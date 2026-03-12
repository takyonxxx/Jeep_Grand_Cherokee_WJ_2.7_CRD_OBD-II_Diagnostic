# WJDiag — Jeep Grand Cherokee WJ 2.7 CRD Diagnostic Tool

## Vehicle: 2003 EU-spec WJ 2.7 CRD (OM612 / NAG1)

Qt6 cross-platform diagnostic application communicating via ELM327 (Bluetooth/WiFi).
Supports K-Line (ISO 14230) and J1850 VPW protocols.

## Module Map — EU WJ 2.7 CRD

| Addr | Module | Bus | Status |
|------|--------|-----|--------|
| 0x15 | Engine ECU (EDC15C2) | K-Line | Full data + security |
| 0x20 | TCM (NAG1 722.6) | K-Line | Full data + security |
| 0x28 | TCM (J1850) | J1850 | Read OK |
| 0x40 | ABS / Door RIGHT | J1850 | Full read + relay |
| 0x58 | ESP / Traction | J1850 | Read OK |
| 0x60 | Airbag (ORC) | J1850 | NRC 0x22 (needs special conditions) |
| 0x61 | Compass / Traveler | J1850 | Read + DTCs |
| 0x68 | Climate (HVAC) | J1850 | Read OK |
| 0x80 | BCM Body Computer | J1850 | Relay control only |
| 0x98 | Memory Seat | J1850 | DTC read only |
| 0xA0 | Door LEFT (Driver) | J1850 | Full read + 16 relay PIDs |
| 0xA1 | Liftgate / HandsFree | J1850 | Read + relay |
| 0xA7 | Siren / Security | J1850 | Read + DTCs |
| 0xC0 | VTSS / Park Assist | J1850 | Read OK |
| 0x2A | EVIC Overhead | J1850 | No response on EU vehicle |

## Controls Tab

- **Front Windows**: Left (0xA0) + Right (0x40) — hold to activate
- **Rear Windows**: Left (0xA0) + Right (0x40) — hold to activate
- **Hazard**: BCM 0x80 toggle (inverted: ON=0x00, OFF=0x01)
- **Horn**: BCM 0x80 hold to honk
- **BCM Lights**: Hi Beam, Low Beam, Park Lamp
- **BCM Extended (0xB4)**: Rear Defog, Fog lights, Wiper, VTSS, Chime, EU Daylights

Dashboard automatically hides when Controls tab is active.

No DiagSession required for relay commands — direct header switch.

## Live Data

- **ECU**: RPM, Coolant, IAT, TPS, MAP, Rail Pressure, Injection Qty, Boost
- **TCM**: Input/Output RPM, Gear, Torque, Shift data, Fluid temp

Note: MAF reads 0 at idle — OM612 is MAP-based, this is normal.

## ESP32-S2 Emulator

WiFi AP emulator for development and testing without a real vehicle.

- **Hardware**: SparkFun ESP32-S2 Thing Plus C
- **WiFi**: AP "WiFi_OBDII", IP 192.168.0.10, TCP port 35000
- **HTTP Dashboard**: http://192.168.0.10/ — live status with auto-refresh
- **Serial**: 115200 baud USB CDC logging

## Files

| File | Description |
|------|-------------|
| `mainwindow.cpp/.h` | Qt UI — Controls, live data, raw test |
| `wjdiagnostics.cpp/.h` | Module management, 15 modules |
| `elm327_emu.cpp/.h` | ESP32 emulator core |
| `main.cpp` | ESP32 WiFi AP, TCP server, HTTP dashboard |
| `platformio.ini` | PlatformIO config |
| `wj_tcm_emulator.py` | Python TCP emulator |
| `RELAY_MAP.md` | Actuator command reference |

## Protocol Notes

- **CRC-16/MODBUS** (poly=0xA001, init=0xFFFF) — RS485 bus standard, never change
- **J1850 VPW** — ATSP2, header format 24XXYY (XX=target, YY=mode)
- **K-Line ISO 14230** — ATSP5, KWP2000 with length+address framing
- **0xA0 = LEFT/Driver door** (US tools mislabel as "Passenger Door")
- **Right door has no dedicated J1850 module** — controlled via 0x40
