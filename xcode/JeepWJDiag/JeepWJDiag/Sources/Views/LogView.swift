import SwiftUI

struct LogView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics
    @State private var customCommand = ""
    @State private var copyNotice = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top buttons: Clear | Copy Log | Raw Dump
                HStack(spacing: 6) {
                    Button("Clear") { connection.logMessages.removeAll() }
                        .buttonStyle(.bordered).font(.caption)

                    Button("Copy Log") {
                        let text = connection.logMessages.joined(separator: "\n")
                        UIPasteboard.general.string = text
                        copyNotice = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copyNotice = false }
                    }
                    .buttonStyle(.borderedProminent).tint(.green).font(.caption.bold())

                    if copyNotice {
                        Text("Copied \(connection.logMessages.count) lines")
                            .font(.caption2).foregroundColor(.green)
                    }

                    Spacer()

                    Text("\(connection.logMessages.count)")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)

                // Command input
                HStack(spacing: 6) {
                    TextField("21 01 or ATRV", text: $customCommand)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit { sendCommand() }

                    Button("Send") { sendCommand() }
                        .buttonStyle(.borderedProminent).tint(.purple).font(.caption.bold())
                        .disabled(connection.state != .ready || customCommand.isEmpty)
                }
                .padding(.horizontal, 8).padding(.bottom, 4)

                // Log output
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(connection.logMessages.enumerated()), id: \.offset) { i, msg in
                                Text(msg)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(logColor(msg))
                                    .textSelection(.enabled)
                                    .id(i)
                            }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                    }
                    .background(Color.black)
                    .onChange(of: connection.logMessages.count) { _ in
                        if let last = connection.logMessages.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationTitle("Log").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sendCommand() {
        guard !customCommand.isEmpty else { return }
        diagnostics.sendCustomCommand(customCommand)
        customCommand = ""
    }

    private func logColor(_ msg: String) -> Color {
        if msg.contains("[TX]") { return .cyan }
        if msg.contains("[RX]") { return .green }
        if msg.contains("[STATE]") { return .yellow }
        if msg.contains("[NRC]") || msg.contains("failed") || msg.contains("ERROR") { return .red }
        if msg.contains("[TIMEOUT]") { return .orange }
        if msg.contains("BLE") || msg.contains("TCP") { return .purple }
        return Color(.systemGray)
    }
}
