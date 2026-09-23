import Foundation

/// Placeholder for extended live data features (ESP PID polling etc.)
/// Main ECU/TCM live data is handled by WJDiagnostics directly.
final class LiveDataManager: ObservableObject {
    @Published var isActive = false
}
