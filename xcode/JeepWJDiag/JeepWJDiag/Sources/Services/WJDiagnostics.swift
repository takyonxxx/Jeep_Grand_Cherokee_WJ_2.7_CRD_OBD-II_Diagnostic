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
    @Published var activeModule: WJModule?

    private var connection: ELM327Connection?
    private var kwp: KWP2000Handler?
    private var pollTimer: Timer?
    private var keepaliveTimer: Timer?
    private var currentBlockIndex = 0
    private var ecuSecurityUnlocked = false

    // ECU block read order: verified from README + Qt (includes 0x28!)
    private let ecuBlocks: [UInt8] = [0x12, 0x28, 0x30, 0x22, 0x20, 0x23, 0x21, 0x16, 0x32, 0x37, 0x13, 0x36, 0x26, 0x34]
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
            if module == .motorECU {
                kwp.initECU { [weak self] ok in
                    guard ok else { completion(false); return }
                    // Security unlock
                    kwp.securityUnlockECU { unlocked in
                        self?.ecuSecurityUnlocked = unlocked
                        self?.connection?.log("ECU security: \(unlocked ? "unlocked" : "locked")")
                        completion(true)
                    }
                }
            } else {
                kwp.initTCM { ok in
                    guard ok else { completion(false); return }
                    kwp.securityUnlockTCM { _ in completion(true) }
                }
            }
        case .j1850:
            kwp.initJ1850(module: module, completion: completion)
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
                // Try reading first data PID
                kwp.readJ1850Data(module: module, pid: "20 00") { response in
                    let alive = !response.contains("NO DATA") && !response.contains("TIMEOUT")
                    self?.moduleStates[module] = alive
                    completion(alive)
                }
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
            self?.keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                self?.kwp?.sendKeepalive()
            }
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
            self?.keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                self?.kwp?.sendKeepalive()
            }
        }
    }

    func stopLiveData() {
        isPollingLive = false
        pollTimer?.invalidate(); pollTimer = nil
        keepaliveTimer?.invalidate(); keepaliveTimer = nil
        activeModule = nil
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
                // RPM [0-1] raw (overrides 0x12), InjQty [2-3] /100
                if data.count >= 4 {
                    self.ecuStatus.rpm = Double(u16(data, 0))
                    self.ecuStatus.injectionQty = Double(u16(data, 2)) / 100.0
                }
                // Per-cylinder RPMs [4-13]
                if data.count >= 14 {
                    for i in 0..<5 { self.ecuStatus.cylRPMs[i] = Double(u16(data, 4 + i*2)) }
                }
                // Injection corrections [20-25] signed
                if data.count >= 26 {
                    for i in 0..<3 { self.ecuStatus.injCorrections[i] = Double(s16(data, 20 + i*2)) / 100.0 }
                }

            case 0x22:
                // Coolant [0-1] /10-273.1, Boost [14-15] /1000
                if data.count >= 2 { self.ecuStatus.coolantTemp = Double(u16(data, 0)) / 10.0 - 273.1 }
                if data.count >= 16 { self.ecuStatus.boostPressure = Double(u16(data, 14)) / 1000.0 }

            case 0x12:
                // Rail [18-19] *0.101 (constant 0.101, NOT /10!)
                if data.count >= 20 { self.ecuStatus.railPressure = Double(u16(data, 18)) * 0.101 }

            case 0x36:
                // MAF [6-7] /10, Pedal [0-1] /100
                if data.count >= 8 { self.ecuStatus.mafFlow = Double(u16(data, 6)) / 10.0 }

            case 0x32:
                // Fuel actual [0-1] /100 = mg/str
                if data.count >= 2 { self.ecuStatus.fuelQuantity = Double(u16(data, 0)) / 100.0 }

            case 0x12:
                // Rail [18-19] *0.101 = Bar (constant 0.101, NOT /10!)
                // Coolant [0-1] /10-273.1 (also in 0x22)
                if data.count >= 20 {
                    self.ecuStatus.railPressure = Double(u16(data, 18)) * 0.101
                }
                // RPM [10-11] (0x28 overrides this)
                if data.count >= 12 && self.ecuStatus.rpm == 0 {
                    self.ecuStatus.rpm = Double(u16(data, 10))
                }

            case 0x16:
                // Block 0x16: Alternator data only. Battery voltage comes from ATRV (Qt behavior)
                break

            case 0x26:
                // Speed [2-3] /100
                if data.count >= 4 { self.ecuStatus.vehicleSpeed = Double(u16(data, 2)) / 100.0 }

            case 0x21:
                // Fuel level [14-15] /10 = %, Fuel sensor V [16-17] /100
                if data.count >= 16 { self.ecuStatus.fuelLevel = Double(u16(data, 14)) / 10.0 }
                if data.count >= 18 { self.ecuStatus.fuelSensorVoltage = Double(u16(data, 16)) / 100.0 }

            default:
                break
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
            kwp.clearDTCs { [weak self] ok in
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
                let bytes = kwp.hexToBytes(response)
                if let idx62 = bytes.firstIndex(of: 0x62), idx62 + 3 < bytes.count {
                    let d0 = bytes[idx62 + 1]
                    let d1 = bytes[idx62 + 2]
                    if (d0 != 0 || d1 != 0) && !(d0 == 0xFF && d1 == 0xFF) {
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
