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
ATSP2          -> Select J1850 VPW as default protocol
```

These 5 commands run once at connection. No ATAT, ATST, ATRV, or ATI commands are sent during init (APK confirmed). What follows depends on the target module's bus type.

---

## 2. Engine ECU (Bosch EDC15C2 OM612) - K-Line Init

**Bus:** K-Line (ISO 14230-4)
**Address:** 0x15
**Init Sequence:**

```
ATZ                -> Full reset
ATE1               -> Echo ON
ATH1               -> Headers ON
ATWM8115F13E       -> Wakeup message (target 0x15, source 0xF1, pattern 0x3E)
ATSH8115F1         -> Set header (ECU addr 0x15, tester addr 0xF1)
ATSP5              -> Select ISO 14230-4 fast init protocol
ATFI               -> Fast init trigger (bus init)
81                 -> StartCommunication (KWP2000 SID 0x81)
27 01              -> SecurityAccess - request seed
27 02 [CD 46]      -> SecurityAccess - send key
```

**Note:** ATWM and ATSH are sent **before** ATSP5. The ELM327 stores the wakeup/header configuration first, then the protocol is selected and fast init is triggered. Ignition must be ON (ACC or RUN) for ATFI to succeed.

**Post-init commands (ReadLocalData SID 0x21):**

| Command | Description |
|---------|-------------|
| `21 12` | Coolant, IAT, TPS, MAP, Rail Pressure, AAP |
| `21 28` | RPM, Injection Qty, Corrections |
| `21 62` | EGR, Wastegate, Glow Plugs, MAF, Alternator |
| `21 B0` | Injector corrections, oil pressure |
| `21 B1` | Boost/idle adaptation |
| `21 B2` | Fuel adaptation |

**Other K-Line commands:**

| Command | Description |
|---------|-------------|
| `1A 86` | ReadEcuId - Manufacturer |
| `1A 90` | ReadEcuId - VIN |
| `1A 91` | ReadEcuId - Hardware version |
| `18 02 00 00` | ReadDTCsByStatus - Read fault codes |
| `14 00 00` | ClearDTCs - Clear fault codes |

---

## 3. Transmission/TCM (NAG1 722.6) - K-Line Init

**Bus:** K-Line (ISO 14230-4)
**Address:** 0x20
**Init Sequence:**

```
ATZ                -> Full reset (shares physical bus with Engine ECU, switch required)
ATE1               -> Echo ON
ATH1               -> Headers ON
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
14 00 00           -> ClearDTCs
```

**Note:** K-Line TCM (0x20) shares the same physical wire as the Engine ECU. Switching between them requires a full ATZ reset.

---

## 4. TCM/Transmission (NAG1) - J1850 VPW Init

**Bus:** J1850 VPW
**Address:** 0x28
**Init Sequence:**

```
ATSP2              -> Select J1850 VPW protocol
ATSH242810         -> Functional header (DiagSession, Reset, etc.)
```

**Session:** No diagnostic session start command is needed for J1850 TCM (APK confirmed). PID reading begins directly after ATSH.

**Live Data Reading (APK verified):**

```
ATSH242822         -> Switch to ReadDataByID header
2E PID 00          -> Read PID (e.g. "2E 10 00" for Turbine RPM)
Response: 62 PID DATA
```

The command format is `2E [PID] 00` — the `2E` prefix is the TCM's LocalID identifier, `00` is padding for 3-byte minimum. This is different from standard OBD-II `22 PID` format.

**TCM J1850 Live Data PIDs (APK verified):**

| PID | Description |
|-----|-------------|
| 0x01 | Actual Gear |
| 0x02 | Selected Gear |
| 0x03 | Max Gear |
| 0x04 | Shift Selector Position |
| 0x10 | Turbine RPM |
| 0x11 | Input RPM (N2) |
| 0x12 | Input RPM (N3) |
| 0x13 | Output RPM |
| 0x14 | Transmission Temp |
| 0x15 | TCC Pressure |
| 0x16 | Solenoid Supply Voltage |
| 0x17 | Limp Mode Status |
| 0x20 | Vehicle Speed |
| 0x21 | TCC Clutch State |
| 0x22 | Actual TCC Slip |
| 0x23 | Desired TCC Slip |
| 0x24 | Shift Solenoid 1-2 / 4-5 |
| 0x25 | Shift Solenoid 2-3 |
| 0x26 | Shift Solenoid 3-4 |
| 0x27 | Shift Pressure Solenoid |
| 0x30 | Battery Voltage (ATRV) |

**TCM J1850 Headers (all SIDs from APK):**

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

**DTC Reading:**
```
ATSH242810         -> Functional header
18 02 FF 00        -> ReadDTCsByStatus
14 00 00           -> ClearDTCs
```

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

**Live Data Reading (APK verified):**

```
20 PID 00          -> Read PID (e.g. "20 01 00" for LF Wheel Speed)
Response: 60 PID DATA
```

The ABS module uses `20` prefix (its own SID) followed by PID and `00` padding.

**ABS PID Groups:**
```
20 00..20 09       -> Basic status data (wheel speeds, vehicle speed)
2E 10..2E 30       -> Extended diagnostic data (sensor readings)
2E 50..2E 54       -> Additional diagnostic data
```

**ABS Headers (from APK):**

| Header | SID | Description |
|--------|-----|-------------|
| `ATSH244011` | 0x11 | ECUReset |
| `ATSH244022` | 0x22 | ReadDataByID |
| `ATSH24402F` | 0x2F | IOControl (actuator test) |
| `ATSH2440B4` | 0xB4 | ReadMemoryByAddress |

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

**Live Data Reading (APK verified):**

```
28 PID 00          -> Read PID (e.g. "28 00 00" for status)
Response: 68 PID DATA
```

The Airbag module uses `28` prefix followed by PID and `00` padding.

**Airbag PIDs:**
```
28 00..28 05       -> Airbag status data
```

**Airbag Headers (from APK):**

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

**Airbag + BCM cross-reading (from APK):**
```
ATSH246022   -> Read Airbag data
ATRA60       -> Listen for Airbag messages
ATRA80       -> Listen for BCM messages (airbag status also read from BCM)
ATSH248022   -> BCM ReadDataByID
ATSH2480B4   -> BCM ReadMemoryByAddress
```

---

## 7. Other J1850 Modules

| Module | Address | ATRA | Headers | Features |
|--------|---------|------|---------|----------|
| **Security/SKIM** | 0x62 | - | ATSH246211, 246222 | Immobilizer, key programming |
| **HVAC/ATC** | 0x68 | - | ATSH246811, 246822, 246831, 246833 | Climate control, StartRoutine+StopRoutine |
| **BCM (Body Computer)** | 0x80 | ATRA80 | ATSH248022, 24802F, 2480B4 | Body control, IOControl, memory read |
| **Radio/Audio** | 0x87 | - | ATSH248722, 24872F | Radio, IOControl |
| **Instrument Cluster** | 0x90 | - | ATSH249011, 249022, 24902F | Odometer, IOControl |
| **Memory Seat** | 0x98 | - | ATSH249811, 249822, 24982F, 249830 | Seat/mirror position |
| **Power Liftgate** | 0xA0 | - | ATSH24A022, 24A02F | Tailgate |
| **HandsFree/Uconnect** | 0xA1 | - | ATSH24A122, 24A12F, 24A131, 24A133 | Phone, Start/Stop Routine |
| **Park Assist** | 0xC0 | - | ATSH24C011, 24C022, 24C027, 24C02F, 24C0B4 | Parking sensor, Security, Memory |
| **Overhead Console (EVIC)** | 0x2A | - | ATSH242A22, 242A2F, 242AB7 | Compass/temperature, DynData |

---

## 8. J1850 VPW Command Format (APK Verified)

Each J1850 module uses its **own SID prefix** in the data portion when the header includes the SID byte:

| Module | Header (ReadData) | Data Format | Example |
|--------|-------------------|-------------|---------|
| **TCM (0x28)** | ATSH242822 | `2E PID 00` | `2E 10 00` → Turbine RPM |
| **ABS (0x40)** | ATSH244022 | `20 PID 00` | `20 01 00` → LF Wheel Speed |
| **Airbag (0x60)** | ATSH246022 | `28 PID 00` | `28 00 00` → Status |

The `00` suffix is padding to meet the 3-byte minimum message length.

**Response format:** Positive response SID = request SID + 0x40:
- TCM: `2E` request → `62` response (0x2E + 0x40 = 0x6E? Actually response uses standard 0x62)
- ABS: `20` request → `60` response
- Airbag: `28` request → `68` response

**For session/DTC commands**, the functional header is used:
```
ATSH24xx10         -> Functional header (source=0x10)
10 89              -> DiagnosticSession (SID in data)
18 02 FF 00        -> ReadDTCsByStatus (SID in data)
14 00 00           -> ClearDTCs (SID in data)
```

---

## 9. Bus Switching Strategy (K-Line <-> J1850)

### Switching to K-Line (J1850 -> K-Line):
```
ATZ              -> Full ELM327 reset
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
ATSP2            -> Select J1850 VPW protocol
ATSH24xxYY       -> Set header (xx = module, YY = SID)
ATRAxx           -> Set receive filter (if required: ABS=ATRA40, Airbag=ATRA60, BCM=ATRA80)
```

### Same-bus module change (J1850 -> J1850):
```
ATSH24xxYY       -> Change header
ATRAxx           -> Set receive filter (if required)
```

Switching between J1850 modules only requires changing the ATSH header (and ATRA filter if applicable). K-Line module switches require a full ATZ reset + ATSP5 + ATFI sequence.

### ATFI Failure Recovery:
If K-Line ATFI fails (e.g. ignition off), the code automatically:
1. Sends ATZ to reset
2. Restores J1850 VPW (ATE1→ATH1→ATSP2)
3. Restores previous J1850 module ATSH header
4. Reports error but keeps J1850 session alive

---

## 10. Timing (APK Verified)

| Parameter | Value | Notes |
|-----------|-------|-------|
| **Inter-command delay** | 340ms | Timer between sequential commands |
| **ATZ timeout** | ~840ms | ELM327 reset response time |
| **ATFI timeout** | ~930ms | K-Line bus init response time |
| **AT command response** | ~35-80ms | Typical AT command response |
| **NO DATA response** | ~140-200ms | When module doesn't respond |
| **ATZ recovery delay** | 500ms | After ATZ before next command |

---

## 11. ELM327 Compatibility

- **Genuine ELM327 recommended:** ATFI, ATWM, ATSH support required for K-Line ECU access
- **Clone ELM327 (v1.5/v2.1):** J1850 VPW modules work, K-Line may fail (no ATFI support)
- **BLE OBD adapters:** Supported via Classic Bluetooth SPP (RFCOMM) connection
- **WiFi OBD adapters:** Supported via TCP connection (default 192.168.0.10:35000)
