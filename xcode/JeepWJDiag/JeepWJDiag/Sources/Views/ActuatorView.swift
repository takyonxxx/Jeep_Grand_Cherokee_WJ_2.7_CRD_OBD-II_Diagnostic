import SwiftUI

struct ActuatorView: View {
    @EnvironmentObject var connection: ELM327Connection
    @EnvironmentObject var diagnostics: WJDiagnostics

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            if let module = diagnostics.activeModule {
                let acts = actuatorsFor(module)
                if acts.isEmpty {
                    Text("No actuator tests for this module").foregroundColor(.secondary)
                        .navigationTitle(actuatorTitle).navigationBarTitleDisplayMode(.inline)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(Array(acts.enumerated()), id: \.offset) { _, act in
                                if act.offCmd != nil {
                                    HoldButton(label: act.name, onCmd: act.onCmd, offCmd: act.offCmd!,
                                               hdr: act.hdr, diagnostics: diagnostics)
                                } else {
                                    PulseButton(label: act.name, cmd: act.onCmd,
                                                hdr: act.hdr, diagnostics: diagnostics)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .scrollDisabled(false)
                    .navigationTitle(actuatorTitle).navigationBarTitleDisplayMode(.inline)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "gearshape.2").font(.system(size: 40)).foregroundColor(.secondary)
                    Text("Select a module from Conn tab\nto see actuator tests")
                        .multilineTextAlignment(.center).foregroundColor(.secondary)
                }.padding(.top, 60)
                .navigationTitle("Actuators").navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var actuatorTitle: String {
        diagnostics.activeModule.map { "Actuators: \($0.displayName)" } ?? "Actuators"
    }

    private func actuatorsFor(_ module: WJModule) -> [ActDef] {
        switch module {
        case .driverDoor:    return doorActs(hdr: "ATSH24A02F")
        case .passengerDoor: return doorActs(hdr: "ATSH24A12F")
        case .bodyComputer:  return bcmActs
        case .cluster:       return clusterActs
        case .atc:           return hvacActs
        case .skim:          return skimActs
        case .overhead:      return overheadActs
        case .motorECU:      return ecuActs
        case .kLineTCM:      return tcmActs
        default: return []
        }
    }

    private func doorActs(hdr: String) -> [ActDef] {
        [("Courtesy Lamp","38 00 12","38 00 00"),("Front Win UP","38 01 12","38 01 00"),
         ("Front Win DOWN","38 02 12","38 02 00"),("Rear Win UP","38 03 12","38 03 00"),
         ("Rear Win DOWN","38 04 12","38 04 00"),("Lock","38 05 12","38 05 00"),
         ("Unlock","38 06 12","38 06 00"),("Mirror UP","38 07 12","38 07 00"),
         ("Mirror DOWN","38 08 12","38 08 00"),("Mirror LEFT","38 09 12","38 09 00"),
         ("Mirror RIGHT","38 0A 12","38 0A 00"),("Foldaway IN","38 0B 12","38 0B 00"),
         ("Foldaway OUT","38 0C 12","38 0C 00"),("Mirror Heater","38 0D 12","38 0D 00"),
         ("Switch Illum","38 0E 12","38 0E 00"),("Memory LED","38 0F 12","38 0F 00")]
            .map { ActDef(name: $0.0, onCmd: $0.1, offCmd: $0.2, hdr: hdr) }
    }
    private var bcmActs: [ActDef] {
        let h = "ATSH24402F"
        return [("VTSS Lamp","38 07 01","38 07 00"),("Front Fog","38 06 02","38 06 00"),
                ("Chime","38 02 01","38 02 00"),("Hi Beam","38 06 08","38 06 00"),
                ("Rear Fog","38 06 10","38 06 00"),("Hazard","38 06 20","38 06 00"),
                ("Wiper","38 08 01","38 08 00"),("Park Lamp","38 06 04","38 06 00"),
                ("Horn","38 0D 01","38 0D 00")]
            .map { ActDef(name: $0.0, onCmd: $0.1, offCmd: $0.2, hdr: h) }
        + [ActDef(name: "Low Beam", onCmd: "3A 02 FF", offCmd: nil, hdr: h)]
    }
    private var clusterActs: [ActDef] {
        let h = "ATSH246122"
        return [("Speedo","3A 00 80","3A 00 00"),("Tacho","3A 00 40","3A 00 00"),
                ("3 Led","3A 00 20","3A 00 00"),("4 Led","3A 00 10","3A 00 00"),
                ("Fuel/Drive","3A 00 08","3A 00 00"),("Temp/Neutral","3A 00 04","3A 00 00"),
                ("Reverse Led","3A 00 02","3A 00 00"),("Park Led","3A 00 01","3A 00 00"),
                ("Oil/4Hi Led","3A 01 01","3A 01 00"),("T-Case Ntrl","3A 01 02","3A 01 00"),
                ("CE/4Low Led","3A 01 04","3A 01 00")]
            .map { ActDef(name: $0.0, onCmd: $0.1, offCmd: $0.2, hdr: h) }
    }
    private var hvacActs: [ActDef] {
        [ActDef(name:"Reset Module",onCmd:"01 01 00",offCmd:nil,hdr:"ATSH249811"),
         ActDef(name:"Self Test",onCmd:"01 FF FF",offCmd:nil,hdr:"ATSH249830"),
         ActDef(name:"Full Def",onCmd:"02 FF FF",offCmd:nil,hdr:"ATSH249830"),
         ActDef(name:"Full Panel",onCmd:"03 FF FF",offCmd:nil,hdr:"ATSH249830"),
         ActDef(name:"Drv Blend Hot",onCmd:"38 03 00",offCmd:nil,hdr:"ATSH24982F"),
         ActDef(name:"Drv Blend Cold",onCmd:"38 04 00",offCmd:nil,hdr:"ATSH24982F"),
         ActDef(name:"Pas Blend Hot",onCmd:"38 07 00",offCmd:nil,hdr:"ATSH24982F"),
         ActDef(name:"Pas Blend Cold",onCmd:"38 08 00",offCmd:nil,hdr:"ATSH24982F"),
         ActDef(name:"Recirc Fresh",onCmd:"38 0B 00",offCmd:nil,hdr:"ATSH24982F"),
         ActDef(name:"Recirc Recirc",onCmd:"38 0C 00",offCmd:nil,hdr:"ATSH24982F")]
    }
    private var skimActs: [ActDef] {
        [ActDef(name:"Reset Module",onCmd:"01 01 00",offCmd:nil,hdr:"ATSH24C011"),
         ActDef(name:"Indicator Lamp",onCmd:"38 00 01",offCmd:"38 00 00",hdr:"ATSH24C02F"),
         ActDef(name:"View VIN",onCmd:"28 10 00",offCmd:nil,hdr:"ATSH24C022")]
    }
    private var overheadActs: [ActDef] {
        [ActDef(name:"Self Test 0x31",onCmd:"01 00 00",offCmd:nil,hdr:"ATSH246831"),
         ActDef(name:"Self Test 0x33",onCmd:"01 00 00",offCmd:nil,hdr:"ATSH246833"),
         ActDef(name:"Reset Module",onCmd:"01 01 00",offCmd:nil,hdr:"ATSH246811")]
    }
    private var ecuActs: [ActDef] {
        [("EGR Solenoid","30 11 07 13 88","30 11 07 00 00"),
         ("Cabin Heater","30 1C 07 27 10","30 1C 07 00 00"),
         ("Glow Plug 1","30 16 07 27 10","30 16 07 00 00"),
         ("Glow Plug 2","30 17 07 27 10","30 17 07 00 00"),
         ("A/C Control","30 14 07 27 10","30 14 07 00 00"),
         ("SWIRL Sol","30 1A 07 13 88","30 1A 07 00 00"),
         ("Boost Press","30 12 07 00 10","30 12 07 00 00"),
         ("Fan Low","30 18 07 08 34","30 18 07 00 00"),
         ("Fan Full","30 18 07 21 34","30 18 07 00 00")]
            .map { ActDef(name: $0.0, onCmd: $0.1, offCmd: $0.2, hdr: nil) }
    }
    private var tcmActs: [ActDef] {
        [ActDef(name:"Reset Adapt",onCmd:"31 31",offCmd:nil,hdr:nil),
         ActDef(name:"Store Adapt",onCmd:"31 32",offCmd:nil,hdr:nil),
         ActDef(name:"Solenoid Test",onCmd:"30 10 07 00 02",offCmd:"30 10 07 00 00",hdr:nil),
         ActDef(name:"Park Lockout",onCmd:"30 10 07 04 00",offCmd:nil,hdr:nil)]
    }
}

struct ActDef: Identifiable {
    var id: String { name + onCmd }
    let name: String
    let onCmd: String
    let offCmd: String?
    let hdr: String?
}
