# Jeep Grand Cherokee WJ 2.7 CRD - Diagnostic Protocol Analysis

**Last updated: 2025-03-10** (real vehicle verified)

## Architecture Overview

| Bus | Protocol | ELM327 | Modules |
|-----|----------|--------|---------|
| **K-Line** | ISO 14230-4 (KWP2000) | ATSP5 | Engine ECU (0x15), **TCM (0x20)** |
| **J1850 VPW** | SAE J1850 VPW | ATSP2 | ABS (0x40), Airbag (0x60), **HVAC (0x68)**, SKIM (0x62) |

**Connectivity:** WiFi TCP (192.168.0.10:35000) + BLE GATT (FFF0/FFF1/FFF2)
**Platforms:** Android (BLE) + iOS (BLE GATT via QLowEnergyController)
**ELM327:** Viecar BLE clone (v1.5)

---

## 1. Connection

### BLE (iOS + Android)
```
Scan (LowEnergyMethod) -> Find "Viecar"/"OBD"/"vLink" etc
QLowEnergyController -> Service discovery
Service FFF0 -> Write FFF2 (0x0c) + Notify FFF1 (0x10)
Enable CCCD 0x0100 -> Ready
```

### WiFi
```
TCP 192.168.0.10:35000 -> ATZ -> ATE1 -> ATH1 -> ATIFR0 -> ATSP2
```

### K-Line Module Init (EVERY switch requires full reinit)
```
ATZ -> ATE1 -> ATH1 -> ATWM81xxF13E -> ATSHxxxx -> ATSP5 -> ATFI -> 81 -> 27 01/02
```

---

## 2. TCM / NAG1 722.6 (0x20) - K-Line

### Security
- Seed: **static** `68 24` (+ padding byte `89`)
- Algorithm: EGS52 (swap, XOR 0x5AA5, multiply 0x5AA5)
- Key: **CC 21** - CONFIRMED WORKING
- Init: `ATWM8120F13E` -> `ATSH8120F1` -> `ATSP5` -> `ATFI` -> `81` -> `27 01` -> `27 02 CC 21`

### Block 0x30 - Live Data (22 bytes)

Verified with real vehicle P/D idle + driving (2025-03-10):

| Byte | Parameter | P idle | D idle | D driving | D cruise |
|------|-----------|--------|--------|-----------|----------|
| **[0-1]** | N2/Turbine sensor | ~49 | ~222 | 300-500 | 30-50 (TCC lock) |
| **[2-3]** | Engage status | 0x1E(30) | 0x37(55) | 0x32-0x35 | 0x32-0x34 |
| **[4-5]** | Output shaft RPM | 0 | 0 | 600-800+ | 600-800 |
| [6] | Unknown | 0 | 0 | varies | varies |
| **[7]** | Selector: P=8,R=7,N=6,D=5 | 8 | 5 | 5 | 5 |
| [8] | Config (usually 4) | 4 | 4 | 4/0xFF/5 | 5 |
| **[9-10]** | Line pressure (signed) | 221 | 1092 | 600-900 | 700-800 |
| **[11]** | Trans temp (raw-40=C) | 0x4D(37C) | 0x5C(52C) | rising | 0x5E(54C) |
| **[12-13]** | TCC slip actual (signed) | ~-31 | ~100 | 100-200 | 150-200 |
| **[14-15]** | TCC slip desired (signed) | ~-31 | ~106 | tracks actual | tracks actual |
| [16-17] | Unknown counter | 0x05BF | 0x0610 | rising | 0x07D0+ |
| **[18]** | Solenoid mode | 0x96 | 0x08 | 0x08 | 0x08 |
| [19] | Status flags | 0x18 | 0x10 | 0x10 | 0x10 |
| [20] | Shift flags | 0x00 | 0x00 | 0x80/0x82 | 0x80 |
| [21] | Always 0x08 | 0x08 | 0x08 | 0x08 | 0x08 |

**NOTE:** Byte[0-1] is NOT raw turbine RPM. During TCC lockup at cruise, values drop to 30-50 regardless of engine RPM. This appears to be N2 clutch drum speed sensor. Gear detection via RPM ratio is unreliable from block 0x30 alone.

### Other TCM Blocks (all verified)

| Block | Bytes | Content |
|-------|-------|---------|
| 0x31 | 24 | `01 A8 00 00 02 B9 02 EC...` - shift parameters |
| 0x32 | 16 | All zero at idle |
| 0x50 | 51 | All zero (NRC 0x78 pending first, then data) |
| 0x60 | 2 | `00 01` - status flags |
| 0x70 | ~244 | Shift calibration / pressure table (large) |
| 0x80 | 27 | DTC/shift configuration parameters |
| 0xB0 | 4 | ASCII `je0a` - part ID |
| 0xC0 | 34 | Lookup table (0,100,25,30,35,40...) |
| 0xD0 | 16 | All zero (NRC 0x78 pending first) |
| 0xE0 | 8 | ASCII `aafwspsp` - software ID |
| 0xE1 | 4 | `01 61 90 46` - calibration version |
| 0x40,0x90,0xA0,0xE2,0xF0 | - | NRC 0x12 (not supported) |

### TCM Identification

| Command | Response |
|---------|----------|
| `1A 86` | `5A 86 56 04 19 06 BC 03 01 02 03 08 02 00 00 03 03 11` |
| `1A 87` | `5A 87 02 08 02 00 00 03 01` + ASCII `56041906BC` |
| `1A 90` | `5A 90` + `00000000000000000` (VIN not programmed) |
| `1A 91` | NRC 0x12 |
| `1A 92` | NRC 0x12 |
| `18 02 FF 00` | `58 00` = 0 DTCs |
| `14 00 00` | `54 00 00` = clear OK |
| `30 10 07 00 02` | NRC 0x22 (conditionsNotCorrect) |
| `3B 90` | NRC 0x79 (responsePending?) |

---

## 3. Engine ECU (0x15) - K-Line

### Security
- Seed: **dynamic** 2-byte (changes every session)
- Level 01 (27 01 -> 27 02): **SUPPORTED** (2-byte key format)
- Level 03 (27 03): NRC 0x12 = NOT SUPPORTED
- Level 41 (27 41): NRC 0x12 = NOT SUPPORTED
- 4-byte key: NRC 0x12 = WRONG FORMAT
- 2-byte key: NRC 0x35 = CORRECT FORMAT, WRONG KEY
- **Constants unknown** - tested EDC16/EDC15P/EDC15V/EDC15VM+ - all NRC 0x35
- Needed: "Chrysler EDC15" (#09) or "Mercedes CDI E2" (#15) algorithm constants
- Init: `ATWM8115F13E` -> `ATSH8115F1` -> `ATSP5` -> `ATFI` -> `81` -> `27 01` -> `27 02 XX XX`

### ECU Blocks (no security required)

| Block | Bytes | Content | Key Parameters |
|-------|-------|---------|----------------|
| **0x12** | 34 | Sensors | Coolant, IAT, TPS, MAP, Rail, AAP |
| **0x28** | 30 | Engine | RPM, Injection Qty |
| **0x20** | 32 | Airflow | MAF actual/spec |
| **0x22** | 34 | Fuel | Rail spec, MAP spec |
| **0x10** | 18 | Idle/limits | Idle target, Max RPM (3000) |
| **0x14** | 12 | Unknown | `7DFE 8241 8241 FF82 E607 FFE6` |
| **0x16** | 40 | Idle/fuel | `012C`(300), `2710`(10000), `0794`(1940) |
| **0x18** | 30 | (all zero at idle) | May contain data during driving |
| **0x24** | 26 | RPM thresholds | `0746`(1862), `07B9`(1977), `094E`(2382) |
| **0x26** | 32 | Sensor raw | Accel pedal raw, injector trims, coolant raw |
| **0x30** | 26 | RPM setpoints | Idle RPM set=750, `0AD9`(2777), `0B91`(2961) |
| **0x40** | 52 | (all zero at idle) | May contain data during driving |

### ECU Blocks (security required - NRC 0x33)

| Block | Expected Content |
|-------|-----------------|
| 0x60 | Unknown |
| 0x62 | EGR duty, Wastegate, Glow plugs, MAF, Alternator |
| 0xB0 | Injector corrections, learn status, oil pressure |
| 0xB1 | Boost adaptation, idle adaptation |
| 0xB2 | Fuel quantity adaptation |

### ECU Blocks (not supported - NRC 0x12)
`0x1A, 0x1C, 0x1E, 0x2A, 0x50`

### ECU Identification

| Command | Response |
|---------|----------|
| `1A 86` | `5A 86 CA 65 34 40 65 30 99 05 F2 03 14 14 14 FF FF FF` |
| `1A 87` | NRC 0x12 |
| `1A 90` | NRC 0x33 (needs security) |
| `1A 91` | `5A 91 ... 20 20 57 43 41 41 41 20` = `  WCAAA ` |

### ECU DTCs (from real vehicle)
- **P0520** - Oil Pressure Sensor/Switch Circuit (stored)
- **P0579** - Cruise Control Multi-Function Input (stored)
- **P0340** - CMP Position Sensor (stored)
- **P1242** - CAN Bus - TCM Message Missing (stored)

---

## 4. ABS (0x40) - J1850 VPW

```
ATSP2 -> ATSH244022 -> ATRA40
```

| PID | Response | Content |
|-----|----------|---------|
| 0x00 | `26 40 62 43 00 00` | DTC data |
| 0x01 | `26 40 62 38 92 00` | LF wheel speed |
| 0x02 | `26 40 62 41 43 00` | RF wheel speed |
| 0x03 | `26 40 62 01 00 00` | LR wheel speed |
| 0x04 | `26 40 62 1A 65 00` | RR wheel speed |
| 0x05 | `26 40 62 41 00 00` | Unknown |
| 0x06 | `26 40 62 02 00 00` | Unknown |
| 0x10 | `26 40 62 08 00 00` | Vehicle speed |
| 0x07+ | NRC 0x12 | Not supported |

DTC Read: `24 00 00`
DTC Clear: `ATSH244011` -> `01 01 00` (ECUReset)

---

## 5. Airbag (0x60) - J1850 VPW

```
ATSP2 -> ATSH246022 -> ATRA60
```

- DTC Read: `28 37 00` -> NRC 0x12 (may need different SID)
- DTC Clear: `ATSH246011` -> `0D`
- Most commands return NRC 0x12

---

## 6. HVAC / Climate (0x68) - J1850 VPW — NEW

```
ATSP2 -> ATSH246822 -> ATRA68
```

| PID | Response | Content |
|-----|----------|---------|
| 0x00 | `26 68 62 47 00 00` | Status/config |
| 0x01 | `26 68 62 FF 00 00` | Set temp? (0xFF = max) |
| 0x02 | `26 68 62 7F 00 00` | Fan/mode? |
| 0x03 | `26 68 62 01 00 00` | Status flag |
| 0x37 | NRC 0x52 | DTC read - different NRC |

---

## 7. Other Modules

| Module | Addr | Bus | Status |
|--------|------|-----|--------|
| SKIM | 0x62 | J1850 | `1A 87` partial response (`A4 62 81 <DATA ERROR`) |
| BCM | 0x80 | J1850 | NO DATA on all probes |
| Cluster | 0x90 | J1850 | NO DATA on all probes |
| Radio | 0x87 | J1850 | NO DATA |
| EVIC | 0x2A | J1850 | NO DATA |
| MemSeat | 0x98 | J1850 | NO DATA |
| Liftgate | 0xA0 | J1850 | NO DATA |

---

## 8. Timing

| Operation | Duration |
|-----------|----------|
| Full K-Line module switch (ATZ->ATFI->81->27) | ~7s |
| K-Line same-module reinit skip | 0s |
| Block 0x30 read (chain polling) | ~300ms |
| ECU 4-block cycle (0x12+0x28+0x20+0x22+ATRV) | ~3.5s |
| J1850 PID read | ~150-700ms |
| BLE GATT connect + service discovery | ~2s |
| ATFI occasional failure + retry | ~6s extra |
| Test v9 full scan (all phases) | ~3.5 min |

---

## 9. Known Issues

- **ECU security constants unknown** - 2-byte key format confirmed, but ProcessKey XOR/magic constants for Chrysler EDC15 / Mercedes CDI E2 not found
- TCM block 0x30 byte[0-1] is N2 sensor speed, NOT raw turbine RPM — drops to 30-50 during TCC lockup
- Gear detection from block 0x30 limited to selector range (P/R/N/D), actual gear (1-5) not available
- ATFI occasionally fails `BUS INIT: ERROR` after rapid switching (retry resolves)
- ECU blocks 0x62/0xB0-0xB2 locked behind security (NRC 0x33)
- TCM VIN (1A 90) all zeros — not programmed from factory?
- iOS: QBluetoothSocket not supported, BLE GATT required
- DTC clear after QMessageBox may need K-Line session re-establishment
