# WJDiag Relay Map & DTC PID Tables

## J1850 DTC PID Scan Tables (PCAP Verified)

### ABS 0x28 — 17 PIDs (2E 10 ~ 2E 30)
Header: `ATSH242822` + `ATRA28`

| PID | DTC Code | Description | PCAP Response (clean) |
|-----|----------|-------------|----------------------|
| 2E 10 | C0031 | LF Sensor Circuit Failure | 00 00 FF |
| 2E 11 | C0032 | LF Wheel Speed Signal Failure | 00 FF FF |
| 2E 12 | C0035 | RF Sensor Circuit Failure | 00 00 00 |
| 2E 13 | C0036 | RF Wheel Speed Signal Failure | 00 FF FF |
| 2E 14 | C0041 | LR Sensor Circuit Failure | 00 00 00 |
| 2E 15 | C0042 | LR Wheel Speed Signal Failure | 00 00 00 |
| 2E 16 | C0045 | RR Sensor Circuit Failure | 00 FF FF |
| 2E 17 | C0046 | RR Wheel Speed Signal Failure | 00 FF FF |
| 2E 20 | C0051 | Valve Power Feed Failure | 00 00 00 |
| 2E 21 | C0060 | Pump Motor Circuit Failure | **00 8F 00** (ACTIVE) |
| 2E 22 | C0070 | CAB Internal Failure | 00 00 00 |
| 2E 23 | C0080 | ABS Lamp Circuit Short | **00 8E 99** (ACTIVE) |
| 2E 24 | C0081 | ABS Lamp Open | 00 FF FF |
| 2E 25 | C0085 | Brake Lamp Circuit Short | 00 00 00 |
| 2E 26 | C0110 | Brake Fluid Level Switch | 00 FF FF |
| 2E 27 | C0111 | G-Switch / Sensor Failure | 00 00 00 |
| 2E 30 | C1014 | ABS Messages Not Received | 00 FF FF |

**Verified across 2 PCAPs**: JeepFullEcuTest.pcap + ecu_tms_abs_airbag_live.pcap

### ESP 0x58 — 55 PIDs (2E 10 ~ 2F 3C, 3-step increments)
Header: `ATSH245822` + `ATRA58`

DTC Clear: `ATSH245814` + `01 00 00` (retry up to 7x, NO DATA is normal)

| PID | DTC Code | PID | DTC Code | PID | DTC Code |
|-----|----------|-----|----------|-----|----------|
| 2E 10 | C0031 | 2E 52 | C1036 | 2E E2 | C2102 |
| 2E 13 | C0032 | 2E 70 | C1041 | 2E E5 | C2103 |
| 2E 16 | C0035 | 2E 73 | C1042 | 2E FA | C2200 |
| 2E 19 | C0036 | 2E 76 | C1045 | 2E FD | C2201 |
| 2E 1C | C0041 | 2E 79 | C1046 | 2F 00 | C2202 |
| 2E 1F | C0042 | 2E 7C | C1051 | 2F 03 | C2203 |
| 2E 22 | C0045 | 2E 7F | C1060 | 2F 06 | C2204 |
| 2E 25 | C0046 | 2E 82 | C1070 | 2F 18 | C2300 |
| 2E 28 | C0051 | 2E 85 | C1071 | 2F 1B | C2301 |
| 2E 2B | C0060 | 2E 88 | C1073 | 2F 1E | C2302 |
| 2E 2E | C0070 | 2E 8B | C1075 | 2F 21 | C2303 |
| 2E 37 | C0110 | 2E 8E | C1080 | 2F 24 | C2304 |
| 2E 3A | C0111 | 2E 91 | C1085 | 2F 27 | C2305 |
| 2E 3D | C1014 | 2E 94 | C1090 | 2F 2A | C2306 |
| 2E 43 | C1015 | 2E 97 | C1095 | 2F 2D | C2307 |
| 2E 49 | C1031 | 2E DC | C2100 | 2F 30 | C2308 |
| 2E 4C | C1032 | 2E DF | C2101 | 2F 33 | C2309 |
| 2E 4F | C1035 | | | 2F 36 | C2310 |
| | | | | 2F 39 | C2311 |
| | | | | 2F 3C | C2312 |

**Verified**: dtc.pcap — all 55 PIDs scanned, all returned 00 00 00 A8 (clean vehicle)

### Body Computer 0x40 — 7 PIDs
Header: `ATSH244022` + `ATRA40`

| PID | DTC Code | Description |
|-----|----------|-------------|
| 2E 00 | B1A00 | Interior Lamp Circuit |
| 2E 01 | B1A10 | Door Ajar Switch Circuit |
| 2E 02 | B2100 | SKIM Communication Error |
| 2E 03 | B2101 | Bus Communication Error |
| 2E 05 | B2102 | Key-In Circuit |
| 2E 0D | B2200 | Door Lock Circuit |
| 2E 12 | B2300 | Horn Relay Circuit |

**Verified**: body_computer.pcap — all returned 00 00 00 31 (clean)

### HVAC/ATC 0x98 — 4 PIDs
Header: `ATSH249822` + `ATRA98`

| PID | DTC Code | Description |
|-----|----------|-------------|
| 2E 03 | B1001 | A/C Pressure Sensor Circuit |
| 2E 04 | B1002 | A/C Clutch Relay Circuit |
| 2E 05 | B1003 | Blend Door Actuator Circuit |
| 2E 06 | B1004 | Mode Door Actuator Circuit |

### Overhead Console 0x68 — 3 PIDs
Header: `ATSH246822` + `ATRA68`

| PID | DTC Code | Description |
|-----|----------|-------------|
| 2E 02 | B1100 | Compass Calibration Error |
| 2E 05 | B1101 | Temperature Sensor Circuit |
| 2E 08 | B1102 | Display Circuit Error |

### Rain Sensor 0xA7 — 1 PID
Header: `ATSH24A722` + `ATRAA7`

| PID | DTC Code | Description |
|-----|----------|-------------|
| 2E 10 | B1200 | Rain Sensor Circuit |

**Verified**: rain_sensor.pcap — returned 00 00 00 47 (clean)

### SKIM 0xC0 — 1 PID
Header: `ATSH24C022` + `ATRAC0`

| PID | DTC Code | Description |
|-----|----------|-------------|
| 2E 00 | B2500 | Transponder Communication Error |

---

## Actuator Commands (Mode 0x2F)

### Body Computer 0x40
Header: `ATSH24402F` + `ATRA40`

| Command | Function |
|---------|----------|
| 38 06 20 | Hazard lamps ON |
| 38 06 00 | Hazard lamps OFF |
| 38 0D 01 | Horn ON (hold) |
| 38 0D 00 | Horn OFF |
| 38 08 01 | Wiper single sweep (hold) |
| 38 08 00 | Wiper OFF |
| 38 0A 01 | Left mirror fold |
| 38 0A 00 | Left mirror unfold |
| 38 0B 01 | Right mirror fold |
| 38 0B 00 | Right mirror unfold |
| 38 01 01 | Dome light ON |
| 38 01 00 | Dome light OFF |

### Driver Door 0xA0
Header: `ATSH24A02F` + `ATRAA0`

| Command | Function |
|---------|----------|
| 38 01 01 | Left window UP |
| 38 02 01 | Left window DOWN |
| 38 03 01 | Rear left window UP |
| 38 04 01 | Rear left window DOWN |

### Passenger Door 0xA1
Header: `ATSH24A12F` + `ATRAA1`

Same PID pattern as Driver Door (38 01~04).

### HVAC/ATC 0x98
Header: `ATSH24982F` + `ATRA98`

| Command | Function |
|---------|----------|
| 38 01 01 | Blend door actuator test |
| 38 02 01 | Mode door actuator test |
| 38 03 01 | Recirc door actuator test |

---

## ABS Valve Test Modes

### Mode 0x30 (SelfTest)
Header: `ATSH242830`

Echo command back as positive response: `26 28 70 <cmd>`

### Mode 0xA3
Header: `ATSH2428A3`

Response: `26 28 E3 02 EE 00 0A DD`

### Mode 0xA0
Header: `ATSH2428A0`

Echo command back: `26 28 E0 <cmd>`

---

## K-Line DTC Read/Clear

### ECU 0x15
- Read: `18 02 00 00` → `58 <count> <DTC_HI DTC_LO STATUS>...`
- Clear: `14 00 00` → `54 00 00`

### TCM 0x20
- Read: `18 02 FF 00` → `58 <count> <DTC_HI DTC_LO STATUS>...`
- Clear: `14 00 00` → may return `7F 14 78` (Response Pending) then `NO DATA` (success)

---

## PCAP Sources (2026-03-14)
- `JeepFullEcuTest.pcap` — Full module scan (ABS DTC PIDs, all modules)
- `dtc.pcap` — ESP 0x58 DTC PID scan (55 PIDs) + DTC clear
- `ecu_tms_abs_airbag_live.pcap` — ABS DTC PIDs cross-validation
- `body_computer.pcap` — Body 0x40 DTC PIDs + actuators
- `rain_sensor.pcap` — Rain 0xA7 DTC PID + clear
- `doors_driver_passenger.pcap` — Door window control
- `faults.pcap` — K-Line ECU/TCM DTC read/clear
- `modules_activation.pcap` — Module identification
- `door_hazard_horn.pcap` — Body actuator commands
- `viper.pcap` — Wiper actuator
- `tmc_gear_change.pcap` — TCM gear data
