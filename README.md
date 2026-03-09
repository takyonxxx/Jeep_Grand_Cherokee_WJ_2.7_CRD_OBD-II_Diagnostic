# Jeep Grand Cherokee WJ 2.7 CRD - Diagnostic Protocol Analysis

## Architecture Overview

| Bus | Protocol | ELM327 | Modules |
|-----|----------|--------|---------|
| **K-Line** | ISO 14230-4 (KWP2000) | ATSP5 | Engine ECU (0x15), **TCM (0x20)** |
| **J1850 VPW** | SAE J1850 VPW | ATSP2 | ABS (0x40), Airbag (0x60), BCM (0x80) |

**Connectivity:** WiFi TCP (192.168.0.10:35000) + BLE GATT (FFF0/FFF1/FFF2 service)
**Platforms:** Android (BLE) + iOS (BLE GATT via QLowEnergyController)

---

## 1. Connection

### BLE (iOS + Android)
```
Scan (LowEnergyMethod only) → Find "Viecar"/"OBD"/etc
Connect via QLowEnergyController → Service discovery
Service FFF0 → Write char FFF2 (props=0x0c) + Notify char FFF1 (props=0x10)
Enable CCCD 0x0100 → Ready
```

### WiFi
```
TCP 192.168.0.10:35000 → ATZ → ATE1 → ATH1 → ATSP2
```

---

## 2. Engine ECU (0x15) - K-Line

```
ATZ → ATE1 → ATH1 → ATWM8115F13E → ATSH8115F1 → ATSP5 → ATFI → 81 → 27 01/02
```

| Block | Bytes | Content | Verified |
|-------|-------|---------|----------|
| 0x12 | 34 | Coolant, IAT, TPS, MAP, Rail, AAP | OK |
| 0x28 | 30 | RPM, Injection Qty | OK |
| 0x20 | 32 | MAF actual/spec | OK |
| 0x22 | 34 | Rail spec, MAP spec | OK |
| 0x62 | - | EGR, Wastegate, Glow | NRC 0x33 (security) |
| 0xB0-B2 | - | Adaptation | NRC 0x33 (security) |

---

## 3. TCM / NAG1 722.6 (0x20) - K-Line

```
ATZ → ATE1 → ATH1 → ATWM8120F13E → ATSH8120F1 → ATSP5 → ATFI → 81 → 27 01/02
```

**CRITICAL:** K-Line requires full ATZ+ATWM+ATFI+81 reinit for EVERY module switch.

### Block 0x30 - Live Data (22 bytes) — CONFIRMED

Real vehicle test (2025-03-09, P/R/N/D tested):

| Byte | Parameter | P | R | N | D | D+gas |
|------|-----------|---|---|---|---|-------|
| **[0-1]** | Turbine RPM | 22 | 751 | 19 | 748 | 1147 |
| **[2-3]** | Engage status (0x1E=P/N, 0x3C=R/D) | 30 | 60 | 30 | 60 | 60 |
| **[4-5]** | Vehicle Speed | 0 | 0 | 0 | 0 | 0 |
| **[7]** | **Gear: P=8, R=7, N=6, D=5, D2=4...D5=1** | 8 | 7 | 6 | 5 | 5 |
| [8] | Config (always 4) | 4 | 4 | 4 | 4 | 4 |
| **[9-10]** | Solenoid pressure | 221 | 187 | 0 | 17 | 17 |
| **[11]** | Trans Temp (raw-40=°C) | 53 | 56 | 57 | 59 | 56 |
| **[12-13]** | TCC Slip actual (signed) | -10 | +29 | -10 | +27 | +149 |
| **[14-15]** | TCC Slip desired (signed) | -10 | +49 | -10 | +45 | +253 |
| **[18]** | Solenoid state (P/N=0x96, R/D=0x00) | 150 | 0 | 150 | 0 | 0 |
| [19] | Mode flags (P=0x18, D=0x10) | 24 | 24 | 24 | 16 | 16 |

### Other TCM Blocks

| Block | Bytes | Content | Verified |
|-------|-------|---------|----------|
| 0x50 | 51 | Adaptation values (NRC 0x78 pending first) | OK |
| 0x60 | 2 | Status (00 01) | OK |
| 0x70 | ~240 | Shift map / calibration | OK |
| 0x80 | 27 | DTC configuration | OK |
| 0xB0 | 5 | Part number ("je0a") | OK |
| 0xE0 | 8 | Software ID ("aafwspsp") | OK |
| 0xE1 | 5 | Version (01 61 90 46) | OK |

Blocks 0x01-0x28, 0x40, 0x62, 0x90-0xFF → NRC 0x12

### TCM Commands (APK verified)

| Command | Description | Verified |
|---------|-------------|----------|
| `18 02 FF 00` | ReadDTCsByStatus → `58 00` = 0 DTCs | OK |
| `14 00 00` | ClearDTCs | OK |
| `1A 86` | ReadEcuId → manufacturer data | OK |
| `1A 90` | ReadEcuId → VIN/part number | OK |
| `30 10 07 xx` | IOControl (solenoid) → NRC 0x22 (no security) | OK |
| `3B 90` | Adaptation write → NRC 0x79 | OK |

---

## 4. ABS (0x40) - J1850 VPW

```
ATSP2 → ATSH244022 → ATRA40
```

| PID | Response | Verified |
|-----|----------|----------|
| 0x00-0x06 | `26 40 62 xx xx xx` | OK |
| 0x07+ | NRC 0x12 | OK |

**DTC Read:** `24 00 00` → DTC data via special PID
**DTC Clear:** `ATSH244011` → `01 01 00` (ECUReset)

---

## 5. Airbag (0x60) - J1850 VPW

**DTC Read:** `ATSH246022` → `28 37 00`
**DTC Clear:** `ATSH246011` → `0D`

---

## 6. Timing

| Operation | Duration |
|-----------|----------|
| Full K-Line module switch | ~4.5s |
| Block 0x30 read | ~300ms |
| J1850 PID read | ~150-220ms |
| BLE GATT connect + service discovery | ~2s |
| ATFI occasional failure + retry | ~6s extra |

---

## 7. Known Issues

- Security key `CD 46` rejected by both ECU and TCM (need seed-to-key algorithm)
- TCM seed always `68 24 89` (static)
- ATFI occasionally fails `BUS INIT: ERROR` after rapid switching (retry resolves)
- ECU blocks 0x62/B0-B2 locked behind security
- iOS: QBluetoothSocket not supported, BLE GATT required
- Android: QComboBox popup crash on MIUI (combo touch disabled, auto-select used)
