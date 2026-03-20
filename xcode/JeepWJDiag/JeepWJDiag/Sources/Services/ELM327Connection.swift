import Foundation
import Network
import CoreBluetooth
import Combine

final class ELM327Connection: NSObject, ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var transport: ELMTransport = .wifi
    @Published var wifiHost: String = "192.168.0.10"
    @Published var wifiPort: UInt16 = 35000
    @Published var logMessages: [String] = []
    @Published var discoveredDevices: [(name: String, id: String)] = []

    var onRawData: ((Data) -> Void)?
    var onResponse: ((String) -> Void)?

    private var tcpConnection: NWConnection?
    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    private var commandQueue: [ELMCommand] = []
    private var isProcessingCommand = false
    private var responseBuffer = ""
    private var currentCommand: ELMCommand?
    private var commandTimer: Timer?

    private let elmServiceUUID = CBUUID(string: "FFF0")
    private let elmWriteUUID = CBUUID(string: "FFF2")
    private let elmNotifyUUID = CBUUID(string: "FFF1")

    override init() { super.init() }

    // MARK: - Public

    func connect() {
        switch transport {
        case .wifi: connectWiFi()
        case .bluetooth: connectBluetooth()
        }
    }

    func disconnect() {
        commandQueue.removeAll()
        commandTimer?.invalidate()
        currentCommand = nil
        isProcessingCommand = false
        responseBuffer = ""
        tcpConnection?.cancel(); tcpConnection = nil
        if let p = connectedPeripheral { centralManager?.cancelPeripheralConnection(p) }
        updateState(.disconnected)
    }

    func sendCommand(_ cmd: String, timeout: TimeInterval = 5.0, completion: ((String) -> Void)? = nil) {
        commandQueue.append(ELMCommand(cmd, timeout: timeout, completion: completion))
        processNextCommand()
    }

    func sendRaw(_ data: String) {
        writeToTransport((data + "\r").data(using: .ascii)!)
        log("[TX] \(data)")
    }

    func startBluetoothScan() {
        discoveredDevices.removeAll()
        if centralManager == nil { centralManager = CBCentralManager(delegate: self, queue: .main) }
        else if centralManager?.state == .poweredOn {
            updateState(.scanning)
            centralManager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.centralManager?.stopScan()
                if self?.state == .scanning { self?.updateState(.disconnected) }
            }
        }
    }

    func connectToDevice(id: String) {
        guard let cm = centralManager, let uuid = UUID(uuidString: id) else { return }
        if let p = cm.retrievePeripherals(withIdentifiers: [uuid]).first {
            connectedPeripheral = p; p.delegate = self
            updateState(.connecting); cm.connect(p, options: nil)
        }
    }

    // MARK: - Transport

    private func writeToTransport(_ data: Data) {
        switch transport {
        case .wifi:
            tcpConnection?.send(content: data, completion: .contentProcessed({ _ in }))
        case .bluetooth:
            guard let c = writeCharacteristic, let p = connectedPeripheral else { return }
            let mtu = p.maximumWriteValueLength(for: .withResponse)
            var off = 0
            while off < data.count {
                let chunk = data.subdata(in: off..<min(off+mtu, data.count))
                p.writeValue(chunk, for: c, type: .withResponse)
                off += mtu
            }
        }
    }

    // MARK: - WiFi

    private func connectWiFi() {
        updateState(.connecting)
        tcpConnection = NWConnection(host: NWEndpoint.Host(wifiHost),
                                     port: NWEndpoint.Port(rawValue: wifiPort)!, using: .tcp)
        tcpConnection?.stateUpdateHandler = { [weak self] s in
            DispatchQueue.main.async {
                switch s {
                case .ready:
                    self?.log("TCP connected"); self?.updateState(.ready); self?.startReceiving()
                case .failed(let e):
                    self?.log("TCP failed: \(e)"); self?.updateState(.error)
                case .cancelled:
                    self?.updateState(.disconnected)
                default: break
                }
            }
        }
        tcpConnection?.start(queue: .main)
    }

    private func startReceiving() {
        tcpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            if let data = data, !data.isEmpty { self?.handleReceivedData(data) }
            if done || err != nil { DispatchQueue.main.async { self?.updateState(.disconnected) }; return }
            self?.startReceiving()
        }
    }

    private func connectBluetooth() {
        if centralManager == nil { centralManager = CBCentralManager(delegate: self, queue: .main) }
        startBluetoothScan()
    }

    // MARK: - Command Queue

    private func processNextCommand() {
        guard !isProcessingCommand, !commandQueue.isEmpty else { return }
        isProcessingCommand = true
        let cmd = commandQueue.removeFirst()
        currentCommand = cmd; responseBuffer = ""
        writeToTransport((cmd.command + "\r").data(using: .ascii)!)
        log("[TX] \(cmd.command)")
        commandTimer?.invalidate()
        commandTimer = Timer.scheduledTimer(withTimeInterval: cmd.timeout, repeats: false) { [weak self] _ in
            let c = self?.currentCommand
            self?.log("[TIMEOUT] \(c?.command ?? "")")
            self?.currentCommand = nil; self?.isProcessingCommand = false
            c?.completion?("TIMEOUT"); self?.processNextCommand()
        }
    }

    // MARK: - Response Parsing

    private func handleReceivedData(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onRawData?(data)
            guard let str = String(data: data, encoding: .ascii) else { return }
            self.responseBuffer += str
            guard self.responseBuffer.contains(">") else { return }

            let full = self.responseBuffer; self.responseBuffer = ""
            self.commandTimer?.invalidate()
            let parsed = self.parseResponse(full)
            self.log("[RX] \(parsed)")

            // NRC 0x21 retry (busyRepeatRequest) — up to 3 times
            if parsed.contains("7F") && parsed.contains("21") {
                if let cmd = self.currentCommand, cmd.retryCount < 3 {
                    self.log("[RETRY] NRC 0x21, attempt \(cmd.retryCount + 1)")
                    var retry = cmd; retry = ELMCommand(cmd.command, timeout: cmd.timeout,
                                                         retryCount: cmd.retryCount + 1, completion: cmd.completion)
                    self.currentCommand = nil; self.isProcessingCommand = false
                    self.commandQueue.insert(retry, at: 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.processNextCommand() }
                    return
                }
            }

            let cmd = self.currentCommand
            self.currentCommand = nil; self.isProcessingCommand = false
            self.onResponse?(parsed)
            cmd?.completion?(parsed); self.processNextCommand()
        }
    }

    private func parseResponse(_ raw: String) -> String {
        var lines = raw.replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\r\n", with: "\r")
            .components(separatedBy: "\r")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FC}", with: "") }
            .filter { !$0.isEmpty }

        // Strip echo
        if let cmd = currentCommand?.command.uppercased(), let first = lines.first?.uppercased(),
           first.hasPrefix(cmd.prefix(min(4, cmd.count))) || first == cmd {
            lines.removeFirst()
        }

        // Filter J1850 bus noise (2D 28 xx xx)
        lines = lines.filter { !$0.hasPrefix("2D 28") && !$0.hasPrefix("2D28") }

        return lines.joined(separator: "\r")
    }

    // MARK: - Helpers

    private func updateState(_ s: ConnectionState) {
        DispatchQueue.main.async { self.state = s; self.log("[STATE] \(s.rawValue)") }
    }

    func log(_ msg: String) {
        DispatchQueue.main.async {
            let ts = Self.tsf.string(from: Date())
            self.logMessages.append("[\(ts)] \(msg)")
            if self.logMessages.count > 500 { self.logMessages.removeFirst(self.logMessages.count - 500) }
        }
    }
    private static let tsf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
}

// MARK: - CBCentralManagerDelegate
extension ELM327Connection: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn && (state == .scanning || state == .connecting) {
            c.scanForPeripherals(withServices: nil, options: nil)
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String:Any], rssi: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        let id = p.identifier.uuidString
        if !discoveredDevices.contains(where: { $0.id == id }) && name != "Unknown" {
            discoveredDevices.append((name: name, id: id))
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        c.stopScan(); p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { updateState(.error) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connectedPeripheral = nil; writeCharacteristic = nil; updateState(.disconnected)
    }
}

// MARK: - CBPeripheralDelegate
extension ELM327Connection: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        p.services?.forEach { p.discoverCharacteristics(nil, for: $0) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        s.characteristics?.forEach { c in
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) { writeCharacteristic = c }
            if c.properties.contains(.notify) { p.setNotifyValue(true, for: c) }
        }
        if writeCharacteristic != nil { updateState(.ready) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let d = c.value { handleReceivedData(d) }
    }
}
