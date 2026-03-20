import Foundation

// MARK: - Transport / Protocol

enum ELMTransport: String, CaseIterable {
    case wifi = "WiFi"
    case bluetooth = "Bluetooth"
}

enum ELMProtocol: Int, CaseIterable {
    case auto = 0, j1850PWM = 1, j1850VPW = 2, iso9141 = 3
    case kwp5Baud = 4, kwpFast = 5
    case can11_500 = 6, can29_500 = 7, can11_250 = 8, can29_250 = 9

    var atCommand: String { "ATSP\(rawValue)" }
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .j1850PWM: return "J1850 PWM"
        case .j1850VPW: return "J1850 VPW"
        case .iso9141: return "ISO 9141-2"
        case .kwp5Baud: return "KWP2000 (5 Baud)"
        case .kwpFast: return "KWP2000 (Fast)"
        case .can11_500: return "CAN 11/500k"
        case .can29_500: return "CAN 29/500k"
        case .can11_250: return "CAN 11/250k"
        case .can29_250: return "CAN 29/250k"
        }
    }
}

enum ConnectionState: String {
    case disconnected = "Disconnected"
    case scanning = "Scanning"
    case connecting = "Connecting"
    case initializing = "Initializing"
    case ready = "Ready"
    case busy = "Busy"
    case error = "Error"
}

// MARK: - Bus Type

enum BusType {
    case kLine
    case j1850
}

// MARK: - Module Definitions (Verified 20 modules)

enum WJModule: UInt8, CaseIterable, Identifiable {
    case motorECU       = 0x15  // K-Line, Bosch EDC15C2 OM612
    case kLineTCM       = 0x20  // K-Line, NAG1 722.6
    case abs            = 0x28  // J1850
    case adjustablePedal = 0x2A // J1850, NO DATA
    case bodyComputer   = 0x40  // J1850
    case espModule      = 0x58  // J1850
    case electroCluster = 0x60  // J1850, NRC 7F 22 22
    case cluster        = 0x61  // J1850
    case overhead       = 0x68  // J1850
    case navigation     = 0x6D  // J1850, 62 00 00 00
    case radio          = 0x80  // J1850, NO DATA
    case cdChanger      = 0x81  // J1850, 62 00 00 00
    case parkAssist     = 0x62  // J1850, 62 00 00 00
    case satAudio       = 0x87  // J1850, 62 00 00 00
    case handsFree      = 0x90  // J1850, 62 00 00 00
    case atc            = 0x98  // J1850
    case driverDoor     = 0xA0  // J1850
    case passengerDoor  = 0xA1  // J1850
    case rainSensor     = 0xA7  // J1850
    case skim           = 0xC0  // J1850

    var id: UInt8 { rawValue }

    var bus: BusType {
        switch self {
        case .motorECU, .kLineTCM: return .kLine
        default: return .j1850
        }
    }

    var displayName: String {
        switch self {
        case .motorECU: return "Engine ECU (EDC15C2)"
        case .kLineTCM: return "Transmission (NAG1)"
        case .abs: return "ABS"
        case .adjustablePedal: return "Adjustable Pedal"
        case .bodyComputer: return "Body Computer (BCM)"
        case .espModule: return "ESP / Traction"
        case .electroCluster: return "Electro Mech Cluster"
        case .cluster: return "Instrument Cluster"
        case .overhead: return "Overhead Console"
        case .navigation: return "Navigation"
        case .radio: return "Radio"
        case .cdChanger: return "CD Changer"
        case .parkAssist: return "Park Assist"
        case .satAudio: return "Satellite Audio"
        case .handsFree: return "Hands Free"
        case .atc: return "HVAC / ATC"
        case .driverDoor: return "Driver Door"
        case .passengerDoor: return "Passenger Door"
        case .rainSensor: return "Rain Sensor"
        case .skim: return "SKIM / Immobilizer"
        }
    }

    /// Modules confirmed as non-responsive
    var isNoData: Bool {
        switch self {
        case .radio, .adjustablePedal: return true  // NO DATA
        default: return false
        }
    }

    /// Modules that return NRC on all commands
    var isAlwaysNRC: Bool {
        switch self {
        case .electroCluster: return true  // NRC 7F 22 22
        default: return false
        }
    }

    /// Modules returning 62 00 00 00 on all reads
    var isStubResponse: Bool {
        switch self {
        case .navigation, .cdChanger, .parkAssist, .satAudio, .handsFree: return true
        default: return false
        }
    }
}

// MARK: - DTC

struct DTCEntry: Identifiable {
    let id = UUID()
    let module: WJModule
    let code: String
    let description: String
}

// MARK: - ECU Status (Dashboard - Verified Formulas from RELAY_MAP)

struct ECUStatus {
    // Block 0x28[0-1]: raw RPM (overrides 0x12)
    var rpm: Double = 0
    // Block 0x22[0-1]: /10 - 273.1 = C
    var coolantTemp: Double = 0
    // Block 0x22[14-15]: /1000 = Bar (MAP/1000)
    var boostPressure: Double = 0
    // Block 0x12[18-19]: *0.101 = Bar (constant 0.101, NOT /10!)
    var railPressure: Double = 0
    // Block 0x36[6-7]: /10 = Mg/Str
    var mafFlow: Double = 0
    // Block 0x32[0-1]: /100 = mg/str (actual fuel qty)
    var fuelQuantity: Double = 0
    // Block 0x16[2-3]: *5/3072 = V
    var batteryVoltage: Double = 0
    // Block 0x26[2-3]: /100 = km/h
    var vehicleSpeed: Double = 0
    // Block 0x21[14-15]: /10 = %
    var fuelLevel: Double = 0
    // Block 0x21[16-17]: /100 = V
    var fuelSensorVoltage: Double = 0
    // Block 0x28[2-3]: /100 = mg/str
    var injectionQty: Double = 0
    // Block 0x28[4-13]: per-cylinder RPMs
    var cylRPMs: [Double] = Array(repeating: 0, count: 5)
    // Block 0x28[20-25]: signed /100 = mg/str injection corrections
    var injCorrections: [Double] = Array(repeating: 0, count: 3)
    // Computed: fuel flow (OM612 5-cyl diesel)
    var fuelFlowLH: Double = 0      // L/h instantaneous
    var fuelLPer100km: Double = 0   // L/100km instantaneous
}

// MARK: - TCM Status (Dashboard - Verified from RELAY_MAP)

struct TCMStatus {
    // Block 0x30[9]: 0=P/N, 1-5=gear
    var gear: Gear = .unknown
    // Block 0x30[7]: P=8, R=7, N=6, D=5
    var selector: UInt8 = 0
    // Block 0x30[0-1]: signed raw RPM
    var actualTCCSlip: Double = 0
    // Block 0x30[4-5]: raw RPM
    var outputRPM: Double = 0
    // Block 0x30[11]: raw - 50 = C
    var transTemp: Double = 0
    // Block 0x31[4-5]: raw RPM
    var turbineRPM: Double = 0
    // Block 0x31[6-7]: raw RPM
    var engineRPM: Double = 0
    // Block 0x31[0-1]: raw RPM
    var inputN2: Double = 0
    // Block 0x34[6-7]: /40 = V (solenoid supply)
    var solenoidVoltage: Double = 0
    // Block 0x34[8-9]: /154.5 = V
    var batteryVoltage: Double = 0
    // Block 0x32[0]: single byte km/h
    var vehicleSpeed: Double = 0
    // Block 0x33: pressures
    var tccPressure: Double = 0      // /1000 = Bar
    var shiftPressure: Double = 0    // /365 = Bar
    var modulationPressure: Double = 0 // /462 = Bar

    enum Gear: String, CaseIterable {
        case park = "P", reverse = "R", neutral = "N"
        case drive1 = "D1", drive2 = "D2", drive3 = "D3", drive4 = "D4", drive5 = "D5"
        case limp = "LIMP!", unknown = "?"

        /// Qt color: D1-D5 = green (#00ffa0), P/N/R = amber (#d0a040), LIMP = red
        var color: String {
            switch self {
            case .drive1, .drive2, .drive3, .drive4, .drive5: return "green"
            case .park, .neutral, .reverse: return "amber"
            case .limp: return "red"
            case .unknown: return "gray"
            }
        }
    }
}

// MARK: - Command Queue Entry

struct ELMCommand {
    let command: String
    let timeout: TimeInterval
    let completion: ((String) -> Void)?
    var retryCount: Int

    init(_ command: String, timeout: TimeInterval = 5.0, retryCount: Int = 0, completion: ((String) -> Void)? = nil) {
        self.command = command
        self.timeout = timeout
        self.retryCount = retryCount
        self.completion = completion
    }
}
