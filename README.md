# WJDiag — Jeep Grand Cherokee WJ 2.7 CRD Diagnostic Tool

## Vehicle: 2003 EU-spec WJ 2.7 CRD (OM612 / NAG1)

Qt6 cross-platform diagnostic application + ESP32-S2 ELM327 emulator.
All commands and responses verified from real vehicle PCAP captures + BLE full block dumps + WJDiag Pro APK reverse engineering.

## Complete Module Address Map (Scan Order, PCAP-Verified)

| # | Addr | Bus | Module | Real Vehicle Response |
|---|------|-----|--------|----------------------|
| 1 | 0x15 | K-Line | Engine ECU (Bosch EDC15C2 OM612) | OK — 9 actuators + 14-block live data |
| 2 | 0x20 | K-Line | Transmission (NAG1 722.6) | OK — 4 tests + 5-block live data |
| 3 | 0x28 | J1850 | ABS | OK — read + 12 valve tests + DTC |
| 4 | 0x58 | J1850 | ESP / Traction Control | OK — read + 50 live PIDs. DTC clear: NO DATA |
| 5 | 0x61 | J1850 | Instrument Cluster | OK — 11 LED + gauge tests (SID 0x3A) |
| 6 | 0xC0 | J1850 | SKIM / Immobilizer | OK — reset + VIN + key program |
| 7 | 0x40 | J1850 | Body Computer | OK — 14 relays + mode 0xB4 config |
| 8 | 0x98 | J1850 | HVAC / ATC / Memory Seat | OK — 10 motor tests |
| 9 | 0xA0 | J1850 | Driver Door (left windows) | OK — 16 actuators |
| 10 | 0xA1 | J1850 | Passenger Door (right windows) | OK — 15 actuators + RKE |
| 11 | 0x60 | J1850 | Electro Mech Cluster | NRC 7F 22 22 on all commands |
| 12 | 0x68 | J1850 | Overhead Console | OK — self test + reset |
| 13 | 0x6D | J1850 | Navigation | `62 00 00 00` on all reads |
| 14 | 0x80 | J1850 | Radio | NO DATA |
| 15 | 0x81 | J1850 | CD Changer | `62 00 00 00` on all reads |
| 16 | 0x62 | J1850 | Park Assist | `62 00 00 00` on all reads |
| 17 | 0xA7 | J1850 | Rain Sensor | OK — read + DTC clear |
| 18 | 0x2A | J1850 | Adjustable Pedal | NO DATA |
| 19 | 0x87 | J1850 | Satellite Audio | `62 00 00 00` on all reads |
| 20 | 0x90 | J1850 | Hands Free / Uconnect | `62 00 00 00` on all reads |

20 modules total. All connectable.

## Dashboard Gauges (Verified: Real Vehicle BLE + WJDiag Pro + Native Lib Decompile)

### ECU Dashboard

| Gauge | Block | Offset | Formula | WJDiag Pro | Native Lib Constant |
|-------|-------|--------|---------|-----------|-------------------|
| RPM | 0x28 (0x12 fallback) | data[0-1] | raw | 751 | — |
| M-TEMP | 0x22 | data[0-1] | /10 - 273.1 = °C | 54.7°C | — |
| BOOST | 0x22 | data[14-15] | /1000 = Bar | 0.913 | — |
| RAIL | 0x12 | data[18-19] | **×0.101 = Bar** | 294.236 | 0.101 |
| MAF | 0x36 | data[6-7] | /10 = Mg/Str | 478.2 | — |
| INJ-Q | 0x32 | data[0-1] | /100 = mg/str | 8.60 | — |
| BATT | 0x16 | data[2-3] | **×5/3072 = V** | 13.85 | — |
| FUEL | calculated | rpm × fuelActual | L/h | — | — |

### TCM Dashboard

| Gauge | Block | Offset | Formula | WJDiag Pro |
|-------|-------|--------|---------|-----------|
| SPEED | 0x30 | data[4-5] | outputRPM × 0.0385 | 0 km/h |
| GEAR | 0x30 | data[9] | 0=P, 1-5=gear | P |
| TURBIN | 0x31 | data[4-5] | raw RPM | 726 |
| T-TEMP | 0x30 | data[11] | **raw - 50 = °C** | 57°C |
| LIMP | 0x30 | data[9]+maxGear | logic | Normal |
| LINE-P | 0x30 | data[9-10] | signed raw | — |
| TCC | 0x30 | data[0-1] | signed raw RPM | 20 |
| SOL V | 0x34 | data[6-7] | /40 = V | 13.28 |
| BATT | 0x34 | data[8-9] | /154.5 = V | 13.32 |

## Native Lib Constants (libnative-lib.so decompiled)

| Address | Value | Usage |
|---------|-------|-------|
| 0x80870 | 0.0049 | Voltage ADC factor (V = raw × 0.0049) |
| 0x808a8 | 0.101 | Pressure factor (Bar = raw × 0.101) |
| 0x808a0 | 0.0236 | Secondary ADC factor |
| 0x808b0 | 0.011 | Temp/voltage factor |
| 0x80828 | 0.25 | TCM current factor |
| 0x808e0 | 0.007 | TCM multiplier |
| 0x80838 | -41.0 | TCM offset (for some params) |
| 0x80848 | 10.0 | Common divisor |
| 0x80850 | 100.0 | Common divisor |
| 0x808d0 | 1000.0 | Common divisor |

## Controls Tab

See [RELAY_MAP.md](RELAY_MAP.md) for full command reference.

### Windows
Both doors: `38 PID 12` ON, `38 PID 00` OFF.
PID 0x01=Front Up, 0x02=Front Down, 0x03=Rear Up, 0x04=Rear Down.

### Body Computer 0x40
Hazard: `38 06 20`, Horn: `38 0D 01`, Hi Beam: `38 06 08`, Park: `38 06 04`

### Cluster 0x61 Gauge Test
SID 0x3A: `3A 00 80`=Speedo, `3A 00 40`=Tacho, `3A 00 08`=Fuel, `3A 00 04`=Temp

## ECU Security — ArvutaKoodi

4-table lookup: T1-T4 (16 bytes each). See RELAY_MAP.md for algorithm.
TCM: Static seed `68 24 89` -> Key `CC 21`

## DTC

K-Line: `18 02 00 00` read, `14 00 00` clear
J1850: `ATSH24xx18` + `FF 00 00` read, `ATSH24xx14` + `FF 00 00` clear
ESP 0x58 DTC clear: NO DATA

## ESP32-S2 Emulator

WiFi AP "WiFi_OBDII", IP 192.168.0.10, TCP 35000. All block responses use exact real vehicle BLE hex data. Dynamic fields: RPM (0x12/0x28), coolant temp (0x12/0x22), fuel qty (0x32), TCM gear cycling, TCM RPMs.

## APK Reverse Engineering

Package: com.jeepswj.WJdiagPro v12.0
Architecture: Java UI → JNI → libnative-lib.so
ECU parser: `MDiiselTagasi` (concatenated buffer: 0x62+0x12+0x28+0xB0+0xB1+0xB2)
TCM parser: `KKDiiselTagasi` (reads 0x34 via native, Java reads 0x30+0x31+0x33+0x32)
Trans Temp: `ValiBaitInt2L(str, 0x11)` reads 0x30 byte[11], formula: raw - 50 = °C
