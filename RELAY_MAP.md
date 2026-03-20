# WJ 2.7 CRD — Complete Actuator Command Reference

All commands verified from real vehicle bus captures and simulator testing.

## Init Sequences (Verified)

### J1850 VPW Init
```
ATZ → ATZ → ATSP2 → ATIFR0 → ATH1 → ATSH24xx22 → ATRAxx → ATSH24xxMM → command
```
Double ATZ for clone ELM327 reliability. ATH1 comes AFTER ATSP2/ATIFR0.

### K-Line ECU Init (0x15)
```
ATZ → ATE1 → ATH1 → ATWM8115F13E → ATSH8115F1 → ATSP5 → ATFI → 81 → 27 01/02
```

### K-Line TCM Init (0x20)
```
ATZ → ATE1 → ATH1 → ATWM8120F13E → ATWM8120F13E → ATSH8120F1 → ATSP5 → ATFI → 81 → 27 01/02
```
Double ATWM for TCM reliability. Real vehicle also uses `81` for bus init (first `81` triggers `BUS INIT: OK`).

### Keepalive: `81` (NOT `3E`)
Real vehicle uses SID 0x81 (StartCommunication) as K-Line keepalive. 

### NRC Handling 
- **NRC 0x78 (ResponsePending)**: ECU sends `7F xx 78` followed by actual positive response in same frame. Common on actuator SID 0x30 and DTC clear SID 0x14.
- **NRC 0x21 (busyRepeatRequest)**: J1850 modules return this when bus is busy. Retry same command up to 3 times.
- **J1850 Bus Noise**: Real bus has periodic unsolicited `2D 28 xx xx` frames (~119 in 957s capture). Must be filtered from response parsing.

---

## 1. Driver Door 0xA0 / Passenger Door 0xA1 — Sequential (mode 0x2F)

Both doors identical PID layout. `38 PID 12` = ON, `38 PID 00` = OFF.
Driver: `ATSH24A02F` + `ATRAA0` | Passenger: `ATSH24A12F` + `ATRAA1`

| PID | Function | ON | OFF |
|-----|----------|-----|-----|
| 0x00 | Courtesy Lamp | `38 00 12` | `38 00 00` |
| 0x01 | **Front Window Up** | `38 01 12` | `38 01 00` |
| 0x02 | **Front Window Down** | `38 02 12` | `38 02 00` |
| 0x03 | **Rear Window Up** | `38 03 12` | `38 03 00` |
| 0x04 | **Rear Window Down** | `38 04 12` | `38 04 00` |
| 0x05 | Lock | `38 05 12` | `38 05 00` |
| 0x06 | Unlock | `38 06 12` | `38 06 00` |
| 0x07 | Mirror Up | `38 07 12` | `38 07 00` |
| 0x08 | Mirror Down | `38 08 12` | `38 08 00` |
| 0x09 | Mirror Left | `38 09 12` | `38 09 00` |
| 0x0A | Mirror Right | `38 0A 12` | `38 0A 00` |
| 0x0B | Foldaway In | `38 0B 12` | `38 0B 00` |
| 0x0C | Foldaway Out | `38 0C 12` | `38 0C 00` |
| 0x0D | Mirror Heater | `38 0D 12` | `38 0D 00` |
| 0x0E | Switch Illumination | `38 0E 12` | `38 0E 00` |
| 0x0F | Set Memory LED | `38 0F 12` | `38 0F 00` |

Passenger Door extra: `ATSH24A131` → `01 00 00` (RKE mode 0x31), `ATSH24A133` → `01 00 00` (mode 0x33)

---

## 2. Body Computer 0x40

### Mode 0x2F (`ATSH24402F` + `ATRA40`)

| # | Function | ON | OFF | Notes |
|---|----------|-----|-----|-------|
| 1 | Viper relay | `38 08 01` | `38 08 00` | |
| 2 | VTSS lamp | `38 07 01` | `38 07 00` | |
| 3 | Front Fog Lamps | `38 06 02` | `38 06 00` | reg 0x06 bitmask |
| 4 | Chime | `38 02 01` | `38 02 00` | |
| 5 | **Hi Beam relay** | `38 06 08` | `38 06 00` | reg 0x06 bitmask |
| 6 | Rear fog lamp | `38 06 10` | `38 06 00` | reg 0x06 bitmask |
| 7 | **Hazard flashers** | **`38 06 20`** | **`38 06 00`** | reg 0x06 bitmask |
| 8 | R Defog relay | `38 06 10` | `38 06 00` | same as rear fog |
| 9 | HI LOW wiper | `38 08 02` | `38 08 00` | |
| 10 | Park lamp relay | `38 06 04` | `38 06 00` | reg 0x06 bitmask |
| 11 | **Horn relay** | **`38 0D 01`** | **`38 0D 00`** | |
| 12 | Low beam | `3A 02 FF` | — | SID 0x3A |
| 13 | Illumination | `38 0D 01` | `38 0D 00` | |
| 14 | Release All | `3A 02 FF` | — | SID 0x3A |

### Mode 0xB4 (`ATSH2440B4`)

| Function | Command |
|----------|---------|
| VTSS Mode | `28 07 46` |
| Alarm Tripped by | `28 3F 00` |

### Mode 0x11 (`ATSH244011`)

| Function | Command |
|----------|---------|
| Reset Module | `01 05 00` |

---

## 3. Instrument Cluster 0x61 — SID 0x3A Gauge Test

Header: `ATSH246122` | Filter: `ATRA61`

| Command | Function | OFF |
|---------|----------|-----|
| `3A 00 80` | Speedo | `3A 00 00` |
| `3A 00 40` | Tacho | `3A 00 00` |
| `3A 00 20` | 3 Led | `3A 00 00` |
| `3A 00 10` | 4 Led | `3A 00 00` |
| `3A 00 08` | Fuel / Drive Led | `3A 00 00` |
| `3A 00 04` | Temp / Neutral Led | `3A 00 00` |
| `3A 00 02` | Reverse Led | `3A 00 00` |
| `3A 00 01` | Park Led | `3A 00 00` |
| `3A 01 01` | Oil lamp / 4Hi Led | `3A 01 00` |
| `3A 01 02` | T-Case Neutral Led | `3A 01 00` |
| `3A 01 04` | CE lamp / 4Low Led | `3A 01 00` |

---

## 4. ECU 0x15 K-Line — SID 0x30 IOControl

Init: `ATWM8115F13E` → `ATSH8115F1` → `ATSP5` → `ATFI` → `81` → security unlock (SID 0x27)

**NRC 0x78 note**: Some actuator commands (e.g. `30 3A 08 00 00`) trigger NRC 0x78
(ResponsePending) before the positive response. Both arrive in the same ELM327 frame:
`7F 30 78\r70 3A 08 00 00\r\r>`

**Security note**: When ECU returns seed=`00 00`, it is already unlocked.
ArvutaKoodi with seed=0 produces key `9C C9` which the ECU accepts.
Blocks 0x62/0xB0/0xB1/0xB2 are readable in this state.

| # | Function | ON | OFF |
|---|----------|-----|-----|
| 1 | EGR Solenoid | `30 11 07 13 88` | `30 11 07 00 00` |
| 2 | Cabin/Viscous heater | `30 1C 07 27 10` | `30 1C 07 00 00` |
| 3 | Glow plug Relay 1 | `30 16 07 27 10` | `30 16 07 00 00` |
| 4 | Glow plug Relay 2 | `30 17 07 27 10` | `30 17 07 00 00` |
| 5 | A/C Control | `30 14 07 27 10` | `30 14 07 00 00` |
| 6 | SWIRL Solenoid | `30 1A 07 13 88` | `30 1A 07 00 00` |
| 7 | Boost Pressure | `30 12 07 00 10` | `30 12 07 00 00` |
| 8 | Hyd Fan Low Speed | `30 18 07 08 34` | `30 18 07 00 00` |
| 9 | Hyd Fan Full Speed | `30 18 07 21 34` | `30 18 07 00 00` |

Other: Fuel correction (`31 25 00` start, `32 25` stop), Max values (`30 3A 01` enable, `30 3A 08 00 00` set),
Compression test (`21 28` per-cylinder RPM monitoring), Adaptation (`21 B0/B1/B2` read calibration constants)

---

## 5. TCM 0x20 K-Line — SID 0x30/0x31

Init: `ATWM8120F13E` → `ATWM8120F13E` → `ATSH8120F1` → `ATSP5` → `ATFI` → `81` → `27 01/02`

Double ATWM for reliability. Keepalive: `81` between each polling cycle.
TCM seed is static: `68 24 89` → Key `CC 21`.

| # | Function | Command |
|---|----------|---------|
| 1 | Reset Adaptives | `31 31` |
| 2 | Store Adaptives | `31 32` |
| 3 | Solenoid Test ON | `30 10 07 00 02` |
| 3 | Solenoid Test OFF | `30 10 07 00 00` |
| 4 | Park Lockout Solenoid | `30 10 07 04 00` |

---

## 6. ABS 0x28 — J1850 Multi-Mode

Init: `ATSH242822` + `ATRA28`

| # | Function | Header | Command |
|---|----------|--------|---------|
| 1 | Set Pinion Factor | `ATSH242810` | `02 00 00` |
| 2 | Bleed Brakes | `ATSH242820` | `00 00 00` |
| 3 | LF Inlet Valve | `ATSH242811` | `01 02 00` |
| 4 | RF Inlet Valve | `ATSH242822` | `36 00 00` |
| 5 | LR Inlet Valve | `ATSH242830` | `01 FE FF` |
| 6-10 | Other valves | `ATSH242810` | `02 00 00` (session) |
| 11 | Pump Motor | `ATSH242810` | `02 00 00` |
| 12 | End ABS Test | `ATSH242810` | `02 00 00` |

DiagSession reset (`ATSH242810` → `02 00 00`) between each test.

---

## 7. HVAC / ATC 0x98 — Mode 0x2F/0x30

Init: `ATSH249822` + `ATRA98` (+ cross-read `ATSH244022` + `ATRA40`)

| # | Function | Header | Command |
|---|----------|--------|---------|
| 1 | Reset Module | `ATSH249811` | `01 01 00` |
| 2 | Self Test | `ATSH249830` | `01 FF FF` |
| 3 | Mode MTR Full Def | `ATSH249830` | `02 FF FF` |
| 4 | Mode MTR Full Panel | `ATSH249830` | `03 FF FF` |
| 5 | Driver Blend Hot | `ATSH24982F` | `38 03 00` |
| 6 | Driver Blend Cold | `ATSH24982F` | `38 04 00` |
| 7 | Pass Blend Hot | `ATSH24982F` | `38 07 00` |
| 8 | Pass Blend Cold | `ATSH24982F` | `38 08 00` |
| 9 | Recirc Fresh | `ATSH24982F` | `38 0B 00` |
| 10 | Recirc Recirculate | `ATSH24982F` | `38 0C 00` |
| 11 | (extra) | `ATSH24982F` | `38 0F 00` |
| 12 | (extra) | `ATSH24982F` | `38 10 00` |

---

## 8. SKIM / Park Assist 0xC0

Init: `ATSH24C022` + `ATRAC0`

| # | Function | Header | Command |
|---|----------|--------|---------|
| 1 | Reset Module | `ATSH24C011` | `01 01 00` |
| 2 | Indicator Lamp | `ATSH24C02F` | `38 00 01` |
| 3 | View SKIM VIN | `ATSH24C022` | `28 10 00` |
| 4 | Erase Ignition Keys | `ATSH24C027` | `02 11 11` |
| 5 | Program Ignition Keys | `ATSH24C027` | `02 11 11` |
| - | DTC Clear | `ATSH24C014` | `FF 00 00` |

---

## 9. Overhead Console 0x68

Init: `ATSH246822` + `ATRA68`

| # | Function | Header | Command |
|---|----------|--------|---------|
| 1 | Self Test (mode 0x31) | `ATSH246831` | `01 00 00` |
| 2 | Self Test (mode 0x33) | `ATSH246833` | `01 00 00` |
| 3 | Reset Module | `ATSH246811` | `01 01 00` |

---

## 10. DTC Read/Clear

### K-Line (SID 0x18 read, SID 0x14 clear)

| Module | Read | Clear |
|--------|------|-------|
| ECU 0x15 | `18 02 00 00` → `58 NN ...` | `14 00 00` → `54 00 00` |
| TCM 0x20 | `18 02 FF 00` → `58 NN ...` | `14 00 00` → `54 00 00` |

### J1850 (mode 0x18 read, mode 0x14 clear)

| Module | Read Header | Clear Header | Clear Cmd |
|--------|-------------|--------------|-----------|
| Body 0x40 | `ATSH244018` | `ATSH244014` + `ATRA40` | `FF 00 00` |
| ABS 0x28 | `ATSH242818` | `ATSH242810` + `ATRA28` | `02 00 00` |
| Rain 0xA7 | `ATSH24A718` | `ATSH24A714` + `ATRAA7` | `FF 00 00` |
| ESP 0x58 | `ATSH245818` | `ATSH245814` + `ATRA58` | `01 00 00` |
| SKIM 0xC0 | `ATSH24C018` | `ATSH24C014` + `ATRAC0` | `FF 00 00` |

---

## ECU Security Unlock Algorithm

See README.md for full ArvutaKoodi algorithm with lookup tables T1-T4.

---

## 11. ECU Live Data Blocks (K-Line 0x15)

14 blocks per cycle + 4 security + ATRV. Block read order: `0x12 → 0x30 → 0x22 → 0x20 → 0x23 → 0x21 → 0x16 → 0x32 → 0x37 → 0x13 → 0x36 → 0x26 → 0x34`

**All offsets verified: Real vehicle BLE full dump + real vehicle BLE captures.**

### Block 0x12 (32 data bytes) — Primary sensors
| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | Coolant Temp | /10 - 273.1 = °C | ✓ |
| [2-3] | u16 | Air Intake Temp (IAT) | /10 - 273.1 = °C | ✓ |
| [4-5] | u16 | Coolant Sensor V | /1000 = V | |
| [6-7] | u16 | IAT Sensor V | /1000 = V | |
| [10-11] | u16 | Engine RPM | raw (0x28 overrides) | ✓ |
| [14-15] | u16 | Injection Qty | /100 = mg/str | |
| [16-17] | u16 | MAP Actual | raw mbar | ✓ |
| [18-19] | u16 | **Fuel Rail Pressure** | **×0.101 = Bar** | ✓ 294.2 Bar |

### Block 0x22 (32 data bytes) — Coolant + Boost (primary source)
| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | **Coolant Temp** | /10 - 273.1 = °C | ✓ 54.7°C |
| [2-3] | u16 | **IAT** | /10 - 273.1 = °C | ✓ |
| [4-5] | u16 | Coolant Sensor V | /1000 = V | |
| [6-7] | u16 | IAT Sensor V | /1000 = V | |
| [14-15] | u16 | **Boost Pressure** | /1000 = Bar (MAP/1000) | ✓ 0.913 Bar |
| [16-17] | u16 | Air Intake Volts | /1000 = V | (NOT Rail!) |

### Block 0x28 (28 data bytes) — RPM + Per-Cylinder + Injection Corrections (Verified)

Real vehicle idle: `02EF 039D 02EE 02EE 02EE 02EE 02EE 0000 0016 0011 FF72 0036 002F 0000`

| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | **Engine RPM** | raw (overrides 0x12) | ✓ 751 |
| [2-3] | u16 | **Injection Qty** | /100 = mg/str | ✓ 9.25 |
| [4-5] | u16 | Cyl 1 RPM | raw | 750 |
| [6-7] | u16 | Cyl 2 RPM | raw | 750 |
| [8-9] | u16 | Cyl 3 RPM | raw | 750 |
| [10-11] | u16 | Cyl 4 RPM | raw | 750 |
| [12-13] | u16 | Cyl 5 RPM | raw | 750 |
| [14-15] | u16 | (padding) | 0 | |
| [16-17] | u16 | (constant) | 0x0016 = 22 | |
| [18-19] | u16 | (varies) | 17/13/11 per cycle | |
| [20-21] | s16 | Inj Correction 1 | /100 = mg/str | -1.42 |
| [22-23] | s16 | Inj Correction 2 | /100 = mg/str | +0.54 |
| [24-25] | s16 | Inj Correction 3 | /100 = mg/str | +0.47 |
| [26-27] | u16 | (padding) | 0 | |

### Block 0x30 (24 data bytes) — Idle setpoints
| Offset | Bytes | Field | Formula |
|--------|-------|-------|---------|
| [0-1] | u16 | Low Idle Setpoint | raw RPM (750) |

### Block 0x32 (32 data bytes) — Fuel actual + speed
| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | **Actual Fuel Quantity** | /100 = mg/str | ✓ 8.60 |
| [4-5] | u16 | Vehicle Speed | raw km/h | |

### Block 0x36 (38 data bytes) — Pedal + MAF
| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | Accel Pedal 1 | /100 = % | |
| [4-5] | u16 | Accel Pedal 1 V | /1000 = V | |
| [6-7] | u16 | **Mass Air Flow** | /10 = Mg/Str | ✓ 478.2 |

### Block 0x16 (38 data bytes) — Battery / Alternator
| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | Alternator raw | — | |
| [2-3] | u16 | **Battery Voltage** | **×5.0/3072 = V** | ✓ 13.85V |

### Block 0x20 (30 data bytes) — MAF/cruise detail
Real BLE: `0254 0253 03FE 0000 0094 0048 01A8 0163 0108 02E5 024D 0090 00BF 03A0 01FA`

### Block 0x23 (20 data bytes) — Boost/MAP detail
Real BLE: `097F 0250 FFFC 0BD7 03A0 02A3 0085 0043 03FD 012A`

### Block 0x21 (20 data bytes) — Fuel quantities + Fuel Level (Verified 2026-03-18)
Real vehicle idle: `018F 03E3 03FD 004A 012A 03FD 024A 01EF 00B4 015D`

| Offset | Bytes | Field | Formula | Verified |
|--------|-------|-------|---------|----------|
| [0-1] | u16 | Desired Fuel QTY Pedal | /100 = mg/str | 3.99 |
| [2-3] | u16 | Fuel QTY Limit | /100 = mg/str | 9.95 |
| [4-5] | u16 | Fuel QTY Demand | /100 = mg/str | 10.21 |
| [6-7] | u16 | Fuel QTY Driver | /100 = mg/str | 0.74 |
| [8-9] | u16 | Fuel QTY Start Setpoint | /100 = mg/str | 2.98 |
| [10-11] | u16 | (reserved) | /100 | 10.21 |
| [12-13] | u16 | (reserved) | /100 | 5.86 |
| [14-15] | u16 | **Fuel Level** | **/10 = %** | **49.5% = 39.0L** |
| [16-17] | u16 | **Fuel Level Sensor Voltage** | **/100 = V** | **1.80V** |
| [18-19] | u16 | (reserved) | /100 | 3.49 |

### Block 0x37 (34 data bytes) — EGR/Wastegate
Real BLE: `0C67 105D 0079 0000 0008...`

### Block 0x13 (26 data bytes) — Oil/AC/Baro
Real BLE: `0393 024A 02E4 02E4 0000 08B7 0000 0250 FFFC 0BD7 0085 03FD 0BCC`

### Block 0x26 (30 data bytes) — Vehicle Speed + misc (Verified 2026-03-18)
Real vehicle idle: `0000 0000 0000 5CB1 7FFF 0000 2FA0 0029 0029 0029 0029 0048 0023 0000 0CE5`
Real vehicle driving: `0000 0465 0000 5CB1 7FFF ...` (11.2 km/h)

| Offset | Bytes | Field | Formula | Verified |
|--------|-------|-------|---------|----------|
| [0-1] | u16 | (always 0) | — | 0 |
| [2-3] | u16 | **Vehicle Speed** | **raw / 100 = km/h** | **0-80+ km/h** |
| [4-5] | u16 | (always 0) | — | 0 |
| [6-7] | u16 | (constant) | — | 23729 |
| [8-9] | u16 | (sentinel 0x7FFF) | — | 32767 |

### Block 0x34 (34 data bytes) — Transfer case/misc
Real BLE: `0048 1000 0000 0004 0000...03FF 0003...0004 0000`

---

## 12. TCM Live Data Blocks (K-Line 0x20)

5 blocks per cycle: `0x30 → 0x31 → 0x34 → 0x33 → 0x32`

**All offsets verified: Real vehicle BLE + real vehicle BLE captures.**

### Block 0x30 (22 data bytes) — Gear, TCC slip, output RPM, trans temp
Real BLE idle: `0017 001E 0000 0008 0400 DD60 FFF6 FFF6 0000 9618 0008`

| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | **Actual TCC Slip** | signed raw RPM | ✓ 20 |
| [2-3] | u16 | **Desired TCC Slip** | signed raw RPM | ✓ 30 |
| [4-5] | u16 | **Output RPM** | raw | ✓ 0 (idle) |
| [7] | u8 | Selector | P=8, R=7, N=6, D=5 | ✓ |
| [9] | u8 | **Actual Gear** | 0=P/N, 1-5=gear | ✓ |
| [10] | u8 | Gear × 0x11 | confirm byte | |
| [11] | u8 | **Transmission Temp** | **raw - 50 = °C** | ✓ 57°C  |

### Block 0x31 (20 data bytes) — RPMs
Real BLE idle: `01BB 0000 02D8 02F0 0000...`

| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | **Input RPM (N2)** | raw | ✓ 442 |
| [2-3] | u16 | **Input RPM (N3)** | raw | ✓ 0 |
| [4-5] | u16 | **Turbine RPM** | raw | ✓ 726 |
| [6-7] | u16 | **Engine RPM** (from TCM) | raw | ✓ 750 |

### Block 0x34 (14 data bytes) — Voltages
Real BLE: `0217 03FF 0332 0214 0807 0001 0028`

| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | Unknown (NOT trans temp!) | — | |
| [2-3] | u16 | Unknown (0x03FF=1023) | — | |
| [4-5] | u16 | **Sensor Supply** | ×7/1000 = V | ✓ 5.73V |
| [6-7] | u16 | **Solenoid Supply** | /40 = V | ✓ 13.28V |
| [8-9] | u16 | **Battery** | /154.5 = V | ✓ 13.32V |

### Block 0x33 (16 data bytes) — Pressures (NOT wheel speeds!)
Real BLE: `0024 0771 05DC 02B8 02B4 02E3 02E1 0000`

| Offset | Bytes | Field | Formula | Verified Value |
|--------|-------|-------|---------|-------------------|
| [0-1] | u16 | **TCC Pressure** | /1000 = Bar | ✓ 0.000 |
| [6-7] | u16 | **Shift PSI** | /365 = Bar | ✓ 1.904 |
| [8-9] | u16 | **Modulation PSI** | /462 = Bar | ✓ 1.499 |

### Block 0x32 (13 data bytes) — Vehicle Speed (Verified 2026-03-18)
Real vehicle idle: all zeros. Driving: `17 00 ...` (23 km/h), `1F 00 ...` (31 km/h)

| Offset | Bytes | Field | Formula | Verified |
|--------|-------|-------|---------|----------|
| [0] | u8 | **Vehicle Speed** | **single byte = km/h** | 0, 23, 31 |
| [1-12] | — | (reserved) | all zeros | — |
