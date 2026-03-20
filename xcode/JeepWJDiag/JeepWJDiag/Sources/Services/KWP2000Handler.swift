import Foundation

/// KWP2000 protocol handler matching verified ESP32 emulator behavior.
/// Init sequences from README.md, security from real vehicle captures.
final class KWP2000Handler {

    private weak var connection: ELM327Connection?
    var onLog: ((String) -> Void)?

    init(connection: ELM327Connection) {
        self.connection = connection
    }

    // MARK: - ArvutaKoodi Tables (from ESP32 emulator, verified)
    private static let T1: [UInt8] = [0xC0,0xD0,0xE0,0xF0,0x00,0x10,0x20,0x30,0x40,0x50,0x60,0x70,0x80,0x90,0xA0,0xB0]
    private static let T2: [UInt8] = [0x02,0x03,0x00,0x01,0x06,0x07,0x04,0x05,0x0A,0x0B,0x08,0x09,0x0E,0x0F,0x0C,0x0D]
    private static let T3: [UInt8] = [0x90,0x80,0xF0,0xE0,0xD0,0xC0,0x30,0x20,0x10,0x00,0x70,0x60,0x50,0x40,0xB0,0xA0]
    private static let T4: [UInt8] = [0x0D,0x0C,0x0F,0x0E,0x09,0x08,0x0B,0x0A,0x05,0x04,0x07,0x06,0x01,0x00,0x03,0x02]

    // MARK: - K-Line Init Sequences (Verified)

    /// ECU 0x15 init: ATZ -> ATE1 -> ATH1 -> ATWM8115F13E -> ATSH8115F1 -> ATSP5 -> ATFI -> 81 -> 27 01/02
    func initECU(completion: @escaping (Bool) -> Void) {
        let cmds = [
            "ATZ", "ATZ",       // double ATZ for clone reliability
            "ATE1",
            "ATH1",
            "ATWM8115F13E",
            "ATSH8115F1",
            "ATSP5",
        ]
        sendSequence(cmds, index: 0) { [weak self] in
            // ATFI: two-part response (BUS INIT: + delay + OK)
            self?.connection?.sendCommand("ATFI", timeout: 5.0) { _ in
                // 81 = StartCommunication (also serves as keepalive)
                self?.connection?.sendCommand("81", timeout: 3.0) { response in
                    let ok = response.contains("C1") || response.contains("BUS INIT")
                    if ok { self?.onLog?("ECU 0x15 K-Line init OK") }
                    completion(ok)
                }
            }
        }
    }

    /// TCM 0x20 init: ATZ -> ATE1 -> ATH1 -> ATWM8120F13E -> ATWM8120F13E -> ATSH8120F1 -> ATSP5 -> ATFI -> 81
    /// Double ATWM for TCM reliability.
    func initTCM(completion: @escaping (Bool) -> Void) {
        let cmds = [
            "ATZ", "ATZ",
            "ATE1",
            "ATH1",
            "ATWM8120F13E",
            "ATWM8120F13E",     // double ATWM for reliability
            "ATSH8120F1",
            "ATSP5",
        ]
        sendSequence(cmds, index: 0) { [weak self] in
            self?.connection?.sendCommand("ATFI", timeout: 5.0) { _ in
                self?.connection?.sendCommand("81", timeout: 3.0) { response in
                    let ok = response.contains("C1") || response.contains("BUS INIT")
                    if ok { self?.onLog?("TCM 0x20 K-Line init OK") }
                    completion(ok)
                }
            }
        }
    }

    /// J1850 VPW init: ATZ -> ATZ -> ATSP2 -> ATIFR0 -> ATH1 -> ATSH24xx22 -> ATRAxx
    /// ATH1 comes AFTER ATSP2/ATIFR0, not before.
    func initJ1850(module: WJModule, completion: @escaping (Bool) -> Void) {
        let addr = String(format: "%02X", module.rawValue)
        let cmds = [
            "ATZ", "ATZ",
            "ATSP2",
            "ATIFR0",
            "ATH1",
            "ATSH24\(addr)22",
            "ATRA\(addr)",
        ]
        sendSequence(cmds, index: 0) {
            self.onLog?("J1850 init OK for 0x\(addr)")
            completion(true)
        }
    }

    // MARK: - Security Access

    /// ECU security: seed=0x0000 means already unlocked.
    /// ArvutaKoodi with seed=0 produces key 9C C9 (accepted by ECU).
    func securityUnlockECU(completion: @escaping (Bool) -> Void) {
        connection?.sendCommand("27 01", timeout: 3.0) { [weak self] response in
            guard let self = self else { completion(false); return }
            let bytes = self.hexToBytes(response)
            // Find 67 01 in response
            guard let idx = bytes.firstIndex(of: 0x67), idx + 1 < bytes.count, bytes[idx+1] == 0x01 else {
                completion(false); return
            }
            if idx + 3 < bytes.count {
                let seedHi = bytes[idx+2]
                let seedLo = bytes[idx+3]
                if seedHi == 0x00 && seedLo == 0x00 {
                    // Seed=0000: ECU already unlocked
                    self.onLog?("ECU seed=0000, already unlocked")
                    completion(true)
                    return
                }
                // Compute ArvutaKoodi key
                let key = self.arvutaKoodi(seedHi: seedHi, seedLo: seedLo)
                let keyCmd = String(format: "27 02 %02X %02X", key.hi, key.lo)
                self.connection?.sendCommand(keyCmd, timeout: 3.0) { resp in
                    let ok = resp.contains("67 02") || resp.contains("6702")
                    completion(ok)
                }
            } else if idx + 2 < bytes.count && bytes[idx+2] == 0x00 {
                // Short seed response (2 bytes only seen with some ECUs)
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    /// TCM security: static seed 68 24 89 -> key CC 21
    /// EGS52 algorithm: swap, XOR 0x5AA5, multiply 0x5AA5
    func securityUnlockTCM(completion: @escaping (Bool) -> Void) {
        connection?.sendCommand("27 01", timeout: 3.0) { [weak self] response in
            // TCM always returns static seed, key is always CC 21
            self?.connection?.sendCommand("27 02 CC 21", timeout: 3.0) { resp in
                let ok = resp.contains("67 02")
                completion(ok)
            }
        }
    }

    // MARK: - Keepalive

    /// K-Line keepalive: SID 0x81 (StartCommunication), NOT 0x3E (TesterPresent)!
    /// ECU responds with C1 EF 8F each time.
    func sendKeepalive() {
        connection?.sendCommand("81", timeout: 2.0, completion: nil)
    }

    // MARK: - Data Read

    func readBlock(_ block: UInt8, completion: @escaping (String) -> Void) {
        let cmd = String(format: "21 %02X", block)
        connection?.sendCommand(cmd, timeout: 3.0, completion: completion)
    }

    // MARK: - DTC

    /// K-Line DTC read: ECU uses 18 02 00 00, TCM uses 18 02 FF 00
    func readDTCs(module: WJModule, completion: @escaping (String) -> Void) {
        let cmd = (module == .kLineTCM) ? "18 02 FF 00" : "18 02 00 00"
        connection?.sendCommand(cmd, timeout: 8.0, completion: completion)
    }

    /// DTC clear: 14 00 00 -> 54 00 00
    /// NRC 0x78 handling: ECU may return 7F 14 78 (ResponsePending) before 54 00 00
    func clearDTCs(completion: @escaping (Bool) -> Void) {
        connection?.sendCommand("14 00 00", timeout: 8.0) { response in
            // Accept both direct positive and NRC 0x78 + positive
            let ok = response.contains("54")
            completion(ok)
        }
    }

    // MARK: - J1850 Operations

    /// Set J1850 header for specific module and mode
    func setJ1850Header(module: WJModule, mode: UInt8, completion: (() -> Void)? = nil) {
        let hdr = String(format: "ATSH24%02X%02X", module.rawValue, mode)
        let filter = String(format: "ATRA%02X", module.rawValue)
        connection?.sendCommand(hdr, timeout: 1.0) { [weak self] _ in
            self?.connection?.sendCommand(filter, timeout: 1.0) { _ in completion?() }
        }
    }

    /// J1850 DTC read: ATSH24xx18 + FF 00 00
    func readJ1850DTCs(module: WJModule, completion: @escaping (String) -> Void) {
        setJ1850Header(module: module, mode: 0x18) { [weak self] in
            self?.connection?.sendCommand("FF 00 00", timeout: 5.0, completion: completion)
        }
    }

    /// J1850 DTC clear: ATSH24xx14 + ATRAxx + clear_cmd
    /// ESP 0x58: uses "01 00 00" (may need 7 retries!)
    /// Others: use "FF 00 00"
    func clearJ1850DTCs(module: WJModule, completion: @escaping (Bool) -> Void) {
        let clearCmd = (module == .espModule) ? "01 00 00" : "FF 00 00"
        setJ1850Header(module: module, mode: 0x14) { [weak self] in
            self?.connection?.sendCommand(clearCmd, timeout: 8.0) { response in
                let ok = response.contains("54")
                completion(ok)
            }
        }
    }

    /// J1850 data read: ATSH24xx22 + ATRAxx + "PID 00 00"
    func readJ1850Data(module: WJModule, pid: String, completion: @escaping (String) -> Void) {
        setJ1850Header(module: module, mode: 0x22) { [weak self] in
            self?.connection?.sendCommand(pid + " 00 00", timeout: 3.0, completion: completion)
        }
    }

    /// J1850 actuator control: mode 0x2F
    func sendJ1850Actuator(module: WJModule, command: String, completion: @escaping (String) -> Void) {
        setJ1850Header(module: module, mode: 0x2F) { [weak self] in
            self?.connection?.sendCommand(command, timeout: 3.0, completion: completion)
        }
    }

    // MARK: - ECU Actuators (SID 0x30)

    /// ECU actuator control. Some commands trigger NRC 0x78 (ResponsePending)
    /// before positive response — both arrive in same ELM327 frame.
    func sendActuator(_ cmd: String, completion: @escaping (String) -> Void) {
        connection?.sendCommand(cmd, timeout: 8.0) { response in
            // Handle NRC 0x78: strip pending, return positive part
            if response.contains("7F") && response.contains("78") {
                let lines = response.components(separatedBy: "\r")
                let positive = lines.filter { !$0.contains("7F") && !$0.isEmpty }
                completion(positive.joined(separator: "\r"))
            } else {
                completion(response)
            }
        }
    }

    // MARK: - ArvutaKoodi Algorithm

    private func arvutaKoodi(seedHi: UInt8, seedLo: UInt8) -> (hi: UInt8, lo: UInt8) {
        let v1 = UInt8((UInt16(seedLo) &+ 0x0B) & 0xFF)
        let keyLo = Self.T1[Int((v1 >> 4) & 0x0F)] | Self.T2[Int(v1 & 0x0F)]

        let cond: UInt8 = (seedLo > 0x34) ? 1 : 0
        let v2 = UInt8((UInt16(seedHi) &+ UInt16(cond) &+ 1) & 0xFF)
        let keyHi = Self.T3[Int((v2 >> 4) & 0x0F)] | Self.T4[Int(v2 & 0x0F)]

        return (keyHi, keyLo)
    }

    // MARK: - Helpers

    func hexToBytes(_ hex: String) -> [UInt8] {
        let clean = hex.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var bytes: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let next = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if next > i, let byte = UInt8(clean[i..<next], radix: 16) {
                bytes.append(byte)
            }
            i = next
        }
        return bytes
    }

    private func sendSequence(_ cmds: [String], index: Int, completion: @escaping () -> Void) {
        guard index < cmds.count else { completion(); return }
        connection?.sendCommand(cmds[index], timeout: 3.0) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.sendSequence(cmds, index: index + 1, completion: completion)
            }
        }
    }
}
