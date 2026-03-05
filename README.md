# Jeep Grand Cherokee WJ 2.7 CRD - Module Init Sequence Analysis

## Architecture Overview

The Jeep WJ 2.7 CRD uses **two separate communication buses**:

| Bus | Protocol | ELM327 Command | Modules |
|-----|----------|----------------|---------|
| **K-Line** | ISO 14230-4 (KWP2000) | ATSP5 | Engine ECU (0x15), **TCM/Gearbox (0x20)** |
| **J1850 VPW** | SAE J1850 VPW | ATSP2 | ABS (0x40), Airbag (0x60), BCM (0x80), and 10+ body modules |

**CRITICAL (real vehicle verified 2025-03-05):** The NAG1 722.6 Transmission on the 2.7 CRD uses **K-Line only** (address 0x20). It does NOT respond on J1850 VPW. The APK's J1850 address 0x28 is for US-market WJ with 545RFE/45RFE transmission. WJdiag official docs confirm: "Engine and Transmission of the Jeep 2.7 CRD are using K-Line data bus."

---

## 1. ELM327 Connection Init (Common)

```
ATZ            -> ELM327 reset
ATE1           -> Echo ON
ATH1           -> Headers ON
ATIFR0         -> Disable IFR (In-Frame Response) for J1850 VPW
ATSP2          -> Select J1850 VPW as default protocol
```

These 5 commands run once at connection. What follows depends on the target module's bus type.

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
27 02 [KEY]        -> SecurityAccess - send key (calculated from seed)
```

**Security Access:** The key must be calculated from the seed — static key `CD 46` does not work (NRC 0x35). Blocks 21 12, 21 28, 21 20, 21 22 work without security; blocks 21 62, 21 B0-B2 require valid security (NRC 0x33).

**Post-init commands (ReadLocalData SID 0x21):**

| Command | Description | Security | Verified |
|---------|-------------|----------|----------|
| `21 12` | Coolant, IAT, TPS, MAP, Rail Pressure, AAP | No | OK |
| `21 28` | RPM, Injection Qty, Corrections | No | OK |
| `21 20` | MAF sensor values | No | OK |
| `21 22` | Rail pressure spec, MAP spec | No | OK |
| `21 62` | EGR, Wastegate, Glow Plugs, MAF, Alternator | **Yes** | NRC 0x33 |
| `21 B0` | Injector corrections, oil pressure | **Yes** | NRC 0x33 |
| `21 B1` | Boost/idle adaptation | **Yes** | NRC 0x33 |
| `21 B2` | Fuel adaptation | **Yes** | NRC 0x33 |

---

## 3. TCM/Transmission (NAG1 722.6 EGS52) - K-Line Init

**Bus:** K-Line (ISO 14230-4)
**Address:** 0x20

**IMPORTANT:** K-Line modules share the same physical wire. Switching between ECU (0x15) and TCM (0x20) requires a **full ATZ reinit** — just changing ATSH is not enough. Each module needs its own ATWM wakeup + ATFI fast init + StartComm(81) sequence.

**Init Sequence (real vehicle verified):**

```
ATZ                -> Full reset (mandatory for K-Line module change)
ATE1               -> Echo ON
ATH1               -> Headers ON
ATWM8120F13E       -> Wakeup message (target 0x20, source 0xF1, pattern 0x3E)
ATSH8120F1         -> Set header (TCM addr 0x20, tester addr 0xF1)
ATSP5              -> ISO 14230-4 fast init
ATFI               -> Fast init trigger → "BUS INIT: OK" (verified!)
81                 -> StartCommunication → 83 F1 20 C1 EF 8F D3 (verified!)
27 01              -> SecurityAccess seed → 84 F1 20 67 01 xx xx (verified!)
27 02 [KEY]        -> SecurityAccess key (algorithm TBD, CD 46 rejected)
```

**Real vehicle test results (2025-03-05):**
- ATFI → BUS INIT: OK (TCM physically responds on K-Line)
- 81 → `83 F1 20 C1 EF 8F D3` (StartComm positive, address 0x20 confirmed)
- 27 01 → seed received (e.g. `68 24 89`)
- 27 02 CD 46 → NRC 0x35 (invalidKey - need seed-to-key algorithm)
- DTC 18 02 FF 00 → NRC 0x79 (format issue or security required)
- ReadLocalData blocks (21 01 - 21 FF) → TBD (first test used wrong init path)

**K-Line TCM Commands (from APK):**

| Command | SID | Description |
|---------|-----|-------------|
| `18 02 FF 00` | 0x18 | ReadDTCsByStatus |
| `31 31` | 0x31 | StartRoutine (routine 0x31) |
| `31 32` | 0x31 | StartRoutine (routine 0x32) |
| `30 10 07 00 02` | 0x30 | InputOutputControl (solenoid test) |
| `30 10 07 00 00` | 0x30 | InputOutputControl (solenoid off) |
| `30 10 07 04 00` | 0x30 | InputOutputControl |
| `30 30 07 00` | 0x30 | InputOutputControl |
| `3B 90` | 0x3B | WriteDataByLocalID (adaptation) |
| `14 00 00` | 0x14 | ClearDTCs |

**Live Data:** ReadLocalData (SID 0x21) block numbers for NAG1 722.6 to be determined by block scan. APK does NOT contain K-Line TCM live data blocks — it only has J1850 live data which doesn't work on 2.7 CRD.

---

## 4. ABS (Anti-lock Braking System) - J1850 VPW Init

**Bus:** J1850 VPW
**Address:** 0x40
**Init Sequence:**

```
ATSP2              -> Select J1850 VPW protocol
ATSH244022         -> ABS ReadDataByID header
ATRA40             -> Filter for ABS address responses
```

**No DiagSession needed** — ABS responds directly.

**Live Data (real device verified):**

```
20 PID 00          -> Read PID (e.g. "20 01 00" for wheel speed)
Response: 26 40 62 DATA
```

**ABS PIDs (verified):**

| PID | Response | Status |
|-----|----------|--------|
| `20 00` - `20 06` | `26 40 62 xx xx xx xx` | Data OK |
| `20 07` - `20 09` | `26 40 7F 22 12` | NRC: not supported |

**ABS Headers (from APK):**

| Header | SID | Description |
|--------|-----|-------------|
| `ATSH244011` | 0x11 | ECUReset |
| `ATSH244022` | 0x22 | ReadDataByID |
| `ATSH24402F` | 0x2F | IOControl |
| `ATSH2440B4` | 0xB4 | ReadMemoryByAddress |

---

## 5. Airbag/ORC (AOSIM) - J1850 VPW Init

**Bus:** J1850 VPW
**Address:** 0x60
**Init Sequence:**

```
ATSP2              -> Select J1850 VPW protocol
ATSH246022         -> Airbag ReadDataByID header
ATRA60             -> Listen for Airbag messages
```

**Real device test:** All PIDs return NRC (0x00-0x01: conditionsNotCorrect, 0x02+: subFuncNotSupported). May require ignition RUN or specific DiagSession.

---

## 6. Other J1850 Modules

| Module | Address | ATRA | Headers |
|--------|---------|------|---------|
| **Security/SKIM** | 0x62 | - | ATSH246211, 246222 |
| **HVAC/ATC** | 0x68 | - | ATSH246811, 246822, 246831, 246833 |
| **BCM** | 0x80 | ATRA80 | ATSH248022, 24802F, 2480B4 |
| **Radio** | 0x87 | - | ATSH248722, 24872F |
| **Instrument Cluster** | 0x90 | - | ATSH249011, 249022, 24902F |
| **Overhead Console** | 0x2A | - | ATSH242A22, 242A2F, 242AB7 |

---

## 7. J1850 VPW Command Format

| Module | Header | LocalID | Format | Example | Response |
|--------|--------|---------|--------|---------|----------|
| **ABS (0x40)** | ATSH244022 | 0x20 | `20 PID 00` | `20 01 00` | `26 40 62 xx` |
| **Airbag (0x60)** | ATSH246022 | 0x28 | `28 PID 00` | `28 00 00` | `26 60 7F 22 22` |

---

## 8. Bus Switching Strategy

### K-Line module switch (ECU ↔ TCM):
**MUST do full ATZ reinit** — just changing ATSH does not work!
```
ATZ              -> Full reset (clears previous module's session)
ATE1 → ATH1     -> Echo + Headers ON
ATWM81xxF13E     -> Wakeup for NEW target (xx = 0x15 or 0x20)
ATSH81xxF1       -> Header for NEW target
ATSP5            -> K-Line protocol
ATFI             -> Fast init (establishes session with new module)
81               -> StartCommunication
27 01 / 27 02    -> SecurityAccess (if needed)
```

### K-Line → J1850 switch:
```
ATZ → ATE1 → ATH1 → ATIFR0 → ATSP2 → ATSH24xxYY → ATRAxx
```

### J1850 → K-Line switch:
```
ATZ → ATE1 → ATH1 → ATWM → ATSH → ATSP5 → ATFI → 81 → 27
```

### J1850 same-bus module change:
```
ATSH24xxYY → ATRAxx (just header + filter change)
```

### ATFI Failure Recovery:
If ATFI fails, code automatically restores J1850 VPW with previous module header.

---

## 9. Timing (Real Device Verified)

| Parameter | Value |
|-----------|-------|
| **Inter-command delay** | 340ms |
| **ATZ response** | ~840ms |
| **ATFI response** | ~470ms |
| **K-Line data response** | ~280-400ms |
| **J1850 data response** | ~120-220ms |
| **NO DATA response** | ~140-350ms |

---

## 10. Real Device Test Results (2025-03-05)

**Setup:** iPhone 16 Pro + Viecar BLE (ELM327 v1.5) + Jeep WJ 2.7 CRD

| Module | Bus | Result |
|--------|-----|--------|
| **Engine ECU (0x15)** | K-Line | 21 12/28/20/22 OK, 21 62/B0-B2 NRC 0x33 |
| **TCM (0x20)** | K-Line | ATFI OK, 81 OK, seed OK — **TCM is alive!** |
| **TCM (0x28)** | J1850 | **NO RESPONSE** — not on J1850 for 2.7 CRD |
| **ABS (0x40)** | J1850 | PIDs 0x00-0x06 OK |
| **Airbag (0x60)** | J1850 | All NRC |
| **Battery** | ATRV | 14.3-14.5V |

**ECU data samples (engine idle):**
- Coolant: 24-66°C, IAT: 13-31°C, TPS: 0.0%
- RPM: 746-752, Injection Qty: 7.6-12.9 mg
- Rail Pressure: 280-306 bar, MAP: 907-928 mbar

**Pending:**
- TCM ReadLocalData block scan (21 01-21 FF) — first test used wrong init path, needs retest with full ATZ reinit
- TCM security key algorithm (seed-to-key for NAG1 722.6)
- TCM DTC format (NRC 0x79 on `18 02 FF 00` — may need different format or security)
