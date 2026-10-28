import Foundation
import Combine

/// Main diagnostics orchestrator matching verified ESP32 emulator protocol.
final class WJDiagnostics: ObservableObject {

    @Published var ecuStatus = ECUStatus()
    @Published var tcmStatus = TCMStatus()
    @Published var dtcList: [DTCEntry] = []
    @Published var moduleStates: [WJModule: Bool] = [:]
    @Published var isPollingLive = false
    @Published var activeBus: BusType = .kLine
    @Published var activeModule: WJModule? {
        // No module (or a J1850 module) selected -> no K-Line keepalive.
        didSet { if activeModule == nil || activeModule?.bus != .kLine { stopKeepalive() } }
    }
    @Published var smokeTest = SmokeTestSession()
    /// Last DTC read/clear outcome for the DTC screen ("TCM: 2 DTC", "ECU init failed ...").
    @Published var dtcStatus: String = ""
    /// Module whose bus session is currently established (survives until the
    /// next init). Lets DTC read/clear reuse the open session instead of
    /// re-running ATZ... and lets clear work on a module that was never read.
    private(set) var initializedModule: WJModule?

    // Smoke test polling: the three fast-changing blocks every cycle plus
    // one slow block round-robin. Reads are chained on completion (not on a
    // timer) so the ELM command queue never backs up during the transient.
    // Real vehicle (pcap/ecu_live.pcap): each block read takes ~250-300 ms on
    // K-Line even with ATAT2/ATST 19, so the cycle is 2 fast reads + 1 slow
    // (~0.8 s). The fuel/air pair that decides smoke comes every cycle;
    // 0x12 (MAP actual, rail, IAT, coolant) is interleaved every other cycle,
    // which is enough for turbo spool that takes 1-3 s.
    //   0x36 pedal, MAF, boost setpoint | 0x28 rpm, inj qty, corrections
    private let smokeFastBlocks: [UInt8] = [0x36, 0x28]
    // 0x26 (vehicle speed) is interleaved so a standing-start run gets a
    // speed sample every ~1.6 s and the summary can compute 0-100 km/h.
    private let smokeSlowBlocks: [UInt8] = [0x12, 0x26, 0x21, 0x26, 0x12, 0x26, 0x32, 0x26, 0x12, 0x26, 0x37, 0x26, 0x12, 0x26, 0x20, 0x26, 0x12, 0x26, 0x23, 0x26]
    private var smokeStep = 0
    private var smokeSlowIndex = 0
    private var lastSmokeRead = Date.distantPast

    private var connection: ELM327Connection?
    private var kwp: KWP2000Handler?
    private var pollTimer: Timer?
    private var keepaliveTimer: Timer?
    private var currentBlockIndex = 0
    private var ecuSecurityUnlocked = false

    // ECU block read order: Qt baseIds[] verified
    private let ecuBlocks: [UInt8] = [0x12, 0x30, 0x22, 0x20, 0x23, 0x21, 0x16, 0x32, 0x37, 0x13, 0x36, 0x26, 0x34, 0x28]
    // + security blocks when unlocked: 0x62, 0xB0, 0xB1, 0xB2
    private let ecuSecurityBlocks: [UInt8] = [0x62, 0xB0, 0xB1, 0xB2]

    // TCM block read order: 0x30 -> 0x31 -> 0x34 -> 0x33 -> 0x32
    private let tcmBlocks: [UInt8] = [0x30, 0x31, 0x34, 0x33, 0x32]

    func setConnection(_ conn: ELM327Connection) {
        self.connection = conn
        self.kwp = KWP2000Handler(connection: conn)
        kwp?.onLog = { [weak self] msg in self?.connection?.log(msg) }
    }

    // MARK: - Module Init & Probe

    func initModule(_ module: WJModule, completion: @escaping (Bool) -> Void) {
        guard let kwp = kwp else { completion(false); return }
        let previous = initializedModule
        beginInit()

        // A K-Line module still in a session ignores the next 5-baud init until
        // P3max (~5 s) of silence has passed (real log 2026-09-25 08:53: TCM
        // init OK -> Dashboard Start re-ran the init 3 s later -> "BUS INIT:
        // ERROR", the retry 5 s later worked). Close the old session with SID 82
        // first, then start the ATZ sequence; if the bus still answers ERROR,
        // retry once after P3max.
        if previous?.bus == .kLine, module.bus == .kLine, !kLineRetryPending {
            connection?.log("[INIT] closing \(previous!.displayName) session (SID 82) before \(module.displayName) init")
            connection?.sendCommand("82", timeout: 2.0) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.runKLineInit(module, kwp: kwp, completion: completion)
                }
            }
            return
        }
        // Any K-Line session dies after P3max (~5 s) without traffic and the
        // WiFi ELM327 clone then drops the TCP socket (real log 2026-09-23:
        // 23 s idle after a smoke test -> "connection abort"). runKLineInit
        // keeps SID 81 going for as long as a K-Line module is the active one.
        if module.bus == .kLine {
            runKLineInit(module, kwp: kwp, completion: completion)
        } else {
            kwp.initJ1850(module: module) { [weak self] ok in
                if ok { self?.initializedModule = module }
                completion(ok)
            }
        }
    }

    private var kLineRetryPending = false

    /// ATZ... ATFI 81 for a K-Line module, with one automatic retry after P3max
    /// when the ELM reports "BUS INIT: ERROR" (bus still owned by a session).
    private func runKLineInit(_ module: WJModule, kwp: KWP2000Handler, completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self = self else { completion(false); return }
            if ok {
                self.kLineRetryPending = false
                self.initializedModule = module
                self.startKeepalive(onlyWhenIdle: false)
                completion(true)
                return
            }
            if !self.kLineRetryPending {
                self.kLineRetryPending = true
                self.connection?.log("[INIT] \(module.displayName) bus init failed, retrying after P3max (5.5 s)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
                    self?.initModule(module) { ok in
                        self?.kLineRetryPending = false
                        completion(ok)
                    }
                }
                return
            }
            self.kLineRetryPending = false
            completion(false)
        }
        if module == .motorECU {
            kwp.initECU { [weak self] ok in
                guard ok else { finish(false); return }
                // Security unlock (seed 00 00 = already unlocked, no key is sent)
                kwp.securityUnlockECU { unlocked in
                    self?.ecuSecurityUnlocked = unlocked
                    self?.connection?.log("ECU security: \(unlocked ? "unlocked" : "locked")")
                    finish(true)
                }
            }
        } else {
            kwp.initTCM { ok in
                guard ok else { finish(false); return }
                kwp.securityUnlockTCM { _ in finish(true) }
            }
        }
    }

    /// Init only if `module` does not already own the bus session.
    private func ensureModule(_ module: WJModule, completion: @escaping (Bool) -> Void) {
        if initializedModule == module, connection?.state == .ready { completion(true); return }
        initModule(module, completion: completion)
    }

    /// Every init sequence (ATZ ...) starts from a quiet line: the previous
    /// module's SID 81 keepalive is stopped and queued commands dropped.
    /// Real log 2026-09-24 14:43: the ECU keepalive kept firing during the TCM
    /// init (ATZ, 81, ATZ, ATE1, 81 ...) -> "BUS INIT: ERROR" on every command,
    /// the init was still reported OK and the app crashed on the empty reply.
    private func beginInit() {
        stopKeepalive()
        connection?.cancelQueuedCommands()
        initializedModule = nil
    }

    /// Pedal word -> 0...100 %. Anything outside the physical range means the
    /// word was not the pedal (wrong offset / sign) and is clamped so the smoke
    /// test never sees a "655 %" pedal again.
    static func pedalPercent(_ raw: UInt16) -> Double {
        return min(100.0, max(0.0, Double(raw) / 100.0))
    }

    // MARK: - K-Line keepalive

    /// SID 0x81 (StartCommunication) every 2 s — the real vehicle uses 81, not 3E.
    /// `onlyWhenIdle` = only send when no block read happened in the last 1.5 s
    /// (smoke test: the read chain itself keeps the session alive).
    private func startKeepalive(onlyWhenIdle: Bool) {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let conn = self.connection, conn.state == .ready else { return }
            if onlyWhenIdle && Date().timeIntervalSince(self.lastSmokeRead) <= 1.5 { return }
            // A command in flight keeps the session alive by itself; queuing
            // another 81 behind it only builds a backlog.
            if conn.pendingCommands > 0 { return }
            self.kwp?.sendKeepalive()
        }
    }

    private func stopKeepalive() {
        keepaliveTimer?.invalidate(); keepaliveTimer = nil
    }

    /// Called when a K-Line module stays selected but polling stopped:
    /// switch back to the plain 2 s keepalive so the session does not time out.
    private func resumeIdleKeepalive() {
        if let m = activeModule, m.bus == .kLine, connection?.state == .ready {
            startKeepalive(onlyWhenIdle: false)
        } else {
            stopKeepalive()
        }
    }

    func probeModule(_ module: WJModule, completion: @escaping (Bool) -> Void) {
        // Skip known dead modules
        if module.isNoData {
            moduleStates[module] = false; completion(false); return
        }

        guard let kwp = kwp else { completion(false); return }

        switch module.bus {
        case .kLine:
            initModule(module) { [weak self] ok in
                self?.moduleStates[module] = ok; completion(ok)
            }
        case .j1850:
            beginInit()
            kwp.initJ1850(module: module) { [weak self] _ in
                // Try reading first data PID. Real capture: 9 of 30 first reads
                // right after ATRA come back NO DATA and the immediate retry
                // succeeds, so probe twice before declaring a module dead.
                func probeRead(_ attempt: Int) {
                    kwp.readJ1850Data(module: module, pid: "20 00") { response in
                        let alive = !response.contains("NO DATA") && !response.contains("TIMEOUT")
                        if !alive && attempt < 2 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { probeRead(attempt + 1) }
                            return
                        }
                        self?.moduleStates[module] = alive
                        completion(alive)
                    }
                }
                probeRead(1)
            }
        }
    }

    // MARK: - Live Data

    func startECULiveData() {
        guard !isPollingLive else { return }
        activeModule = .motorECU
        activeBus = .kLine
        isPollingLive = true
        currentBlockIndex = 0

        ensureModule(.motorECU) { [weak self] ok in
            guard ok else { self?.isPollingLive = false; return }

            // Poll timer: read one block per tick
            self?.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                self?.pollNextECUBlock()
            }
            // Keepalive: SID 0x81 every 2 seconds (NOT 0x3E!)
            self?.startKeepalive(onlyWhenIdle: false)
        }
    }

    func startTCMLiveData() {
        guard !isPollingLive else { return }
        activeModule = .kLineTCM
        activeBus = .kLine
        isPollingLive = true
        currentBlockIndex = 0

        ensureModule(.kLineTCM) { [weak self] ok in
            guard ok else { self?.isPollingLive = false; return }
            self?.pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                self?.pollNextTCMBlock()
            }
            self?.startKeepalive(onlyWhenIdle: false)
        }
    }

    /// Stops polling. The module stays selected (the views clear `activeModule`
    /// themselves when the user deselects it), so a K-Line session is kept
    /// alive with SID 81 until another module is initialised or we disconnect.
    func stopLiveData() {
        if smokeTest.isRecording { smokeTest.finish() }
        isPollingLive = false
        pollTimer?.invalidate(); pollTimer = nil
        connection?.cancelQueuedCommands()
        resumeIdleKeepalive()
    }

    // MARK: - Smoke Test (black smoke transient recording)

    func startSmokeTest() {
        guard !smokeTest.isRecording else { return }
        stopLiveData()
        smokeTest.begin()
        activeModule = .motorECU
        activeBus = .kLine
        isPollingLive = true
        smokeStep = 0
        smokeSlowIndex = 0
        connection?.log("[SMOKE] test started")

        ensureModule(.motorECU) { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                self.smokeTest.error = "ECU init failed"
                self.smokeTest.finish()
                self.isPollingLive = false
                self.activeModule = nil
                return
            }
            // Continuous block reads keep the KWP session alive by themselves;
            // only send SID 81 if the chain has been silent for a while.
            self.startKeepalive(onlyWhenIdle: true)
            // ELM327 timing: the default 200 ms post-response wait (ATST 32)
            // dominates the ~300 ms per read seen on the real car. Aggressive
            // adaptive timing + 100 ms wait roughly doubles the sample rate.
            // ATZ at the next init restores the defaults.
            self.connection?.sendCommand("ATAT2", timeout: 2.0) { _ in
                self.connection?.sendCommand("ATST 19", timeout: 2.0) { _ in
                    self.connection?.log("[SMOKE] ELM timing set (ATAT2, ATST 19)")
                    self.pollNextSmokeBlock()
                }
            }
        }
    }

    func stopSmokeTest() {
        guard smokeTest.isRecording else { return }
        smokeTest.finish()
        isPollingLive = false
        connection?.log("[SMOKE] test stopped: \(smokeTest.samples.count) samples, \(String(format: "%.1f", smokeTest.duration)) s")
        // ECU stays selected: keep the K-Line session alive (the 2026-09-23 log
        // lost the adapter 23 s after the test because nothing was sent).
        resumeIdleKeepalive()
    }

    func smokeTestMark() {
        smokeTest.mark()
        connection?.log("[SMOKE] MARK at \(String(format: "%.1f", smokeTest.marks.last ?? 0)) s")
    }

    func clearSmokeTest() {
        guard !smokeTest.isRecording else { return }
        smokeTest.reset()
    }

    private func pollNextSmokeBlock() {
        guard smokeTest.isRecording, let kwp = kwp else { return }
        let block: UInt8
        if smokeStep < smokeFastBlocks.count {
            block = smokeFastBlocks[smokeStep]
            smokeStep += 1
        } else {
            block = smokeSlowBlocks[smokeSlowIndex % smokeSlowBlocks.count]
            smokeSlowIndex += 1
            smokeStep = 0
        }
        kwp.readBlock(block) { [weak self] response in
            guard let self = self else { return }
            self.lastSmokeRead = Date()
            self.parseECUBlock(block, response: response)
            self.computeFuelFlow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self.pollNextSmokeBlock() }
        }
    }

    // MARK: - ECU Block Polling

    private func pollNextECUBlock() {
        guard isPollingLive, let kwp = kwp else { return }
        // The timer ticks every 0.1 s but a read takes ~0.35 s on the car:
        // only enqueue when the previous command has been answered.
        guard (connection?.pendingCommands ?? 0) == 0 else { return }

        var blocks = ecuBlocks
        if ecuSecurityUnlocked { blocks += ecuSecurityBlocks }
        let block = blocks[currentBlockIndex % blocks.count]
        currentBlockIndex += 1

        // At end of cycle, read ATRV for accurate battery voltage (matches Qt)
        let isEndOfCycle = currentBlockIndex % blocks.count == 0
        
        kwp.readBlock(block) { [weak self] response in
            self?.parseECUBlock(block, response: response)
            self?.computeFuelFlow()
            
            if isEndOfCycle {
                // ATRV = ELM327 direct voltage measurement (more accurate than ECU ADC)
                self?.connection?.sendCommand("ATRV") { resp in
                    let cleaned = resp.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "V", with: "")
                        .replacingOccurrences(of: "v", with: "")
                    if let volts = Double(cleaned), volts > 0 {
                        DispatchQueue.main.async {
                            self?.ecuStatus.batteryVoltage = volts
                        }
                    }
                }
            }
        }
    }

    /// Compute fuel flow from RPM and injection quantity (OM612 5-cyl diesel)
    /// Matches Qt: fuelFlowGS = rpm * iq * 5 / (2 * 1000 * 60)
    private func computeFuelFlow() {
        let dieselDensity = 832.0 // g/L
        let cylinders = 5.0
        let iq = ecuStatus.fuelQuantity > 0 ? ecuStatus.fuelQuantity : ecuStatus.injectionQty
        let fuelFlowGS = ecuStatus.rpm * iq * cylinders / (2.0 * 1000.0 * 60.0) // g/s
        ecuStatus.fuelFlowLH = fuelFlowGS * 3600.0 / dieselDensity
        if ecuStatus.vehicleSpeed > 5.0 {
            ecuStatus.fuelLPer100km = ecuStatus.fuelFlowLH / ecuStatus.vehicleSpeed * 100.0
        } else {
            ecuStatus.fuelLPer100km = 0
        }
    }

    private func parseECUBlock(_ block: UInt8, response: String) {
        guard let kwp = kwp else { return }
        let bytes = kwp.hexToBytes(response)
        // Find 61 XX payload in response (skip KWP header if present)
        guard let idx = findPayload(bytes, marker1: 0x61, marker2: block) else { return }
        let data = Array(bytes.suffix(from: idx + 2))

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch block {
            case 0x28:
                // RPM [0-1] raw (overrides 0x12[10-11]), InjQty [2-3] /100
                if data.count >= 4 {
                    self.ecuStatus.rpm = Double(u16(data, 0))
                    self.ecuStatus.injectionQty = Double(u16(data, 2)) / 100.0
                }
                // Per-cylinder RPMs [4-13] - only populated at idle (smooth-running
                // control); all zero while driving (real car, 2026-09-23 log).
                if data.count >= 14 {
                    for i in 0..<5 { self.ecuStatus.cylRPMs[i] = Double(u16(data, 4 + i*2)) }
                }
                // Five per-cylinder injection corrections [16-25] signed - idle only as well.
                // Real car: 0016 0011 FF72 0036 002F = +0.22 +0.17 -1.42 +0.54 +0.47 (sum -0.02).
                if data.count >= 26 {
                    for i in 0..<5 { self.ecuStatus.injCorrections[i] = Double(s16(data, 16 + i*2)) / 100.0 }
                }

            case 0x22:
                // Coolant [0-1] /10-273.1, IAT [2-3] /10-273.1, Boost [14-15] /1000
                if data.count >= 2 { self.ecuStatus.coolantTemp = Double(u16(data, 0)) / 10.0 - 273.1 }
                if data.count >= 4 { self.ecuStatus.iat = Double(u16(data, 2)) / 10.0 - 273.1 }
                if data.count >= 16 { self.ecuStatus.boostPressure = Double(u16(data, 14)) / 1000.0 }

            case 0x12:
                // Coolant [0-1], IAT [2-3] /10-273.1 (same sensors as 0x22),
                // RPM [10-11] (0x28 overrides this), Pedal [12-13] /100 = %,
                // MAP actual [16-17] raw mbar (= boost, identical to 0x22[14-15]),
                // Rail [18-19] *0.101 = Bar (constant 0.101, NOT /10!)
                // [0-1] is NOT rpm (README used to say so): it is coolant temp.
                if data.count >= 2 { self.ecuStatus.coolantTemp = Double(u16(data, 0)) / 10.0 - 273.1 }
                if data.count >= 4 { self.ecuStatus.iat = Double(u16(data, 2)) / 10.0 - 273.1 }
                if data.count >= 12 && self.ecuStatus.rpm == 0 {
                    self.ecuStatus.rpm = Double(u16(data, 10))
                }
                if data.count >= 14 { self.ecuStatus.pedalPos = WJDiagnostics.pedalPercent(u16(data, 12)) }
                if data.count >= 18 {
                    self.ecuStatus.mapActual = Double(u16(data, 16))
                    self.ecuStatus.boostPressure = self.ecuStatus.mapActual / 1000.0
                }
                if data.count >= 20 { self.ecuStatus.railPressure = Double(u16(data, 18)) * 0.101 }

            case 0x36:
                // Real-vehicle layout (pcap/ecu_live.pcap, smoke log 2026-09-23):
                // [0-1] small SIGNED word (not pedal!), [2] gear (0=P/N,1-5), [3] 0,
                // [4-5] raw (unknown), [6-7] MAF /10 = mg/str,
                // [8-9] boost setpoint /1000 = Bar abs, [10-11] baro mbar (~912),
                // [12-13] PEDAL /100 = % (2710 = 100%), [16-17] ~0x390 const,
                // [20-21] raw, [22-23] rail raw *0.101 (same as 0x12[18-19]),
                // [24-25] FFFF, [26-27] MAF copy, [30-31] signed (torque-like)
                if data.count >= 2 { self.ecuStatus.blk36signed = Double(s16(data, 0)) }
                if data.count >= 3 { self.ecuStatus.gear = Int(data[2]) }
                if data.count >= 8 { self.ecuStatus.mafFlow = Double(u16(data, 6)) / 10.0 }
                if data.count >= 10 { self.ecuStatus.boostSetpoint = Double(u16(data, 8)) / 1000.0 }
                if data.count >= 12 { self.ecuStatus.blk36c = Double(u16(data, 10)) }
                if data.count >= 14 { self.ecuStatus.pedalPos = WJDiagnostics.pedalPercent(u16(data, 12)) }
                if data.count >= 24 && self.ecuStatus.railPressure == 0 {
                    self.ecuStatus.railPressure = Double(u16(data, 22)) * 0.101
                }
                if data.count >= 32 { self.ecuStatus.blk36torque = Double(s16(data, 30)) }

            case 0x32:
                // Fuel actual [0-1] /100 = mg/str
                if data.count >= 2 { self.ecuStatus.fuelQuantity = Double(u16(data, 0)) / 100.0 }

            case 0x16:
                // Block 0x16: Alternator data only. Battery voltage comes from ATRV (Qt behavior)
                break

            case 0x26:
                // Speed [2-3] /100
                if data.count >= 4 { self.ecuStatus.vehicleSpeed = Double(u16(data, 2)) / 100.0 }

            case 0x21:
                // Fuel quantity words [0-13] /100 = mg/str (7 x u16)
                for i in 0..<7 where data.count >= (i + 1) * 2 {
                    self.ecuStatus.fuelQty21[i] = Double(u16(data, i * 2)) / 100.0
                }
                // Fuel level [14-15] /10 = %, Fuel sensor V [16-17] /100
                // Fuel (verified real car + WJdiag-Pro 2026-10-28): block 0x21 data[0-1] = fuel sender
                // ADC; voltage = raw*0.0048 (465 -> 2.23 V). "Fuel Level" % = (V - 1.27)*33.3 clamped.
                if data.count >= 2 {
                    self.ecuStatus.fuelSensorVoltage = Double(u16(data, 0)) * 0.0048
                    self.ecuStatus.fuelLevel = max(0, min(100, (self.ecuStatus.fuelSensorVoltage - 1.27) * 33.3))
                }

            case 0x37:
                // EGR/MAF setpoint [0-1] raw, wastegate/EGR actuator [2-3] raw
                if data.count >= 2 { self.ecuStatus.egrMafSetpoint = Double(u16(data, 0)) }
                if data.count >= 4 { self.ecuStatus.wastegateRaw = Double(u16(data, 2)) }

            case 0x20:
                // MAF detail words [0-1], [2-3] raw
                if data.count >= 2 { self.ecuStatus.blk20a = Double(u16(data, 0)) }
                if data.count >= 4 { self.ecuStatus.blk20b = Double(u16(data, 2)) }

            case 0x23:
                // Boost detail words [0-1], [6-7] raw
                if data.count >= 2 { self.ecuStatus.blk23a = Double(u16(data, 0)) }
                if data.count >= 8 { self.ecuStatus.blk23g = Double(u16(data, 6)) }

            default:
                break
            }

            // Smoke test: snapshot after every parsed block
            if self.smokeTest.isRecording {
                self.smokeTest.append(from: self.ecuStatus, src: block)
            }
        }
    }

    // MARK: - TCM Block Polling

    private func pollNextTCMBlock() {
        guard isPollingLive, let kwp = kwp else { return }
        guard (connection?.pendingCommands ?? 0) == 0 else { return }
        let block = tcmBlocks[currentBlockIndex % tcmBlocks.count]
        currentBlockIndex += 1
        
        let isEndOfCycle = currentBlockIndex % tcmBlocks.count == 0
        if isEndOfCycle { kwp.sendKeepalive() }

        kwp.readBlock(block) { [weak self] response in
            self?.parseTCMBlock(block, response: response)
            
            if isEndOfCycle {
                self?.connection?.sendCommand("ATRV") { resp in
                    let cleaned = resp.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "V", with: "")
                        .replacingOccurrences(of: "v", with: "")
                    if let volts = Double(cleaned), volts > 0 {
                        DispatchQueue.main.async {
                            self?.tcmStatus.batteryVoltage = volts
                        }
                    }
                }
            }
        }
    }

    private func parseTCMBlock(_ block: UInt8, response: String) {
        guard let kwp = kwp else { return }
        let bytes = kwp.hexToBytes(response)
        guard let idx = findPayload(bytes, marker1: 0x61, marker2: block) else { return }
        let data = Array(bytes.suffix(from: idx + 2))

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch block {
            case 0x30:
                // [0-1]=TCC slip(signed), [4-5]=outputRPM, [7]=selector, [9]=gear, [11]=temp-50
                if data.count >= 2 { self.tcmStatus.actualTCCSlip = Double(s16(data, 0)) }
                if data.count >= 6 { self.tcmStatus.outputRPM = Double(u16(data, 4)) }
                if data.count >= 8 { self.tcmStatus.selector = data[7] }
                if data.count >= 10 {
                    // Qt logic: byte[7]=selector range, byte[9]=actual gear number
                    // selector: P=8, R=7, N=6, D=5
                    // gear: 0=P/N, 1=1st, 2=2nd, 3=3rd, 4=4th, 5=5th
                    let selector = data[7]
                    let actualGearNum = data[9]
                    switch selector {
                    case 8: self.tcmStatus.gear = .park
                    case 7: self.tcmStatus.gear = .reverse
                    case 6: self.tcmStatus.gear = .neutral
                    case 5: // D range - use byte[9] for actual gear
                        switch actualGearNum {
                        case 1: self.tcmStatus.gear = .drive1
                        case 2: self.tcmStatus.gear = .drive2
                        case 3: self.tcmStatus.gear = .drive3
                        case 4: self.tcmStatus.gear = .drive4
                        case 5: self.tcmStatus.gear = .drive5
                        default: self.tcmStatus.gear = .drive1 // shift transition
                        }
                    default: self.tcmStatus.gear = .unknown
                    }
                }
                if data.count >= 12 { self.tcmStatus.transTemp = Double(data[11]) - 50.0 }

            case 0x31:
                // [0-1]=N2, [4-5]=turbine, [6-7]=engine RPM
                if data.count >= 2 { self.tcmStatus.inputN2 = Double(u16(data, 0)) }
                if data.count >= 6 { self.tcmStatus.turbineRPM = Double(u16(data, 4)) }
                if data.count >= 8 { self.tcmStatus.engineRPM = Double(u16(data, 6)) }

            case 0x34:
                // [4-5]=sensor supply *7/1000 (5.7 V), [6-7]=solenoid supply /40.
                // [8-9] is NOT battery voltage: it is constant within a session
                // and differs between sessions (0x0807 in the BLE captures,
                // 0x0504 = "8.3 V" in the real log 2026-09-25 while ATRV read
                // 13.3 V). Battery comes from ATRV only (end of each cycle).
                if data.count >= 8 { self.tcmStatus.solenoidVoltage = Double(u16(data, 6)) / 40.0 }

            case 0x33:
                // Block 0x33: Pressures (NOT wheel speeds!)
                // [0-1]=TCC pressure /1000=Bar, [6-7]=shift PSI /365=Bar, [8-9]=mod PSI /462=Bar
                if data.count >= 2 { self.tcmStatus.tccPressure = Double(u16(data, 0)) / 1000.0 }
                if data.count >= 8 { self.tcmStatus.shiftPressure = Double(u16(data, 6)) / 365.0 }
                if data.count >= 10 { self.tcmStatus.modulationPressure = Double(u16(data, 8)) / 462.0 }

            case 0x32:
                // [0]=single byte km/h
                if data.count >= 1 { self.tcmStatus.vehicleSpeed = Double(data[0]) }

            default:
                break
            }
        }
    }

    // MARK: - DTC Operations

    private func setDTCStatus(_ s: String) {
        DispatchQueue.main.async { [weak self] in self?.dtcStatus = s; self?.connection?.log("[DTC] \(s)") }
    }

    /// Read DTCs. Reuses the module's open session when it is already the
    /// initialised one (a fresh ATZ init per read is what let the keepalive
    /// break the TCM init in the 2026-09-24 log).
    func readDTCs(module: WJModule) {
        guard let kwp = kwp else { return }
        setDTCStatus("\(module.displayName): reading…")
        ensureModule(module) { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.setDTCStatus("\(module.displayName): init failed"); return }
            switch module.bus {
            case .kLine:
                kwp.readDTCs(module: module) { [weak self] response in
                    guard let self = self else { return }
                    if response.contains("TIMEOUT") || response.contains("BUS INIT") {
                        self.setDTCStatus("\(module.displayName): no answer to 18 02 (\(response.trimmingCharacters(in: .whitespacesAndNewlines)))")
                        return
                    }
                    let n = self.parseKLineDTCs(module: module, response: response)
                    self.setDTCStatus("\(module.displayName): \(n) DTC")
                }
            case .j1850:
                // J1850: mode 0x18 is NOT supported by WJ modules -> PID scan via mode 0x22
                self.readJ1850DTCsByPIDScan(module: module)
            }
        }
    }

    /// Clear DTCs. The module is initialised first if needed, and the read is
    /// repeated afterwards so the list and the status reflect the ECU state.
    func clearDTCs(module: WJModule) {
        guard let kwp = kwp else { return }
        setDTCStatus("\(module.displayName): clearing…")
        ensureModule(module) { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.setDTCStatus("\(module.displayName): init failed"); return }
            let done: (Bool) -> Void = { [weak self] ok in
                guard let self = self else { return }
                if ok {
                    DispatchQueue.main.async { self.dtcList.removeAll { $0.module == module } }
                    self.setDTCStatus("\(module.displayName): cleared")
                    // Re-read so a fault that is still present comes back immediately.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.readDTCs(module: module) }
                } else {
                    self.setDTCStatus("\(module.displayName): clear failed (no 54)")
                }
            }
            switch module.bus {
            case .kLine: kwp.clearDTCs(module: module, completion: done)
            case .j1850: kwp.clearJ1850DTCs(module: module, completion: done)
            }
        }
    }

    // MARK: - Raw Command

    func sendCustomCommand(_ cmd: String) {
        sendCustomCommand(cmd, attempt: 1)
    }

    /// J1850 actuator commands: an OFF frame ("38 xx 00") that gets NO DATA is
    /// re-sent (real log 2026-09-24: "38 02 00 -> NO DATA" left the window
    /// motor running until the door module timed out).
    private func sendCustomCommand(_ cmd: String, attempt: Int) {
        connection?.sendCommand(cmd) { [weak self] response in
            self?.connection?.log("[CUSTOM] \(cmd) -> \(response)")
            let isActuatorOff = cmd.uppercased().hasPrefix("38 ") && cmd.uppercased().hasSuffix(" 00")
            if isActuatorOff && response.contains("NO DATA") && attempt < 3 {
                self?.connection?.log("[CUSTOM] retry OFF \(attempt)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.sendCustomCommand(cmd, attempt: attempt + 1) }
            }
        }
    }

    func startBusDump() { connection?.sendCommand("ATMA", timeout: 30.0, completion: nil) }
    func stopBusDump() { connection?.sendRaw(" ") }

    // MARK: - DTC Parsing

    @discardableResult
    /// K-Line (ECU/TCM) DTC code -> description. P2210/P0702 confirmed on the real car;
    /// the rest are the standard WJ 2.7 CRD (EDC15C2 / NAG1 722.6) codes.
    private static let kLineDtcNames: [String: String] = [
        // Engine (EDC15C2)
        "P0100": "MAF Sensor Circuit", "P0105": "Boost/MAP Sensor Circuit",
        "P0110": "Intake Air Temp Sensor", "P0115": "Coolant Temp Sensor",
        "P0190": "Fuel Rail Pressure Sensor",
        "P0201": "Cylinder 1 Injector Circuit", "P0202": "Cylinder 2 Injector Circuit",
        "P0203": "Cylinder 3 Injector Circuit", "P0204": "Cylinder 4 Injector Circuit",
        "P0205": "Cylinder 5 Injector Circuit",
        "P0335": "CKP Position Sensor Circuit", "P0340": "CMP Position Sensor Circuit",
        "P0380": "Glow Plug 1 Relay Control Circuit", "P0381": "Glow Plug 2 Relay Control Circuit",
        "P0403": "EGR Solenoid Circuit", "P0460": "Fuel Level Sensor Circuit",
        "P0500": "Vehicle Speed Sensor", "P0645": "A/C Clutch Relay Circuit",
        "P2120": "Accelerator Pedal Position Sensor 1", "P2125": "Accelerator Pedal Position Sensor 2",
        "P0702": "Transmission Control",  // real car: ECU 18 02 00 00 -> 58 01 07 02 E0
        // Transmission (NAG1 722.6)
        "P2210": "ID 17 Shifter signal invalid",  // real car: TCM 18 02 FF 00 -> 58 01 22 10 20
        "P0700": "Transmission Control System", "P0703": "Brake Switch B Circuit",
        "P0705": "Range Sensor Circuit (PRNDL)", "P0710": "Trans Fluid Temp Sensor",
        "P0715": "Input/Turbine Speed Sensor", "P0720": "Output Speed Sensor",
        "P0730": "Incorrect Gear Ratio", "P0731": "Gear 1 Ratio Error",
        "P0732": "Gear 2 Ratio Error", "P0733": "Gear 3 Ratio Error",
        "P0734": "Gear 4 Ratio Error", "P0735": "Gear 5 Ratio Error",
        "P0740": "TCC Solenoid Circuit", "P0741": "TCC Stuck Off",
    ]

    static func dtcName(_ code: String) -> String {
        if let d = kLineDtcNames[code] { return d }
        switch code.first {
        case "P": return "Powertrain fault code"
        case "C": return "Chassis fault code"
        case "B": return "Body fault code"
        case "U": return "Network fault code"
        default: return ""
        }
    }

    private func parseKLineDTCs(module: WJModule, response: String) -> Int {
        guard let kwp = kwp else { return 0 }
        let bytes = kwp.hexToBytes(response)
        // Find 58 NN in response ("58 00" = no DTCs)
        guard let idx = bytes.firstIndex(of: 0x58) else {
            DispatchQueue.main.async { [weak self] in self?.dtcList.removeAll { $0.module == module } }
            return 0
        }
        let count = (idx + 1 < bytes.count) ? Int(bytes[idx + 1]) : 0
        var dtcs: [DTCEntry] = []
        var i = idx + 2
        while i + 2 < bytes.count && dtcs.count < count {
            let code = decodeDTC(hi: bytes[i], lo: bytes[i+1])
            dtcs.append(DTCEntry(module: module, code: code, description: Self.dtcName(code)))
            i += 3
        }
        DispatchQueue.main.async { [weak self] in
            self?.dtcList.removeAll { $0.module == module }
            self?.dtcList.append(contentsOf: dtcs)
        }
        return dtcs.count
    }

    private func parseJ1850DTCs(module: WJModule, response: String) {
        // This is kept as fallback but not used - readJ1850DTCsByPIDScan is primary
    }

    /// J1850 DTC reading via PID scan (matching Qt behavior).
    /// Mode 0x18 is NOT supported by any WJ J1850 module.
    /// Instead, scan known DTC PID ranges via mode 0x22.
    private func readJ1850DTCsByPIDScan(module: WJModule) {
        let pids: [(pid: String, code: String, desc: String)]
        switch module {
        case .abs:
            // code = PID, desc = WJdiag-Pro's exact name (res VeadABS2E<pid>00).
            pids = [("2E 10","2E 10","Left Front Sensor Circuit Failure"),("2E 11","2E 11","Left Front Wheel Speed Signal Failure"),
                    ("2E 12","2E 12","Right Front Sensor Circuit Failure"),("2E 13","2E 13","Right Front Wheel Speed Signal Failure"),
                    ("2E 14","2E 14","Left Rear Sensor Circuit Failure"),("2E 15","2E 15","Left Rear Wheel Speed Signal Failure"),
                    ("2E 16","2E 16","Right Rear Sensor Circuit Failure"),("2E 17","2E 17","Right Rear Wheel Speed Signal Failure"),
                    ("2E 20","2E 20","Pump Circuit Failure"),("2E 21","2E 21","Valve Power Feed Failure"),
                    ("2E 22","2E 22","CAB Internal Failure"),("2E 23","2E 23","G-Switch / Sensor Failure"),
                    ("2E 24","2E 24","System Under Voltage"),("2E 25","2E 25","Cluster Lamp Failure"),
                    ("2E 26","2E 26","BUS System Communication"),("2E 27","2E 27","System Over Voltage"),
                    ("2E 30","2E 30","Brake Fluid Level Switch")]
        case .bodyComputer:
            // code = PID, desc = WJdiag-Pro primary name (res VeadBody2E<pid>00_0).
            pids = [("2E 00","2E 00","BCM Eeprom Checksum Failure"),("2E 01","2E 01","Head Lamp Sw Open Ckt"),
                    ("2E 02","2E 02","Pcm Message Not Recd"),("2E 03","2E 03","Ambient Temperature Sensor Ckt Open"),
                    ("2E 05","2E 05","Wiper Park Switch Failure"),("2E 12","2E 12","Fog Lamp Relay Ckt Shorted Hi")]
        case .rainSensor:
            // WJdiag-Pro scans PID 2E 10 (res VeadRainSensor2E1000_0..2).
            pids = [("2E 10","2E 10","Rain Sensor Internal/Optical Fault")]
        case .espModule:
            // Airbag/ORC is module 0x58. WJdiag-Pro capture: ATSH245822 + the 2E/2F PID scan
            // below; a non-zero 62 payload = fault. Clear = ATSH245814 + "01 00 00". code = PID,
            // desc = WJdiag-Pro's exact fault name (res VeadAirbag2E1000_<scan-index>); 2E E5 =
            // "Right Front Impact Sensor Internal 1" matches the real car / pcap.
            pids = [("2E 10","2E 10","Accelerometer 1"),("2E 13","2E 13","Output Driver 1"),("2E 16","2E 16","Driver SQUIB 1 Circuit Open"),
                    ("2E 19","2E 19","Passenger SQUIB 1 Circuit Open"),("2E 1C","2E 1C","Internal 1"),("2E 1F","2E 1F","Driver SQUIB 1 Circuit Short"),
                    ("2E 22","2E 22","Passenger SQUIB 1 Circuit Short"),("2E 25","2E 25","Driver SQUIB 1 Short To Battery"),("2E 28","2E 28","Passenger SQUIB 1 Short To Battery"),
                    ("2E 2B","2E 2B","Driver SQUIB 1 Short To Ground"),("2E 2E","2E 2E","Passenger SQUIB 1 Short To Ground"),("2E 37","2E 37","Stored Energy Firing 1"),
                    ("2E 3A","2E 3A","Warning Indicator Short"),("2E 3D","2E 3D","Warning Indicator Open"),("2E 43","2E 43","No PCI Transmission"),
                    ("2E 49","2E 49","Loss Of Ignition / Run-Start"),("2E 4C","2E 4C","Loss Of Ignition / Run Only"),("2E 4F","2E 4F","No Cluster Message"),
                    ("2E 52","2E 52","Cluster Message Mismatch"),("2E 70","2E 70","Driver SQUIB 2 Circuit Open"),("2E 73","2E 73","Passenger SQUIB 2 Circuit Open"),
                    ("2E 76","2E 76","Driver SQUIB 2 Circuit Short"),("2E 79","2E 79","Passenger SQUIB 2 Circuit Short"),("2E 7C","2E 7C","Driver SQUIB 2 Short To Battery"),
                    ("2E 7F","2E 7F","Passenger SQUIB 2 Short To Battery"),("2E 82","2E 82","Driver SQUIB 2 Short To Ground"),("2E 85","2E 85","Passenger SQUIB 2 Short To Ground"),
                    ("2E 88","2E 88","Driver Seat Belt Switch Circuit Open"),("2E 8B","2E 8B","Passenger Seat Belt Switch Circuit Open"),("2E 8E","2E 8E","Driver Seat Belt Switch Shorted To Ground"),
                    ("2E 91","2E 91","Passenger Seat Belt Switch Shorted To Ground"),("2E 94","2E 94","Driver Seat Belt Switch Shorted To Battery"),("2E 97","2E 97","Passenger Seat Belt Switch Shorted To Battery"),
                    ("2E DC","2E DC","No Left Front Impact Sensor Communication"),("2E DF","2E DF","No Right Front Impact Sensor Communication"),("2E E2","2E E2","Left Front Impact Sensor Internal 1"),
                    ("2E E5","2E E5","Right Front Impact Sensor Internal 1"),("2E FA","2E FA","Interrogate AOSIM"),("2E FD","2E FD","No AOSIM Message"),
                    ("2F 00","2F 00","AOSIM Driver Off Indicator Failure"),("2F 03","2F 03","AOSIM Passenger Off Indicator Failure"),("2F 06","2F 06","Module Not Configured For AOSIM"),
                    ("2F 18","2F 18","Driver Curtain SQUIB Circuit Open"),("2F 1B","2F 1B","Passenger Curtain SQUIB Circuit Open"),("2F 1E","2F 1E","Driver Curtain SQUIB Circuit Short"),
                    ("2F 21","2F 21","Passenger Curtain SQUIB Circuit Short"),("2F 24","2F 24","Driver Curtain SQUIB Short To Battery"),("2F 27","2F 27","Passenger Curtain SQUIB Short To Battery"),
                    ("2F 2A","2F 2A","Driver Curtain SQUIB Short To Ground"),("2F 2D","2F 2D","Passenger Curtain SQUIB Short To Ground"),("2F 30","2F 30","Accelerometer 2"),
                    ("2F 33","2F 33","No Driver Side Impact Sensor Communication"),("2F 36","2F 36","No Passenger Side Impact Sensor Communication"),("2F 39","2F 39","Driver Side Impact Sensor Internal 1"),
                    ("2F 3C","2F 3C","Passenger Side Impact Sensor Internal 1")]
        default:
            pids = [("2E 00","U0001"),("2E 10","U0010")].map { ($0.0, $0.1, "") }
        }

        var foundDTCs: [DTCEntry] = []
        var pidIndex = 0

        func scanNext() {
            guard pidIndex < pids.count else {
                DispatchQueue.main.async { [weak self] in
                    self?.dtcList.removeAll { $0.module == module }
                    self?.dtcList.append(contentsOf: foundDTCs)
                }
                setDTCStatus("\(module.displayName): \(foundDTCs.count) DTC (\(pids.count) PIDs scanned)")
                return
            }
            let entry = pids[pidIndex]
            pidIndex += 1

            connection?.sendCommand(entry.pid + " 00", timeout: 3.0) { [weak self] response in
                guard let self = self, let kwp = self.kwp else { return }
                // Real reply: "26 <addr> 62 D0 D1 D2 CS". Locate 62 by its header
                // so a 62 data byte inside stray traffic cannot be mistaken for it.
                // NRC 7F 22 21 (busy) is already retried by the connection layer.
                let bytes = kwp.hexToBytes(response)
                var idx62: Int? = nil
                if bytes.count >= 3 {
                    for i in 2..<bytes.count where bytes[i] == 0x62 && bytes[i - 1] == module.rawValue && bytes[i - 2] == 0x26 {
                        idx62 = i; break
                    }
                }
                if idx62 == nil, !ELM327Connection.hasNRC(response, code: 0x21) { idx62 = bytes.firstIndex(of: 0x62) }
                if let i = idx62, i + 3 < bytes.count {
                    let d0 = bytes[i + 1], d1 = bytes[i + 2], d2 = bytes[i + 3]
                    let raw = (UInt16(d0) << 8) | UInt16(d1)
                    // Qt rule: non-zero and not FFFF = fault. Additionally the ABS
                    // answers "00 FF FF" for roughly half its PIDs in the real
                    // capture, which reads as "not supported", not as 10 faults.
                    let unsupported = (d1 == 0xFF && d2 == 0xFF)
                    if raw != 0x0000 && raw != 0xFFFF && !unsupported {
                        foundDTCs.append(DTCEntry(module: module, code: entry.code, description: entry.desc))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scanNext() }
            }
        }

        // Sequentially send the WJdiag-Pro airbag warm-up blocks, then start the scan.
        func sendWarmup(_ cmds: [String], _ index: Int, _ done: @escaping () -> Void) {
            guard index < cmds.count else { done(); return }
            connection?.sendCommand(cmds[index], timeout: 2.0) { [weak self] _ in
                guard self != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { sendWarmup(cmds, index + 1, done) }
            }
        }

        // Re-assert the J1850 read header (ATSH24xx22 + ATRAxx) before scanning: ensureModule
        // skips re-init when the module is already current, so a prior clear (which leaves the
        // header in mode 0x14) would otherwise make every 2E/2F read come back NO DATA. For the
        // airbag (0x58) module, warm it with WJdiag-Pro's 20/24/28 block read first.
        guard let kwp = self.kwp else { scanNext(); return }
        kwp.setJ1850Header(module: module, mode: 0x22) {
            if module == .espModule {
                sendWarmup(["20 00 00", "20 01 00", "20 02 00", "24 00 00", "28 00 00", "20 07 00"], 0) { scanNext() }
            } else {
                scanNext()
            }
        }
    }

    // MARK: - Helpers

    private func decodeDTC(hi: UInt8, lo: UInt8) -> String {
        let prefix = ["P","C","B","U"][Int((hi >> 6) & 0x03)]
        return String(format: "%@%01X%01X%02X", prefix, (hi >> 4) & 0x03, hi & 0x0F, lo)
    }

    private func findPayload(_ bytes: [UInt8], marker1: UInt8, marker2: UInt8) -> Int? {
        // "TIMEOUT" / "BUS INIT: ERROR" decode to zero bytes: 0..<-1 is a fatal
        // range in Swift, so guard before iterating (crash seen 2026-09-24).
        guard bytes.count >= 2 else { return nil }
        for i in 0..<bytes.count - 1 {
            if bytes[i] == marker1 && bytes[i+1] == marker2 { return i }
        }
        return nil
    }
}

// MARK: - Byte Helpers
private func u16(_ data: [UInt8], _ offset: Int) -> UInt16 {
    guard offset + 1 < data.count else { return 0 }
    return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
}

private func s16(_ data: [UInt8], _ offset: Int) -> Int16 {
    return Int16(bitPattern: u16(data, offset))
}
