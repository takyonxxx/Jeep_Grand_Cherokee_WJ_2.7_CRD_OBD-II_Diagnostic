# Jeep Grand Cherokee WJ 2.7 CRD - Diagnostic Protocol Analysis

## Architecture Overview

| Bus | Protocol | ELM327 | Modules |
|-----|----------|--------|---------|
| **K-Line** | ISO 14230-4 (KWP2000) | ATSP5 | Engine ECU (0x15), **TCM (0x20)** |
| **J1850 VPW** | SAE J1850 VPW | ATSP2 | ABS (0x40), Airbag (0x60), BCM (0x80), body modules |

**Real vehicle verified:** TCM (NAG1 722.6) uses K-Line only (address 0x20). Does NOT respond on J1850 VPW (0x28 is US-market 545RFE only).

---

## 1. ELM327 Init

```
ATZ → ATE1 → ATH1 → ATIFR0 → ATSP2
```

---

## 2. Engine ECU (0x15) - K-Line

```
ATZ → ATE1 → ATH1 → ATWM8115F13E → ATSH8115F1 → ATSP5 → ATFI → 81 → 27 01/02
```

**Blocks (SID 0x21):**

| Block | Bytes | Content | Security | Verified |
|-------|-------|---------|----------|----------|
| 0x12 | 34 | Coolant, IAT, TPS, MAP, Rail, AAP | No | OK |
| 0x28 | 30 | RPM, Injection Qty | No | OK |
| 0x20 | 32 | MAF sensor values | No | OK |
| 0x22 | 34 | Rail spec, MAP spec | No | OK |
| 0x62 | - | EGR, Wastegate, Glow | **Yes** | NRC 0x33 |
| 0xB0-B2 | - | Injector/Boost/Fuel adaptation | **Yes** | NRC 0x33 |

Security key `CD 46` is static and rejected. Seed-to-key algorithm needed.

---

## 3. TCM / NAG1 722.6 (0x20) - K-Line

```
ATZ → ATE1 → ATH1 → ATWM8120F13E → ATSH8120F1 → ATSP5 → ATFI → 81 → 27 01/02
```

**CRITICAL:** K-Line requires full ATZ+ATWM+ATFI+81 reinit for EVERY switch, even returning to same module. Session is lost when switching between K-Line modules.

### Verified TCM Blocks (SID 0x21)

| Block | Bytes | Content | Verified |
|-------|-------|---------|----------|
| **0x30** | **22** | **Live transmission data (RPM, temp, gear, speed, solenoids)** | **OK** |
| 0x50 | 51 | Adaptation values (NRC 0x78 pending, then data) | OK |
| 0x60 | 2 | Status (00 01) | OK |
| 0x70 | ~240 | Shift map / calibration table | OK |
| 0x80 | 27 | Configuration / DTC config | OK |
| 0xB0 | 5 | Part number ("je0a") | OK |
| 0xE0 | 8 | Software ID ("aafwspsp") | OK |
| 0xE1 | 5 | Version info | OK |

Blocks 0x01-0x28, 0x40, 0x62, 0x90-0xFF → NRC 0x12 (subFunctionNotSupported)

### Block 0x30 - Live Data (22 bytes)

Real vehicle data at idle (P position, engine running):

```
98 F1 20 61 30 | 02 EE 00 1E 00 00 00 07 04 00 BB 59 00 0A 00 11 00 00 00 18 00 08
                  [0-1] [2-3] [4-5] [6-7] [8] [9-10] [11] [12-13] [14-15] ...  [18]
```

**Byte mapping (tentative, from idle/P/N/D comparison):**

| Bytes | Idle P (off) | Idle P (on) | Idle D | Interpretation |
|-------|-------------|-------------|--------|----------------|
| [0-1] | 00 22 (34) | 02 EE (750) | 02 EE (750) | Turbine RPM |
| [2-3] | 00 1E (30) | 00 3C (60) | 00 1E (30) | Output RPM or status |
| [4-5] | 00 00 | 00 00 | 00 00 | Vehicle Speed |
| [7] | 08→05 | 05 | 05 | Counter/status (decreasing) |
| [8] | 04 | 04 | 04 | Gear selector (P=4) |
| [9-10] | varies | 00 11 | | Solenoid current/pressure |
| [11] | 55→5A | 5A (90) | 5A | Trans Temp raw (90-40=50°C) |
| [12-13] | FFE1→000B | 000B | | TCC slip (signed) |
| [14-15] | FFE1→0012 | 0012 | | Desired TCC slip (signed) |
| [18] | 96/80/00 | 00 | | TCC/solenoid state |

### TCM Other Commands (APK verified)

| Command | SID | Description |
|---------|-----|-------------|
| `18 02 FF 00` | 0x18 | ReadDTCsByStatus → response `58 00` = 0 DTCs |
| `1A 86` | 0x1A | ReadEcuId → manufacturer data |
| `1A 90` | 0x1A | ReadEcuId → VIN/part number |
| `30 10 07 xx xx` | 0x30 | InputOutputControl (solenoid test) |
| `31 31` / `31 32` | 0x31 | StartRoutine |
| `3B 90` | 0x3B | WriteDataByLocalID (adaptation) |
| `14 00 00` | 0x14 | ClearDTCs |

---

## 4. ABS (0x40) - J1850 VPW

```
ATSP2 → ATSH244022 → ATRA40
```

No DiagSession needed. Live data: `20 PID 00` format.

| PID | Verified |
|-----|----------|
| 0x00-0x06 | Data OK (`26 40 62 xx xx xx xx`) |
| 0x07-0x09 | NRC 0x12 |

**DTC Read:** `ATSH244022` → `24 00 00` (special PID for DTC data)
**DTC Clear:** `ATSH244011` → `01 01 00` (ECUReset)

---

## 5. Airbag (0x60) - J1850 VPW

```
ATSP2 → ATSH246022 → ATRA60
```

All PIDs return NRC on tested vehicle (conditionsNotCorrect / subFuncNotSupported).

**DTC Read:** `ATSH246022` → `28 37 00`
**DTC Clear:** `ATSH246011` → `0D`

---

## 6. Bus Switching

### K-Line switch (any direction):
**ALWAYS full reinit** — session lost on every switch, even same module.
```
ATZ → ATE1 → ATH1 → ATWM81xxF13E → ATSH81xxF1 → ATSP5 → ATFI → 81 → 27
```

### J1850 same-bus switch:
```
ATSH24xxYY → ATRAxx (header + filter only)
```

### Cross-bus switch:
Full ATZ reset + target bus init sequence.

---

## 7. Timing

| Parameter | Value |
|-----------|-------|
| ATZ response | ~840ms |
| ATFI response | ~470ms |
| K-Line block read | ~300ms |
| J1850 PID read | ~150-220ms |
| Full K-Line module switch | ~4.5s (ATZ+ATWM+ATSH+ATSP5+ATFI+81+27) |

---

## 8. Real Vehicle Test Results (2025-03-07)

**Setup:** Android + Viecar BLE (ELM327 v1.5 clone) + Jeep WJ 2.7 CRD

| Module | Bus | Status |
|--------|-----|--------|
| Engine ECU (0x15) | K-Line | Blocks 0x12/28/20/22 OK |
| **TCM (0x20)** | **K-Line** | **Block 0x30 live data OK! DTC read OK!** |
| TCM (0x28) | J1850 | NO RESPONSE (US market only) |
| ABS (0x40) | J1850 | PIDs 0x00-0x06 OK |
| Airbag (0x60) | J1850 | All NRC |
| Battery | ATRV | 14.4-14.6V |

**TCM block 0x30 confirmed working** — 22 bytes live data, updates in real-time.
**DTC read confirmed** — `18 02 FF 00` → `58 00` (0 stored DTCs).
**ECU identification** — `1A 86` returns manufacturer data, `1A 90` returns part info.

### Known Issues
- Security key `CD 46` rejected by both ECU and TCM (need seed-to-key algorithm)
- TCM ATFI occasionally fails with `BUS INIT: ERROR` after rapid K-Line switching (retry resolves)
- Block 0x30 byte mapping needs driving test data to confirm speed/gear bytes
- ECU blocks 0x62/B0-B2 locked behind security access
