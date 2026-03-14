# WJDiag — Jeep WJ 2.7 CRD Diagnostics

Qt6/C++ diagnostics application for Jeep Grand Cherokee WJ (2003 EU, 2.7 CRD OM612) with ESP32 ELM327 simulator.

## Supported Modules

### K-Line (ISO 14230-4 KWP2000, ATSP5)
| Address | Module | Features |
|---------|--------|----------|
| 0x15 | Bosch EDC15C2 (MotorECU) | Live data (20+ blocks), DTC read/clear, security access, actuator test |
| 0x20 | NAG1 722.6 (KLineTCM) | Live data (block 0x30), DTC read/clear, gear display |

### J1850 VPW (ATSP2)
| Address | Module | DTC PIDs | Features |
|---------|--------|----------|----------|
| 0x28 | ABS/TCM | 17 (2E 10~2E 30) | Live data, DTC PID scan, valve test (mode 0x30/0xA0/0xA3) |
| 0x58 | ESP/Traction | 55 (2E 10~2F 3C) | DTC PID scan, DTC clear (mode 0x14, cmd 01 00 00) |
| 0x40 | Body Computer | 7 (2E 00~2E 12) | Live data, actuators (mode 0x2F), config (mode 0xB4), DTC PID scan |
| 0x98 | HVAC/ATC | 4 (2E 03~2E 06) | Live data, self-test (mode 0x30), actuators (mode 0x2F), DTC PID scan |
| 0x68 | Overhead Console | 3 (2E 02~2E 08) | Live data, self-test, DTC PID scan |
| 0xA7 | Rain Sensor | 1 (2E 10) | Live data, DTC PID scan, DTC clear |
| 0xC0 | SKIM/Immobilizer | 1 (2E 00) | Identification, DTC PID scan |
| 0xA0 | Driver Door | — | Window control (mode 0x2F), live data |
| 0xA1 | Passenger Door | — | Window control (mode 0x2F), live data |
| 0x61 | Instrument Cluster | — | Gauge test, identification |
| 0x60 | Airbag (ORC) | — | All NRC on real vehicle |

### Dead Modules (NO DATA on EU spec)
0x80 (Radio), 0x81 (CD Changer), 0x62 (Park Assist), 0x6D (Navigation), 0x87 (Sat Audio), 0x90 (Hands Free), 0x2A (EVIC)

## J1850 DTC Read — PID Scan Method

WJDiag Pro and this app read J1850 DTCs via **PID scanning**, not mode 0x18 (which returns NRC on all WJ modules).

**How it works:**
1. Switch to module's read header: `ATSH24xx22` + `ATRAxx`
2. Send each DTC PID: `2E xx 00` (or `2F xx 00` for ESP extended range)
3. Parse response: `26 <src> 62 <D0> <D1> <D2> <CRC>`
4. If D0:D1 != 0x0000 and != 0xFFFF → DTC is active at that PID slot
5. DTC code is mapped from the PID number via a lookup table

**Response patterns:**
- `00 00 00` or `00 00 FF` → No fault (cleared)
- `00 FF FF` → Unlearned (slot never had a fault or was cleared)
- `00 8F 00` → Active fault, occurrence count = 0x8F
- `7F 22 21` → NRC (PID not supported by this module)

**DTC clear** uses mode 0x14:
- ESP 0x58: `ATSH245814` + `01 00 00` (may need multiple retries, NO DATA is normal)
- Others: `ATSH24xx14` + `FF 00 00`

## Protocol Details

- **CRC-16/MODBUS**: poly=0xA001, init=0xFFFF (K-Line only, immutable)
- **J1850 VPW**: Header format `24 <target> <mode>`, ATRA filter required
- **ELM327**: ATH1 mode (headers on), WiFi TCP port 35000
- **DiagSession**: Some modules (0x98 HVAC, 0x28 ABS) need `ATSH24xx11` + `01 01 00` before data reads

## ESP32 Simulator

PlatformIO project in `elm327_esp32/` — SparkFun ESP32-S2 Thing Plus C.
All J1850 responses are PCAP-verified against real vehicle captures (2026-03-14).

## Build

```
qmake && make   # Qt6, requires BLE module for iOS/macOS
```

## File Structure

- `src/wjdiagnostics.cpp` — Multi-protocol diagnostics engine, DTC PID scan
- `src/mainwindow.cpp` — UI: tabs (Conn|DTC|Live|Ctrl|Acts|Log)
- `src/livedata.cpp` — Live data parameter definitions
- `src/kwp2000handler.cpp` — K-Line KWP2000 protocol handler
- `src/elm327connection.cpp` — ELM327 BLE/WiFi/Serial transport
- `elm327_esp32/src/elm327_emu.cpp` — ESP32 simulator (PCAP-verified)
- `include/` — Headers
