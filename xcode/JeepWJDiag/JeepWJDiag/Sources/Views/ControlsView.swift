import SwiftUI

struct ControlsView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics
    @State private var activeGroup: CtrlGroup = .none
    @State private var isSwitching = false

    enum CtrlGroup { case none, driver, passenger, bcm }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        groupButton("Driver Door", group: .driver, module: .driverDoor)
                        groupButton("Pass. Door", group: .passenger, module: .passengerDoor)
                        groupButton("Body Ctrl", group: .bcm, module: .bodyComputer)
                    }
                    .padding(.horizontal, 8)

                    if isSwitching {
                        ProgressView("Switching...").padding()
                    }

                    switch activeGroup {
                    case .driver:   windowControls(hdr: "ATSH24A02F", label: "Driver Door 0xA0")
                    case .passenger: windowControls(hdr: "ATSH24A12F", label: "Passenger Door 0xA1")
                    case .bcm:      bcmControls
                    case .none:
                        Text("Select a control group").foregroundColor(.secondary).padding(.top, 40)
                    }
                }
                .padding(.top, 8)
            }
            .navigationTitle("Controls").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func groupButton(_ title: String, group: CtrlGroup, module: WJModule) -> some View {
        Button {
            if activeGroup == group { activeGroup = .none; return }
            isSwitching = true
            diagnostics.initModule(module) { ok in
                isSwitching = false
                activeGroup = ok ? group : .none
            }
        } label: {
            Text(title).font(.caption.bold())
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(activeGroup == group ? Color.green.opacity(0.2) : Color(.systemGray5))
                .foregroundColor(activeGroup == group ? .green : .primary)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(activeGroup == group ? Color.green : .clear, lineWidth: 1.5))
                .cornerRadius(8)
        }
        .disabled(connection.state != .ready || isSwitching)
    }

    private func windowControls(hdr: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                HoldButton(label: "Front Window UP",   onCmd: "38 01 12", offCmd: "38 01 00", hdr: hdr, diagnostics: diagnostics)
                HoldButton(label: "Front Window DOWN", onCmd: "38 02 12", offCmd: "38 02 00", hdr: hdr, diagnostics: diagnostics)
                HoldButton(label: "Rear Window UP",    onCmd: "38 03 12", offCmd: "38 03 00", hdr: hdr, diagnostics: diagnostics)
                HoldButton(label: "Rear Window DOWN",  onCmd: "38 04 12", offCmd: "38 04 00", hdr: hdr, diagnostics: diagnostics)
            }.padding(.horizontal, 8)

            HStack(spacing: 6) {
                HoldButton(label: "Lock",   onCmd: "38 05 12", offCmd: "38 05 00", hdr: hdr, diagnostics: diagnostics)
                HoldButton(label: "Unlock", onCmd: "38 06 12", offCmd: "38 06 00", hdr: hdr, diagnostics: diagnostics)
            }.padding(.horizontal, 8)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                HoldButton(label: "Mirror UP",    onCmd: "38 07 12", offCmd: "38 07 00", hdr: hdr, diagnostics: diagnostics)
                HoldButton(label: "Mirror DOWN",  onCmd: "38 08 12", offCmd: "38 08 00", hdr: hdr, diagnostics: diagnostics)
                HoldButton(label: "Mirror LEFT",  onCmd: "38 09 12", offCmd: "38 09 00", hdr: hdr, diagnostics: diagnostics)
                HoldButton(label: "Mirror RIGHT", onCmd: "38 0A 12", offCmd: "38 0A 00", hdr: hdr, diagnostics: diagnostics)
            }.padding(.horizontal, 8)
        }
    }

    private var bcmControls: some View {
        let h = "ATSH24402F"
        return VStack(spacing: 6) {
            Text("Body Computer 0x40").font(.caption).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                HoldButton(label: "Hazard",    onCmd: "38 06 20", offCmd: "38 06 00", hdr: h, diagnostics: diagnostics)
                HoldButton(label: "Horn",      onCmd: "38 0D 01", offCmd: "38 0D 00", hdr: h, diagnostics: diagnostics)
                HoldButton(label: "Hi Beam",   onCmd: "38 06 08", offCmd: "38 06 00", hdr: h, diagnostics: diagnostics)
                HoldButton(label: "Park Lamp", onCmd: "38 06 04", offCmd: "38 06 00", hdr: h, diagnostics: diagnostics)
                HoldButton(label: "Front Fog", onCmd: "38 06 02", offCmd: "38 06 00", hdr: h, diagnostics: diagnostics)
                HoldButton(label: "Rear Fog",  onCmd: "38 06 10", offCmd: "38 06 00", hdr: h, diagnostics: diagnostics)
                HoldButton(label: "Wiper",     onCmd: "38 08 01", offCmd: "38 08 00", hdr: h, diagnostics: diagnostics)
                HoldButton(label: "Chime",     onCmd: "38 02 01", offCmd: "38 02 00", hdr: h, diagnostics: diagnostics)
            }.padding(.horizontal, 8)
        }
    }
}
