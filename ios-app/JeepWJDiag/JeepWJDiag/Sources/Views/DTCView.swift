import SwiftUI

struct DTCView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics
    @State private var selectedSource = 0
    @State private var isReading = false
    @State private var showClearConfirm = false

    private let sources: [(String, WJModule)] = [
        ("TCM", .kLineTCM), ("ECU", .motorECU), ("ABS", .abs), ("Airbag", .espModule)
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                // Source selector
                HStack(spacing: 6) {
                    ForEach(0..<sources.count, id: \.self) { i in
                        Button(sources[i].0) { selectedSource = i }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(selectedSource == i ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(selectedSource == i ? Color(red: 0.85, green: 0.45, blue: 0.0) : Color(.systemGray5))
                            .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 8)

                // Read / Clear
                HStack(spacing: 8) {
                    Button {
                        isReading = true
                        diagnostics.readDTCs(module: sources[selectedSource].1)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { isReading = false }
                    } label: {
                        HStack(spacing: 4) {
                            if isReading { ProgressView().scaleEffect(0.7) }
                            Text("Read DTC")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .cornerRadius(4)
                    }
                    .disabled(connection.state != .ready || isReading)
                    .opacity((connection.state != .ready || isReading) ? 0.5 : 1)

                    Button { showClearConfirm = true } label: {
                        Text("Clear DTC")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red)
                            .cornerRadius(4)
                    }
                    .disabled(connection.state != .ready || filteredDTCs.isEmpty)
                    .opacity((connection.state != .ready || filteredDTCs.isEmpty) ? 0.5 : 1)
                }
                .padding(.horizontal, 8)

                Text("\(sources[selectedSource].0): \(filteredDTCs.count) fault codes")
                    .font(.caption).foregroundColor(.secondary)

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
