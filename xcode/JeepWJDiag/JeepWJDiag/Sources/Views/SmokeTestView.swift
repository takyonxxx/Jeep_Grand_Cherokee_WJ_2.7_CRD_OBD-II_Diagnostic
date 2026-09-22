import SwiftUI
import UIKit

/// Black-smoke transient test: records the fuel / air / boost / rail values at
/// high rate while the driver floors the pedal, then shares the log via
/// WhatsApp (text) or the iOS share sheet (file).
struct SmokeTestView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var notice = ""
    @State private var showSummary = false

    private var session: SmokeTestSession { diagnostics.smokeTest }
    private var ecu: ECUStatus { diagnostics.ecuStatus }
    private let orange = Color(red: 0.85, green: 0.45, blue: 0.0)

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                instructions
                liveGrid
                controlRow
                if !notice.isEmpty {
                    Text(notice).font(.caption).foregroundColor(.green)
                }
                if session.hasData && !session.isRecording {
                    shareRow
                    summaryBox
                }
                if let err = session.error {
                    Text(err).font(.caption).foregroundColor(.red)
                }
            }
            .padding(8)
        }
        .navigationTitle("Smoke Test").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }

    // MARK: - Sections

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Kara Duman Testi").font(.system(size: 14, weight: .bold))
            Group {
                Text("1. Motor sıcak olsun (>70°C). ELM bağlı olsun, modül seçmeye gerek yok.")
                Text("2. START'a bas, 3 sn rölantide bekle.")
                Text("3. Yolda 2. viteste ~1500 rpm'den gaza SONUNA KADAR bas, 3500+ rpm'e çek.")
                Text("4. Duman görüldüğü an MARK'a bas (yolcu bassın).")
                Text("5. Durunca N'de 2 kez ani gaz ver, sonra STOP.")
                Text("6. WhatsApp ile logu gönder.")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(.systemGray6))
        .cornerRadius(6)
    }

    private var liveGrid: some View {
        let fuel = ecu.fuelQuantity > 0 ? ecu.fuelQuantity : ecu.injectionQty
        let af = fuel > 0.5 ? ecu.mafFlow / fuel : 0
        return VStack(spacing: 3) {
            HStack(spacing: 3) {
                GaugeCell(title: "RPM", value: String(format: "%.0f", ecu.rpm), unit: "rpm",
                          color: ecu.rpm > 4500 ? .red : .green)
                GaugeCell(title: "PEDAL", value: String(format: "%.0f", ecu.pedalPos), unit: "%",
                          color: ecu.pedalPos > 60 ? .orange : .green)
                GaugeCell(title: "FUEL", value: String(format: "%.1f", fuel), unit: "mg/str")
                GaugeCell(title: "MAF", value: String(format: "%.0f", ecu.mafFlow), unit: "mg/str")
            }
            HStack(spacing: 3) {
                GaugeCell(title: "A/F", value: af > 0 ? String(format: "%.1f", af) : "-", unit: "air/fuel",
                          color: af == 0 ? .gray : af < 15 ? .red : af < 17 ? .orange : .green)
                GaugeCell(title: "BOOST", value: String(format: "%.2f", ecu.boostPressure), unit: "bar abs")
                GaugeCell(title: "B-SET", value: String(format: "%.2f", ecu.boostSetpoint), unit: "bar abs",
                          color: (ecu.boostSetpoint - ecu.boostPressure) > 0.4 && ecu.pedalPos > 50 ? .red : .green)
                GaugeCell(title: "RAIL", value: String(format: "%.0f", ecu.railPressure), unit: "bar")
            }
            HStack(spacing: 3) {
                GaugeCell(title: "M-TEMP", value: String(format: "%.0f", ecu.coolantTemp), unit: "C",
                          color: ecu.coolantTemp < 70 ? .orange : .green)
                GaugeCell(title: "IAT", value: String(format: "%.0f", ecu.iat), unit: "C")
                GaugeCell(title: "TIME", value: String(format: "%.1f", session.duration), unit: "s",
                          color: session.isRecording ? .green : .gray)
                GaugeCell(title: "SAMPLES", value: "\(session.samples.count)", unit: "\(session.marks.count) marks",
                          color: session.isRecording ? .green : .gray)
            }
        }
    }

    private var controlRow: some View {
        HStack(spacing: 8) {
            if session.isRecording {
                Button("STOP") { diagnostics.stopSmokeTest(); showSummary = true }
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.red).cornerRadius(8)

                Button("MARK\nSMOKE") { diagnostics.smokeTestMark() }
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.yellow).cornerRadius(8)
            } else {
                Button("START") { notice = ""; showSummary = false; diagnostics.startSmokeTest() }
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(connection.state == .ready ? orange : Color.gray).cornerRadius(8)
                    .disabled(connection.state != .ready)
                if session.hasData {
                    Button("Clear") { diagnostics.clearSmokeTest(); notice = ""; showSummary = false }
                        .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        .frame(width: 80, height: 54)
                        .background(Color(.systemGray3)).cornerRadius(8)
                }
            }
        }
    }

    private var shareRow: some View {
        HStack(spacing: 8) {
            Button {
                shareToWhatsApp()
            } label: {
                Label("WhatsApp", systemImage: "paperplane.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(red: 0.14, green: 0.66, blue: 0.33)).cornerRadius(8)
            }
            Button {
                shareFile()
            } label: {
                Label("Share file", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.blue).cornerRadius(8)
            }
            Button {
                UIPasteboard.general.string = session.reportText()
                flash("Copied to clipboard")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    .frame(width: 48, height: 44)
                    .background(Color(.systemGray3)).cornerRadius(8)
            }
        }
    }

    private var summaryBox: some View {
        let sum = session.summary()
        return VStack(alignment: .leading, spacing: 4) {
            Text("Summary  (\(session.samples.count) samples, \(String(format: "%.1f", session.duration)) s)")
                .font(.system(size: 12, weight: .bold))
            ForEach(Array(sum.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 10, design: .monospaced)).foregroundColor(.primary)
            }
            if !sum.flags.isEmpty {
                Divider()
                ForEach(Array(sum.flags.enumerated()), id: \.offset) { _, flag in
                    Text("! " + flag).font(.system(size: 10, design: .monospaced)).foregroundColor(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.black.opacity(0.3))
        .cornerRadius(6)
    }

    // MARK: - Sharing

    /// WhatsApp accepts long messages through its URL scheme; the report is
    /// summary + CSV so the whole log lands in the chat as text. Falls back to
    /// the share sheet when WhatsApp is not installed.
    private func shareToWhatsApp() {
        let text = session.reportText()
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "whatsapp://send?text=" + encoded),
              UIApplication.shared.canOpenURL(url) else {
            flash("WhatsApp not available, using share sheet")
            shareFile()
            return
        }
        UIApplication.shared.open(url)
    }

    private func shareFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(session.fileName())
        do {
            try session.reportText().write(to: url, atomically: true, encoding: .utf8)
            shareItems = [url]
            showShare = true
        } catch {
            shareItems = [session.reportText()]
            showShare = true
        }
    }

    private func flash(_ msg: String) {
        notice = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if notice == msg { notice = "" } }
    }
}

// MARK: - UIActivityViewController wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
