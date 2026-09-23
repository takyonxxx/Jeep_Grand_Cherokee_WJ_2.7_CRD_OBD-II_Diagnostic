import SwiftUI

// MARK: - Hold Button

/// ForEach-safe hold button. Uses @State (not @GestureState) to survive ForEach redraws.
/// The gesture is a LongPress sequenced with Drag, applied as simultaneousGesture
/// so it doesn't conflict with ScrollView.
struct HoldButton: View {
    let label: String
    let onCmd: String
    let offCmd: String
    let hdr: String?
    let diagnostics: WJDiagnostics
    
    @State private var isActive = false

    var body: some View {
        HoldButtonContent(label: label, isActive: $isActive)
            .onChange(of: isActive) { active in
                if active {
                    if let h = hdr { diagnostics.sendCustomCommand(h) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (hdr != nil ? 0.15 : 0)) {
                        diagnostics.sendCustomCommand(onCmd)
                    }
                } else {
                    if let h = hdr { diagnostics.sendCustomCommand(h) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (hdr != nil ? 0.15 : 0)) {
                        diagnostics.sendCustomCommand(offCmd)
                    }
                }
            }
    }
}

/// Inner content view that owns the gesture - separated to give SwiftUI stable identity
private struct HoldButtonContent: View {
    let label: String
    @Binding var isActive: Bool
    @GestureState private var pressing = false

    var body: some View {
        let press = LongPressGesture(minimumDuration: 0.001)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($pressing) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }

        Text(label)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(pressing ? .white : .primary)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(pressing ? Color.green : Color(.systemGray5))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(pressing ? Color.green : Color(.systemGray4),
                            lineWidth: pressing ? 2.5 : 1)
            )
            .cornerRadius(10)
            .scaleEffect(pressing ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: pressing)
            .gesture(press)
            .onChange(of: pressing) { p in
                isActive = p
            }
    }
}

// MARK: - Pulse Button

struct PulseButton: View {
    let label: String
    let cmd: String
    let hdr: String?
    let diagnostics: WJDiagnostics

    var body: some View {
        Button {
            if let h = hdr { diagnostics.sendCustomCommand(h) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (hdr != nil ? 0.15 : 0)) {
                diagnostics.sendCustomCommand(cmd)
            }
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(PulseButtonStyle())
    }
}

struct PulseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .white : .primary)
            .background(configuration.isPressed ? Color.green : Color(.systemGray5))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(configuration.isPressed ? Color.green : Color(.systemGray4),
                            lineWidth: configuration.isPressed ? 2.5 : 1)
            )
            .cornerRadius(10)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}
