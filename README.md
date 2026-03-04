# Jeep Grand Cherokee WJ 2.7 CRD - Module Init Sequence Analysis

## Architecture Overview

The Jeep WJ 2.7 CRD uses **two separate communication buses**:

| Bus | Protocol | ELM327 Command | Modules |
|-----|----------|----------------|---------|
| **K-Line** | ISO 14230-4 (KWP2000) | ATSP5 | Engine ECU (0x15), TCM/Gearbox (0x20) |
| **J1850 VPW** | SAE J1850 VPW | ATSP2 | TCM (0x28), ABS (0x40), Airbag (0x60), and 10+ modules |

The Engine ECU and Transmission are accessible over **both K-Line and J1850**. K-Line provides deep diagnostics (block reads, security access), while J1850 is used for basic PID reading.

---

## 1. ELM327 Connection Init (Common)

```
ATZ            -> ELM327 reset
ATE1           -> Echo ON
ATH1           -> Headers ON
ATIFR0         -> Disable IFR (In-Frame Response) for J1850 VPW
```

These 4 commands run once before connecting to any module. What follows depends on the target module's bus type.

---

## 2. Engine ECU (Bosch EDC15C2 OM612) - K-Line Init

**Bus:** K-Line (ISO 14230-4)
**Address:** 0x15
**Init Sequence:**

```
ATZ                -> Full reset
ATWM8115F13E       -> Wakeup message (target 0x15, source 0xF1, pattern 0x3E)
ATSH8115F1         -> Set header (ECU addr 0x15, tester addr 0xF1)
ATSP5              -> Select ISO 14230-4 fast init protocol
ATFI               -> Fast init trigger (bus init)
81                 -> StartCommunication (KWP2000 SID 0x81)
27 01              -> SecurityAccess - request seed
27 02 [CD 46]      -> SecurityAccess - send key
```

**Note:** ATWM and ATSH are sent **before** ATSP5. The ELM327 stores the wakeup/header configuration first, then the protocol is selected and fast init is triggered.

**Post-init commands:**

| Command | Description |
|---------|-------------|
| `21 12` | ReadLocalData - Coolant, IAT, TPS, MAP, Rail Pressure, AAP |
| `21 28` | ReadLocalData - RPM, Injection Qty, Corrections |
| `21 62` | ReadLocalData - EGR, Wastegate, Glow Plugs, MAF, Alternator |
| `21 B0` | ReadLocalData - additional block (test/calibration data) |
| `21 B1` | ReadLocalData - additional block (test/calibration data) |
| `21 B2` | ReadLocalData - additional block (test/calibration data) |
| `1A 86` | ReadEcuId - Manufacturer |
| `1A 90` | ReadEcuId - VIN |
| `1A 91` | ReadEcuId - Hardware version |
| `18 02 00 00` | ReadDTCsByStatus - Read fault codes |
| `14 00 00` | ClearDTCs - Clear fault codes |
| `31 25 00` | StartRoutine |
| `30 3A 01/08` | InputOutputControl |

---

## 3. Transmission/TCM (NAG1 722.6) - K-Line Init

**Bus:** K-Line (ISO 14230-4)
**Address:** 0x20
**Init Sequence:**

```
ATZ                -> Full reset (shares physical bus with Engine ECU, switch required)
ATWM8120F13E       -> Wakeup message (target 0x20, source 0xF1, pattern 0x3E)
ATSH8120F1         -> Set header (TCM addr 0x20, tester addr 0xF1)
ATSP5              -> ISO 14230-4 fast init
ATFI               -> Fast init trigger
81                 -> StartCommunication
27 01 / 27 02      -> SecurityAccess (if required)
```

**K-Line TCM Commands:**
```
18 02 FF 00        -> ReadDTCsByStatus (all DTCs)
31 31              -> StartRoutine 0x31
31 32              -> StartRoutine 0x32
```

**Note:** K-Line TCM (0x20) shares the same physical wire as the Engine ECU. Switching between them requires a full ATZ reset.

---

## 4. TCM/Transmission (NAG1) - J1850 VPW Init

**Bus:** J1850 VPW
**Address:** 0x28
**Init Sequence:**

```
ATSP2              -> Select J1850 VPW protocol
ATIFR0             -> Disable IFR (may already be set)
ATH1               -> Headers ON
ATSH242810         -> Functional header (DiagSession, Reset, etc.)
```

**Session:** No diagnostic session start command is needed for J1850 TCM. PID reading begins directly.

**TCM J1850 Headers (all SIDs):**

| Header | SID | Description |
|--------|-----|-------------|
| `ATSH242810` | 0x10 | DiagnosticSession |
| `ATSH242811` | 0x11 | ECUReset |
| `ATSH242814` | 0x14 | ClearDTCs |
| `ATSH242820` | 0x20 | ReturnToNormal |
| `ATSH242822` | 0x22 | ReadDataByID (live data) |
| `ATSH242830` | 0x30 | RoutineControl |
| `ATSH2428A0` | 0xA0 | Download/Upload |
| `ATSH2428A3` | 0xA3 | WriteDataByAddress |

---

## 5. ABS (Anti-lock Braking System) - J1850 VPW Init

**Bus:** J1850 VPW
**Address:** 0x40
**Init Sequence:**

```
ATSP2              -> Select J1850 VPW protocol
ATSH244022         -> ABS ReadDataByID header
ATRA40             -> Filter/listen for ABS address responses
```

**ABS Headers:**

| Header | SID | Description |
|--------|-----|-------------|
| `ATSH244011` | 0x11 | ECUReset |
| `ATSH244022` | 0x22 | ReadDataByID |
| `ATSH24402F` | 0x2F | IOControl (actuator test) |
| `ATSH2440B4` | 0xB4 | ReadMemoryByAddress |

**ABS PID Groups (SID 0x20, 0x2E series):**
```
20 00..20 09       -> Basic status data
2E 00..2E 54       -> Extended diagnostic data (30+ PIDs)
```

**Note:** ABS has no SecurityAccess (0x27) header - no security required.

---

## 6. Airbag/ORC (AOSIM) - J1850 VPW Init

**Bus:** J1850 VPW
**Address:** 0x60
**Init Sequence:**

```
ATSP2              -> Select J1850 VPW protocol
ATSH246022         -> Airbag ReadDataByID header
ATRA60             -> Listen for Airbag messages
```

**Airbag Headers:**

| Header | SID | Description |
|--------|-----|-------------|
| `ATSH246011` | 0x11 | ECUReset |
| `ATSH246022` | 0x22 | ReadDataByID |
| `ATSH246027` | 0x27 | SecurityAccess |
| `ATSH246031` | 0x31 | StartRoutine |
| `ATSH2460A0` | 0xA0 | Download/Upload |
| `ATSH2460A3` | 0xA3 | WriteDataByAddress |
| `ATSH2460B4` | 0xB4 | ReadMemoryByAddress |

The Airbag module supports SecurityAccess (0x27) for crash data clearing and reprogramming operations.

**Airbag + BCM cross-reading:**
```
ATSH246022   -> Read Airbag data
ATRA60       -> Listen for Airbag messages
ATRA80       -> Listen for BCM messages (airbag status also read from BCM)
ATSH248022   -> BCM ReadDataByID
ATSH2480B4   -> BCM ReadMemoryByAddress
```

---

## 7. Other J1850 Modules

| Module | Address | Headers | Features |
|--------|---------|---------|----------|
| **Security/SKIM** | 0x62 | ATSH246211, 246222 | Immobilizer, key programming |
| **HVAC/ATC** | 0x68 | ATSH246811, 246822, 246831, 246833 | Climate control, StartRoutine+StopRoutine |
| **BCM (Body Computer)** | 0x80 | ATSH248022, 24802F, 2480B4 | Body control, IOControl, memory read |
| **Radio/Audio** | 0x87 | ATSH248722, 24872F | Radio, IOControl |
| **Instrument Cluster** | 0x90 | ATSH249011, 249022, 24902F | Odometer, IOControl |
| **Memory Seat** | 0x98 | ATSH249811, 249822, 24982F, 249830 | Seat/mirror position |
| **Power Liftgate** | 0xA0 | ATSH24A022, 24A02F | Tailgate |
| **HandsFree/Uconnect** | 0xA1 | ATSH24A122, 24A12F, 24A131, 24A133 | Phone, Start/Stop Routine |
| **Park Assist** | 0xC0 | ATSH24C011, 24C022, 24C027, 24C02F, 24C0B4 | Parking sensor, Security, Memory |
| **Overhead Console (EVIC)** | 0x2A | ATSH242A22, 242A2F, 242AB7 | Compass/temperature, DynData |

---

## 8. Bus Switching Strategy (K-Line <-> J1850)

### Switching to K-Line (J1850 -> K-Line):
```
ATZ              -> Full ELM327 reset (7500ms timeout)
ATE1             -> Echo ON
ATH1             -> Headers ON
ATWM81xxF13E     -> Wakeup (xx = module address: 0x15 or 0x20)
ATSH81xxF1       -> Set header
ATSP5            -> Select K-Line protocol
ATFI             -> Fast init trigger
81               -> StartCommunication
27 01 / 27 02    -> SecurityAccess
```

### Switching to J1850 (K-Line -> J1850):
```
ATZ              -> Full ELM327 reset
ATE1             -> Echo ON
ATH1             -> Headers ON
ATIFR0           -> Disable IFR
ATSP2            -> Select J1850 VPW protocol
ATSH24xxYY       -> Set header (xx = module, YY = SID)
```

### Same-bus module change (J1850 -> J1850):
```
ATSH24xxYY       -> Just change the header (no ATZ needed)
```

Switching between J1850 modules only requires changing the ATSH header. K-Line module switches require a full ATZ reset + ATSP5 + ATFI sequence.
