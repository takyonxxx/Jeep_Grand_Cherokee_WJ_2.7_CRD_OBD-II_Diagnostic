import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics
    @State private var selectedModule: WJModule?
    @State private var isSwitching = false
    @State private var bleStatus = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DashboardPanel(selectedModule: selectedModule)
                    .environmentObject(diagnostics)
                Divider()
                ScrollView {
                    VStack(spacing: 6) {
                        connectionCard
                        moduleList
                    }
                    .padding(6)
                }
            }
            .navigationTitle("JeepWjDiag").navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Connection Card

    private var connectionCard: some View {
        VStack(spacing: 8) {
            // Status row
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(connection.state.rawValue)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                if !bleStatus.isEmpty {
                    Text(bleStatus).font(.system(size: 11)).foregroundColor(.orange).lineLimit(1)
                }
                Spacer()
                if connection.state == .ready || connection.state == .busy {
                    Button("Disconnect") {
                        diagnostics.stopLiveData(); diagnostics.activeModule = nil
                        selectedModule = nil; connection.disconnect()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.red).cornerRadius(4)
                }
            }

            // WiFi row
            HStack(spacing: 6) {
                Text("WiFi").font(.system(size: 12, weight: .medium)).frame(width: 32, alignment: .leading)
                TextField("192.168.0.10", text: $connection.wifiHost)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(6).background(Color(.systemGray5)).cornerRadius(4)
                    .keyboardType(.decimalPad)
                TextField("35000", value: $connection.wifiPort, format: .number)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(6).background(Color(.systemGray5)).cornerRadius(4)
                    .frame(width: 64).keyboardType(.numberPad)
                Button("Connect") { connection.connect() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(connection.state == .disconnected || connection.state == .error ? Color.green : Color.gray)
                    .cornerRadius(4)
                    .disabled(connection.state != .disconnected && connection.state != .error)
            }

            // BLE row
            HStack(spacing: 6) {
                Text("BLE").font(.system(size: 12, weight: .medium)).frame(width: 32, alignment: .leading)
                Button("Connect") { startBLEAutoConnect() }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white).frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(connection.state == .disconnected || connection.state == .error ? Color.blue : Color.gray)
                    .cornerRadius(4)
                    .disabled(connection.state != .disconnected && connection.state != .error)
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(6)
    }

    private func startBLEAutoConnect() {
        bleStatus = "Scanning..."
        connection.startBluetoothScan()
        let keywords = ["obd","elm","vlink","v-link","ios-v","veepeak","carista","lelink","icar","viecar","konnwei"]
        func check(n: Int) {
            guard n < 50 else { bleStatus = "No OBD device found"; return }
            for d in connection.discoveredDevices {
                if keywords.contains(where: { d.name.lowercased().contains($0) }) {
                    bleStatus = "Found: \(d.name)"
                    connection.connectToDevice(id: d.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if connection.state == .ready { bleStatus = "" } }
                    return
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check(n: n + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check(n: 0) }
    }

    // MARK: - Module List

    private var moduleList: some View {
        VStack(spacing: 2) {
            ForEach(moduleEntries, id: \.module) { entry in
                Button { toggleModule(entry.module) } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(selectedModule == entry.module ? Color.green : Color(.systemGray4))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.label)
                                .font(.system(size: 13, weight: selectedModule == entry.module ? .bold : .medium))
                            Text(entry.detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(selectedModule == entry.module ? .green.opacity(0.7) : .secondary)
                        }
                        Spacer()
                        if selectedModule == entry.module {
                            Image(systemName: "checkmark").foregroundColor(.green).font(.system(size: 11, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selectedModule == entry.module ? Color.green.opacity(0.1) : Color(.systemGray6))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .foregroundColor(selectedModule == entry.module ? .green : .primary)
                .disabled(connection.state != .ready || isSwitching)
                .opacity((connection.state != .ready || isSwitching) ? 0.4 : 1)
            }
        }
    }

    private func toggleModule(_ module: WJModule) {
        if selectedModule == module {
            diagnostics.stopLiveData(); diagnostics.activeModule = nil; selectedModule = nil; return
        }
        isSwitching = true; diagnostics.stopLiveData()
        diagnostics.initModule(module) { ok in
            isSwitching = false
            if ok {
                selectedModule = module; diagnostics.activeModule = module
                // Live data is NOT auto-started - user starts via dashboard button
            }
        }
    }

    private var statusColor: Color {
        switch connection.state {
        case .disconnected: return .gray; case .scanning, .connecting, .initializing: return .orange
        case .ready: return .green; case .busy: return .yellow; case .error: return .red
        }
    }
}

struct ModuleEntry { let module: WJModule; let label: String; let detail: String }

let moduleEntries: [ModuleEntry] = [
    .init(module: .motorECU, label: "1. Engine ECU", detail: "K-Line 0x15 | EDC15C2 | 14-block + 9 acts"),
    .init(module: .kLineTCM, label: "2. Transmission", detail: "K-Line 0x20 | NAG1 722.6 | 5-block + 4 tests"),
    .init(module: .abs, label: "3. ABS", detail: "J1850 0x28 | 12 valve tests"),
    .init(module: .espModule, label: "4. ESP / Traction", detail: "J1850 0x58 | 50 PIDs"),
    .init(module: .cluster, label: "5. Instrument Cluster", detail: "J1850 0x61 | gauge tests"),
    .init(module: .skim, label: "6. SKIM", detail: "J1850 0xC0 | VIN + keys"),
    .init(module: .bodyComputer, label: "7. Body Computer", detail: "J1850 0x40 | 14 relays"),
    .init(module: .atc, label: "8. HVAC / ATC", detail: "J1850 0x98 | 10 motor tests"),
    .init(module: .driverDoor, label: "9. Driver Door", detail: "J1850 0xA0 | 16 actuators"),
    .init(module: .passengerDoor, label: "10. Passenger Door", detail: "J1850 0xA1 | 15 actuators"),
    .init(module: .electroCluster, label: "11. Electro Cluster", detail: "J1850 0x60 | NRC"),
    .init(module: .overhead, label: "12. Overhead", detail: "J1850 0x68"),
    .init(module: .navigation, label: "13. Navigation", detail: "J1850 0x6D"),
    .init(module: .radio, label: "14. Radio", detail: "J1850 0x80 | NO DATA"),
    .init(module: .cdChanger, label: "15. CD Changer", detail: "J1850 0x81"),
    .init(module: .parkAssist, label: "16. Park Assist", detail: "J1850 0x62"),
    .init(module: .rainSensor, label: "17. Rain Sensor", detail: "J1850 0xA7"),
    .init(module: .adjustablePedal, label: "18. Adj. Pedal", detail: "J1850 0x2A | NO DATA"),
    .init(module: .satAudio, label: "19. Sat Audio", detail: "J1850 0x87"),
    .init(module: .handsFree, label: "20. Hands Free", detail: "J1850 0x90"),
]
