import SwiftUI

struct DTCView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics
    @State private var selectedSource = 0 // 0=TCM, 1=ECU, 2=ABS, 3=ESP
    @State private var isReading = false
    @State private var showClearConfirm = false

    private let sources: [(String, WJModule)] = [
        ("TCM", .kLineTCM), ("ECU", .motorECU), ("ABS", .abs), ("ESP", .espModule)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                // Source selector
                HStack(spacing: 6) {
                    ForEach(0..<sources.count, id: \.self) { i in
                        Button(sources[i].0) { selectedSource = i }
                            .buttonStyle(.borderedProminent)
                            .tint(selectedSource == i ? .green : .gray)
                            .font(.caption.bold())
                    }
                }
                .padding(.horizontal)

                // Buttons
                HStack(spacing: 12) {
                    Button {
                        isReading = true
                        diagnostics.readDTCs(module: sources[selectedSource].1)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { isReading = false }
                    } label: {
                        HStack {
                            if isReading { ProgressView().scaleEffect(0.7) }
                            Text("Read DTC")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                    .disabled(connection.state != .ready || isReading)

                    Button("Clear DTC") { showClearConfirm = true }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .disabled(connection.state != .ready || filteredDTCs.isEmpty)
                }
                .padding(.horizontal)

                Text("\(sources[selectedSource].0): \(filteredDTCs.count) fault codes")
                    .font(.caption).foregroundColor(.secondary)

                // DTC list
                if filteredDTCs.isEmpty {
                    Spacer()
                    Image(systemName: "checkmark.shield").font(.system(size: 40)).foregroundColor(.green.opacity(0.5))
                    Text("No fault codes").foregroundColor(.secondary)
                    Spacer()
                } else {
                    List(filteredDTCs) { dtc in
                        HStack {
                            Text(dtc.code)
                                .font(.system(.headline, design: .monospaced)).foregroundColor(.orange)
                            Spacer()
                            Text(dtc.description).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("DTC").navigationBarTitleDisplayMode(.inline)
            .alert("Clear DTCs?", isPresented: $showClearConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    diagnostics.clearDTCs(module: sources[selectedSource].1)
                }
            }
        }
    }

    private var filteredDTCs: [DTCEntry] {
        diagnostics.dtcList.filter { $0.module == sources[selectedSource].1 }
    }
}
