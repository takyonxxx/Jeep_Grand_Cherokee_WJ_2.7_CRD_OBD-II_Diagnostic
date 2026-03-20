import SwiftUI

struct MainView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics

    var body: some View {
        TabView {
            ConnectionView()
                .tabItem { Label("Conn", systemImage: "antenna.radiowaves.left.and.right") }
            DTCView()
                .tabItem { Label("DTC", systemImage: "exclamationmark.triangle") }
            ControlsView()
                .tabItem { Label("Ctrl", systemImage: "hand.tap") }
            ActuatorView()
                .tabItem { Label("Acts", systemImage: "gearshape.2") }
            LogView()
                .tabItem { Label("Log", systemImage: "doc.text") }
        }
        .tint(.orange)
    }
}
