import SwiftUI

/// Dashboard panel shown above tabs. Layout changes based on selected module.
/// ECU: big FUEL center (L/h + fuel level), surrounding engine gauges
/// TCM: big GEAR center, surrounding transmission gauges
struct DashboardPanel: View {
    @EnvironmentObject var diagnostics: WJDiagnostics
    let selectedModule: WJModule?

    var body: some View {
        VStack(spacing: 2) {
            // Live data control bar (only for ECU/TCM)
            if selectedModule == .motorECU || selectedModule == .kLineTCM {
                HStack(spacing: 8) {
                    Circle().fill(diagnostics.isPollingLive ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(diagnostics.isPollingLive ? "LIVE" : "Stopped")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(diagnostics.isPollingLive ? .green : .secondary)
                    Spacer()
                    if diagnostics.isPollingLive {
                        Button("Stop") { diagnostics.stopLiveData() }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14).padding(.vertical, 4)
                            .background(Color.red).cornerRadius(4)
                    } else {
                        Button("Start Live") {
                            if selectedModule == .motorECU { diagnostics.startECULiveData() }
                            else if selectedModule == .kLineTCM { diagnostics.startTCMLiveData() }
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .background(Color(red: 0.85, green: 0.45, blue: 0.0)).cornerRadius(4)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
            }

            // Dashboard gauges
            if selectedModule == .kLineTCM {
                tcmDashboard
            } else {
                ecuDashboard
            }
        }
        .padding(4)
    }

    // MARK: - ECU Dashboard (Qt layout: SPEED | FUEL(2x2) | INJ-Q / RPM | ... | RAIL / BOOST | M-TEMP | MAF | BATT)

    private var ecuDashboard: some View {
        let ecu = diagnostics.ecuStatus
        return VStack(spacing: 3) {
            // Row 0: SPEED | FUEL (big) | INJ-Q
            HStack(spacing: 3) {
                GaugeCell(title: "SPEED", value: String(format: "%.0f", ecu.vehicleSpeed), unit: "km/h")
                // Big FUEL center
                VStack(spacing: 0) {
                    Text("FUEL").font(.system(size: 11)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    let fuelVal = ecu.vehicleSpeed > 5 ? ecu.fuelLPer100km : ecu.fuelFlowLH
                    Text(String(format: "%.1f", fuelVal))
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(ecu.vehicleSpeed > 5 ? "L/100km" : "L/h")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    // Fuel level sub-row
                    if ecu.fuelLevel > 0 {
                        let liters = ecu.fuelLevel * 78.7 / 100.0
                        let col = liters < 10 ? Color.red : liters < 20 ? Color.orange : Color.cyan
                        Text(String(format: "%.1f L", liters))
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(col)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Text(String(format: "(%.0f%%)", ecu.fuelLevel))
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundColor(col)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
                .cornerRadius(8)

                GaugeCell(title: "INJ-Q", value: String(format: "%.1f", ecu.fuelQuantity > 0 ? ecu.fuelQuantity : ecu.injectionQty), unit: "mg/str")
            }

            // Row 1: RPM | (fuel spans) | RAIL
            HStack(spacing: 3) {
                GaugeCell(title: "RPM", value: String(format: "%.0f", ecu.rpm), unit: "rpm",
                          color: ecu.rpm > 4500 ? .red : ecu.rpm > 3500 ? .orange : .green)
                Spacer()
                GaugeCell(title: "RAIL", value: String(format: "%.0f", ecu.railPressure), unit: "bar",
                          color: ecu.railPressure > 1400 ? .red : .green)
            }

            // Row 2: BOOST | M-TEMP | MAF | BATT
            HStack(spacing: 3) {
                GaugeCell(title: "BOOST", value: String(format: "%.2f", ecu.boostPressure), unit: "Bar",
                          color: ecu.boostPressure > 2.0 ? .red : .green)
                GaugeCell(title: "M-TEMP", value: String(format: "%.0f", ecu.coolantTemp), unit: "C",
                          color: ecu.coolantTemp > 105 ? .red : ecu.coolantTemp > 95 ? .orange : .green)
                GaugeCell(title: "MAF", value: String(format: "%.0f", ecu.mafFlow), unit: "mg/s")
                GaugeCell(title: "BATT", value: String(format: "%.1f", ecu.batteryVoltage), unit: "V",
                          color: ecu.batteryVoltage < 11.5 ? .red : .green)
            }
        }
    }

    // MARK: - TCM Dashboard (Qt layout: SPEED | GEAR(2x2) | TURBIN / T-TEMP | ... | LIMP / LINE-P | TCC | SOL V | BATT)

    private var tcmDashboard: some View {
        let tcm = diagnostics.tcmStatus
        return VStack(spacing: 3) {
            // Row 0: SPEED | GEAR (big) | TURBIN
            HStack(spacing: 3) {
                GaugeCell(title: "SPEED", value: String(format: "%.0f", tcm.vehicleSpeed), unit: "km/h")

                // Big GEAR center
                VStack(spacing: 0) {
                    Text("GEAR").font(.system(size: 11)).foregroundColor(.secondary)
                    Text(tcm.gear.rawValue)
                        .font(.system(size: 64, weight: .bold, design: .monospaced))
                        .foregroundColor(gearColor(tcm.gear))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.5), lineWidth: 2))
                .cornerRadius(8)

                GaugeCell(title: "TURBIN", value: String(format: "%.0f", tcm.turbineRPM), unit: "rpm")
            }

            // Row 1: T-TEMP | (gear spans) | LIMP
            HStack(spacing: 3) {
                GaugeCell(title: "T-TEMP", value: String(format: "%.0f", tcm.transTemp), unit: "C",
                          color: tcm.transTemp > 105 ? .red : tcm.transTemp > 95 ? .orange : .green)
                Spacer()
                GaugeCell(title: "LIMP", value: "Normal", unit: "", color: .green)
            }

            // Row 2: LINE-P | TCC | SOL V | BATT
            HStack(spacing: 3) {
                GaugeCell(title: "LINE-P", value: String(format: "%.2f", tcm.shiftPressure), unit: "Bar")
                GaugeCell(title: "TCC", value: String(format: "%.0f", tcm.actualTCCSlip), unit: "rpm")
                GaugeCell(title: "SOL V", value: String(format: "%.1f", tcm.solenoidVoltage), unit: "V",
                          color: tcm.solenoidVoltage < 9 ? .red : tcm.solenoidVoltage < 11 ? .orange : .green)
                GaugeCell(title: "BATT", value: String(format: "%.1f", tcm.batteryVoltage), unit: "V",
                          color: tcm.batteryVoltage < 11.5 ? .red : .green)
            }
        }
    }
}

// Qt: D1-D5=#00ffa0 (green), P/N/R=#d0a040 (amber), LIMP=red
private func gearColor(_ gear: TCMStatus.Gear) -> Color {
    switch gear {
    case .drive1, .drive2, .drive3, .drive4, .drive5:
        return Color(red: 0, green: 1, blue: 0.63) // #00ffa0
    case .park, .neutral:
        return Color(red: 0.82, green: 0.63, blue: 0.25) // #d0a040
    case .reverse:
        return Color(red: 0.82, green: 0.63, blue: 0.25) // #d0a040
    case .limp:
        return .red
    case .unknown:
        return .gray
    }
}

struct GaugeCell: View {
    let title: String
    let value: String
    let unit: String
    var color: Color = .green

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 10)).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(unit)
                .font(.system(size: 9)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Color(.systemGray6))
        .cornerRadius(6)
    }
}
