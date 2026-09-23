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
    private let smokeSlowBlocks: [UInt8] = [0x12, 0x21, 0x12, 0x32, 0x12, 0x37, 0x12, 0x20, 0x12, 0x23]
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

        switch module.bus {
        case .kLine:
            // Any K-Line session dies after P3max (~5 s) without traffic and the
            // WiFi ELM327 clone then drops the TCP socket (real log 2026-09-23:
            // 23 s idle after a smoke test -> "connection abort"). Keep SID 81
            // going for as long as a K-Line module is the active one.
            if module == .motorECU {
                kwp.initECU { [weak self] ok in
                    guard ok else { completion(false); return }
                    // Security unlock (seed 00 00 = already unlocked, no key is sent)
                    kwp.securityUnlockECU { unlocked in
                        self?.ecuSecurityUnlocked = unlocked
                        self?.connection?.log("ECU security: \(unlocked ? "unlocked" : "locked")")
                        self?.startKeepalive(onlyWhenIdle: false)
                        completion(true)
                    }
                }
            } else {
                kwp.initTCM { [weak self] ok in
                    guard ok else { completion(false); return }
                    kwp.securityUnlockTCM { _ in
                        self?.startKeepalive(onlyWhenIdle: false)
                        completion(true)
                    }
                }
            }
        case .j1850:
            stopKeepalive()   // SID 81 must not be sent on the J1850 bus
            kwp.initJ1850(module: module, completion: completion)
        }
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

        initModule(.motorECU) { [weak self] ok in
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

        initModule(.kLineTCM) { [weak self] ok in
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

        initModule(.motorECU) { [weak self] ok in
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
                // Injection corrections [20-25] signed - idle only as well
                if data.count >= 26 {
                    for i in 0..<3 { self.ecuStatus.injCorrections[i] = Double(s16(data, 20 + i*2)) / 100.0 }
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
                if data.count >= 16 { self.ecuStatus.fuelLevel = Double(u16(data, 14)) / 10.0 }
                if data.count >= 18 { self.ecuStatus.fuelSensorVoltage = Double(u16(data, 16)) / 100.0 }

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
                // [4-5]=sensorSupply*7/1000, [6-7]=solenoid /40, [8-9]=battery /154.5
                if data.count >= 6 { self.tcmStatus.solenoidVoltage = Double(u16(data, 4)) * 7.0 / 1000.0 }
                if data.count >= 8 { self.tcmStatus.solenoidVoltage = Double(u16(data, 6)) / 40.0 }
                if data.count >= 10 { self.tcmStatus.batteryVoltage = Double(u16(data, 8)) / 154.5 }

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

    func readDTCs(module: WJModule) {
        guard let kwp = kwp else { return }

        switch module.bus {
        case .kLine:
            initModule(module) { [weak self] ok in
                guard ok else { return }
                kwp.readDTCs(module: module) { [weak self] response in
                    self?.parseKLineDTCs(module: module, response: response)
                }
            }
        case .j1850:
            // J1850: mode 0x18 is NOT supported by WJ modules
            // Use PID scan via mode 0x22 instead (matching Qt behavior)
            kwp.initJ1850(module: module) { [weak self] _ in
                self?.readJ1850DTCsByPIDScan(module: module)
            }
        }
    }

    func clearDTCs(module: WJModule) {
        guard let kwp = kwp else { return }

        switch module.bus {
        case .kLine:
            kwp.clearDTCs(module: module) { [weak self] ok in
                if ok { self?.dtcList.removeAll { $0.module == module } }
            }
        case .j1850:
            kwp.clearJ1850DTCs(module: module) { [weak self] ok in
                if ok { self?.dtcList.removeAll { $0.module == module } }
            }
        }
    }

    // MARK: - Raw Command

    func sendCustomCommand(_ cmd: String) {
        connection?.sendCommand(cmd) { [weak self] response in
            self?.connection?.log("[CUSTOM] \(cmd) -> \(response)")
        }
    }

    func startBusDump() { connection?.sendCommand("ATMA", timeout: 30.0, completion: nil) }
    func stopBusDump() { connection?.sendRaw(" ") }

    // MARK: - DTC Parsing

    private func parseKLineDTCs(module: WJModule, response: String) {
        guard let kwp = kwp else { return }
        let bytes = kwp.hexToBytes(response)
        // Find 58 NN in response
        guard let idx = bytes.firstIndex(of: 0x58) else {
            if response.contains("NO DATA") { /* no DTCs */ }
            return
        }
        let count = (idx + 1 < bytes.count) ? Int(bytes[idx + 1]) : 0
        var dtcs: [DTCEntry] = []
        var i = idx + 2
        while i + 2 < bytes.count && dtcs.count < count {
            let code = decodeDTC(hi: bytes[i], lo: bytes[i+1])
            dtcs.append(DTCEntry(module: module, code: code, description: ""))
            i += 3
        }
        DispatchQueue.main.async { [weak self] in
            self?.dtcList.removeAll { $0.module == module }
            self?.dtcList.append(contentsOf: dtcs)
        }
    }

    private func parseJ1850DTCs(module: WJModule, response: String) {
        // This is kept as fallback but not used - readJ1850DTCsByPIDScan is primary
    }

    /// J1850 DTC reading via PID scan (matching Qt behavior).
    /// Mode 0x18 is NOT supported by any WJ J1850 module.
    /// Instead, scan known DTC PID ranges via mode 0x22.
    private func readJ1850DTCsByPIDScan(module: WJModule) {
        let pids: [(pid: String, code: String)]
        switch module {
        case .abs:
            pids = [("2E 10","C0031"),("2E 11","C0032"),("2E 12","C0035"),("2E 13","C0036"),
                    ("2E 14","C0041"),("2E 15","C0042"),("2E 16","C0045"),("2E 17","C0046"),
                    ("2E 20","C0051"),("2E 21","C0060"),("2E 22","C0070"),("2E 23","C0080"),
                    ("2E 24","C0081"),("2E 25","C0085"),("2E 26","C0110"),("2E 27","C0111"),
                    ("2E 30","C1014")]
        case .bodyComputer:
            pids = [("2E 00","B1A00"),("2E 01","B1A10"),("2E 02","B2100"),("2E 03","B2101"),
                    ("2E 05","B2102"),("2E 0D","B2200"),("2E 12","B2300")]
        case .rainSensor:
            pids = [("2E 00","B1A00"),("2E 01","B1A10")]
        default:
            pids = [("2E 00","U0001"),("2E 10","U0010")]
        }

        var foundDTCs: [DTCEntry] = []
        var pidIndex = 0

        func scanNext() {
            guard pidIndex < pids.count else {
                DispatchQueue.main.async { [weak self] in
                    self?.dtcList.removeAll { $0.module == module }
                    self?.dtcList.append(contentsOf: foundDTCs)
                }
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
                        foundDTCs.append(DTCEntry(module: module, code: entry.code, description: ""))
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scanNext() }
            }
        }
        scanNext()
    }

    // MARK: - Helpers

    private func decodeDTC(hi: UInt8, lo: UInt8) -> String {
        let prefix = ["P","C","B","U"][Int((hi >> 6) & 0x03)]
        return String(format: "%@%01X%01X%02X", prefix, (hi >> 4) & 0x03, hi & 0x0F, lo)
    }

    private func findPayload(_ bytes: [UInt8], marker1: UInt8, marker2: UInt8) -> Int? {
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
