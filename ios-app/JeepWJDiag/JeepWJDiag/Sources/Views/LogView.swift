import SwiftUI

struct LogView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics
    @State private var customCommand = ""
    @State private var copyNotice = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top buttons
                HStack(spacing: 6) {
                    Button("Clear") { connection.logMessages.removeAll() }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray3))
                        .cornerRadius(4)

                    Button("Copy Log") {
                        let text = connection.logMessages.joined(separator: "\n")
                        UIPasteboard.general.string = text
                        copyNotice = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copyNotice = false }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.85, green: 0.45, blue: 0.0))
                    .cornerRadius(4)

                    if copyNotice {
                        Text("Copied!")
                            .font(.caption2).foregroundColor(.green)
                    }

                    Spacer()

                    Text("\(connection.logMessages.count)")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)

                // Command input - prominent
                HStack(spacing: 8) {
                    TextField("21 01 or ATRV", text: $customCommand)
                        .autocapitalization(.allCharacters)
                        .disableAutocorrection(true)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .padding(10)
                        .background(Color(.systemGray5))
                        .cornerRadius(4)
                        .onSubmit { sendCommand() }

                    Button("Send") { sendCommand() }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background((connection.state == .ready && !customCommand.isEmpty) ? Color.purple : Color.gray)
                        .cornerRadius(4)
                        .disabled(connection.state != .ready || customCommand.isEmpty)
                }
                .padding(.horizontal, 8).padding(.bottom, 6)

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
