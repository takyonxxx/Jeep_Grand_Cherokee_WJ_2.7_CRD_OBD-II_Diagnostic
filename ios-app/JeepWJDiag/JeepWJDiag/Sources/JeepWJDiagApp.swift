import SwiftUI

@main
struct JeepWJDiagApp: App {
    @StateObject private var connectionManager = ELM327Connection()
    @StateObject private var diagnostics = WJDiagnostics()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(connectionManager)
                .environmentObject(diagnostics)
                .preferredColorScheme(.dark)
                .onAppear {
                    diagnostics.setConnection(connectionManager)
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
