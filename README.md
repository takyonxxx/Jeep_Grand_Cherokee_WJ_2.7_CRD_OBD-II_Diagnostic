# Jeep Grand Cherokee WJ 2.7 CRD (2002-2004) — OBD-II Diagnostic Protocol Reference

## 1. Bus Architecture Overview

The WJ 2.7 CRD uses two diagnostic bus protocols accessible through the OBD-II DLC (Data Link Connector):

- **K-Line (ISO 14230-4 KWP2000)** — Used by Mercedes-origin ECUs (Engine, Cruise Control)
- **J1850 VPW (SAE J1850)** — Used by Chrysler body/chassis modules (Transmission, ABS, Airbag, BCM, etc.)

> **Note:** CAN bus exists as an internal powertrain network but is NOT accessible via OBD-II pins. All diagnostics go through K-Line or J1850 VPW.

---

## 2. Module Address Map

### 2.1 K-Line Modules (Protocol: ATSP5, ISO 14230-4 Fast Init)

| Address | ELM327 Header | ELM327 Wakeup | Module | Description |
|---------|---------------|---------------|--------|-------------|
| 0x15 | `ATSH8115F1` | `ATWM8115F13E` | **Engine ECU** | Bosch EDC15C2, OM612 2.7L 5-cyl diesel |
| 0x20 | `ATSH8120F1` | `ATWM8120F13E` | **EPC / CRD Cruise** | Electronic Pedal Control / Cruise Control |

K-Line header format: `81 <target> F1` (F1 = tester address)
Wakeup format: `81 <target> F1 3E` (TesterPresent)

### 2.2 J1850 VPW Modules (Protocol: ATSP2, SAE J1850 VPW)

| Address | Base Header | Module | DTC Read | Live Data | DTC Clear | Other |
|---------|-------------|--------|----------|-----------|-----------|-------|
| 0x28 | `ATSH2428xx` | **TCM** (NAG1 722.6 / EGS52) | xx11 | xx22 | xxB4 | xx2F (IO) |
| 0x2A | `ATSH242Axx` | **Transfer Case** (NV247) | xx11 | xx22 | — | — |
| 0x40 | `ATSH2440xx` | **ABS / ESP** (CAB) | xx11 | xx22 | xxB4 | xx2F (IO) |
| 0x60 | `ATSH2460xx` | **Airbag** (ORC) | xx11 | xx22 | xxB4 | xx27 (Sec), xx31 (Rtn), xxA0 (ID) |
| 0x62 | `ATSH2462xx` | **SKIM** (Immobilizer) | xx11 | xx22 | — | — |
| 0x68 | `ATSH2468xx` | **ATC** (Climate Control) | xx11 | xx22 | — | xx31, xx33 |
| 0x80 | `ATSH2480xx` | **BCM** (Body Controller) | xx11 | xx22 | xxB4 | xx2F (IO) |
| 0x87 | `ATSH2487xx` | **Compass / Mini-Trip** | — | xx22 | — | xx2F |
| 0x90 | `ATSH2490xx` | **Instrument Cluster** (MIC) | xx11 | xx22 | — | xx2F |
| 0x98 | `ATSH2498xx` | **Radio / Audio** | xx11 | xx22 | — | xx2F, xx30 |
| 0xA0 | `ATSH24A0xx` | **Overhead Console** (EVIC) | — | xx22 | — | xx2F, xx31, xx33 |
| 0xA1 | `ATSH24A1xx` | **Memory Module** | — | xx22 | — | xx2F, xx31, xx33 |
| 0xC0 | `ATSH24C0xx` | **Steering Column** | xx11 | xx22 | — | xx27, xx2F, xxB4 |

J1850 header format: `24 <target> <SID_byte>`  
The last byte of the 3-byte header selects the service:
- `11` = ReadDTCByStatus
- `22` = ReadDataByPID (live data)
- `2F` = IOControlByIdentifier
- `B4` = ClearDiagnosticInformation
- `27` = SecurityAccess
- `31` = StartRoutineByLocalID
- `A0` / `A3` = ReadECUIdentification

---

## 3. ELM327 Initialization Sequences

### 3.1 K-Line Init (Engine ECU / EPC)
```
ATZ                  ; Reset
ATE1                 ; Echo on
ATH1                 ; Headers on (optional, for debugging)
ATSP5                ; Protocol: ISO 14230-4 KWP fast init
ATFI                 ; Fast init (5-baud init fallback: ATSP3)
ATSH8115F1           ; Target: Engine ECU (0x15)
ATWM8115F13E         ; Wakeup message: TesterPresent
```

### 3.2 J1850 VPW Init (TCM, ABS, Airbag, BCM, etc.)
```
ATZ                  ; Reset
ATE1                 ; Echo on
ATSP2                ; Protocol: SAE J1850 VPW
ATSH242811           ; Target: TCM (0x28), SID: ReadDTC
```

### 3.3 Switching Between K-Line and J1850
```
; From K-Line to J1850:
ATSP2                ; Switch protocol
ATSH242811           ; Set J1850 header

; From J1850 to K-Line:
ATSP5                ; Switch protocol
ATFI                 ; Fast init
ATSH8115F1           ; Set K-Line header
ATWM8115F13E         ; Wakeup
```

### 3.4 Response Filtering (J1850)
```
ATRA40               ; Receive address filter: ABS (0x40)
ATRA60               ; Receive address filter: Airbag (0x60)
ATRA80               ; Receive address filter: BCM (0x80)
ATIFR0               ; IFR response handling
```

---

## 4. Engine ECU (0x15) — K-Line KWP2000

### 4.1 Supported KWP2000 Services

| SID | Command | Description |
|-----|---------|-------------|
| 0x10 | `10 xx` | StartDiagnosticSession |
| 0x14 | `14 00 00` | ClearDiagnosticInformation (all DTCs) |
| 0x18 | `18 02 FF 00` | ReadDTCByStatus (all DTCs, status mask 0xFF) |
| 0x18 | `18 02 00 00` | ReadDTCByStatus (stored DTCs) |
| 0x1A | `1A 86` | ReadECUIdentification — DCS/Variant ID |
| 0x1A | `1A 90` | ReadECUIdentification — VIN |
| 0x1A | `1A 91` | ReadECUIdentification — ECU HW/SW Number |
| 0x21 | `21 xx` | ReadDataByLocalIdentifier (live data blocks) |
| 0x27 | `27 01` | SecurityAccess — Request Seed |
| 0x27 | `27 02` | SecurityAccess — Send Key |
| 0x30 | `30 xx ...` | InputOutputControlByLocalIdentifier |
| 0x31 | `31 xx xx` | StartRoutineByLocalIdentifier |

### 4.2 Live Data Blocks (SID 0x21)

| Command | Block | Content | Response Size |
|---------|-------|---------|---------------|
| `21 12` | Misc Sensors | Coolant temp, IAT, TPS, MAP, AAP | 32+ data bytes |
| `21 20` | MAF | Mass Air Flow actual / specified | 30+ data bytes |
| `21 22` | Rail/MAP | Rail pressure specified, MAP specified | 32+ data bytes |
| `21 28` | RPM/IQ/Inj | RPM, injection qty, 5× injector corrections | 28+ data bytes |
| `21 62` | Extended | Additional sensor data (TBD) | Variable |
| `21 B0` | Adaptation 1 | Adaptation/learning values | Variable |
| `21 B1` | Adaptation 2 | Adaptation/learning values | Variable |
| `21 B2` | Adaptation 3 | Adaptation/learning values | Variable |

### 4.3 Block 0x12 Byte Map — Misc Sensors
Response format: `61 12 <data[0]> <data[1]> ... <data[31]>`

| Byte Offset | Size | Formula | Parameter | Unit |
|-------------|------|---------|-----------|------|
| 2–3 | uint16 | raw / 10.0 − 273.1 | Coolant Temperature | °C |
| 4–5 | uint16 | raw / 10.0 − 273.1 | Intake Air Temperature | °C |
| 16–17 | uint16 | raw / 19.53 | Throttle Position | % |
| 18–19 | uint16 | raw × 1.0 | MAP Actual | mbar |
| 30–31 | uint16 | raw × 1.0 | Atmospheric Pressure (AAP) | mbar |

### 4.4 Block 0x28 Byte Map — RPM / Injection / Injector Corrections
Response format: `61 28 <data[0]> <data[1]> ... <data[27]>`

| Byte Offset | Size | Formula | Parameter | Unit |
|-------------|------|---------|-----------|------|
| 2–3 | uint16 | raw × 1.0 | Engine RPM | rpm |
| 4–5 | uint16 | raw / 100.0 | Injection Quantity | mg/str |
| 18–19 | int16 | raw / 100.0 | Injector Correction Cyl 1 | mg |
| 20–21 | int16 | raw / 100.0 | Injector Correction Cyl 2 | mg |
| 22–23 | int16 | raw / 100.0 | Injector Correction Cyl 3 | mg |
| 24–25 | int16 | raw / 100.0 | Injector Correction Cyl 4 | mg |
| 26–27 | int16 | raw / 100.0 | Injector Correction Cyl 5 | mg |

### 4.5 Block 0x20 Byte Map — MAF
Response format: `61 20 <data[0]> ... <data[29]>`

| Byte Offset | Size | Formula | Parameter | Unit |
|-------------|------|---------|-----------|------|
| 14–15 | uint16 | raw × 1.0 | MAF Actual | mg/str |
| 16–17 | uint16 | raw × 1.0 | MAF Specified | mg/str |

### 4.6 Block 0x22 Byte Map — Rail Pressure / MAP Spec
Response format: `61 22 <data[0]> ... <data[31]>`

| Byte Offset | Size | Formula | Parameter | Unit |
|-------------|------|---------|-----------|------|
| 16–17 | uint16 | raw × 1.0 | MAP Specified | mbar |
| 18–19 | uint16 | raw / 10.0 | Rail Pressure Specified | bar |

### 4.7 Engine ECU Live Data Parameters (Display Names)

- Engine RPM
- Coolant Temp / Coolant Sensor Voltage
- Air Intake Temp / Air Intake Volts
- Boost Pressure Sensor / Boost Pressure Setpoint / Boost Pressure Voltage
- Fuel Rail Pressure Sensor, Actual
- Fuel Pressure Setpoint / Fuel Pressure Volts / Fuel Pressure Regulator Output
- Actual Fuel Quantity (Mg/Str)
- Desired Fuel QTY Demand / Driver / Pedal / Cruise
- Fuel QTY Limit / Fuel QTY Low-Idle Gov / Fuel QTY Start Setpoint / Fuel QTY Torque
- Accelerator Pedal Position Sensor 1 / Sensor 2 (+ Voltage)
- EGR Duty Cycle / EGR op Phase
- MAF for EGR Setpoint / Mass Air Flow / Mass Air Flow Voltage
- Barometric Pressure / Barometer Pressure Voltage
- Battery Voltage / Battery Temp / Battery Temp Voltage
- Calculated Injector Voltage / Injector Bank 1 Capacitor
- Oil Pressure Sensor / Oil Pressure Voltage
- Camshaft/crankshaft Synchronization
- Vehicle Speed / Vehicle Speed Setpoint
- Swirl Solenoid / Wastegate Solenoid
- Hydraulic Rad Fan
- Glow Plug Relay 1 / Glow Plug Relay 2 / Glow Plug Display
- Water in Fuel
- Start op Phase / Boost op Phase / Afterrun op Phase
- Steering Control op Phase / Steering Control On/Off/Set/Coast/Resume/Cancel/Cutout

### 4.8 I/O Control (SID 0x30) Commands

| Command | LocalID | Description | Value Range |
|---------|---------|-------------|-------------|
| `30 10 07 xx xx` | 0x10 | I/O control 1 | 0x0000–0x0400 |
| `30 11 07 xx xx` | 0x11 | I/O control 2 | 0–5000 |
| `30 12 07 xx xx` | 0x12 | I/O control 3 | 0–16 |
| `30 14 07 xx xx` | 0x14 | I/O control 4 | 0–10000 |
| `30 16 07 xx xx` | 0x16 | I/O control 5 | 0–10000 |
| `30 17 07 xx xx` | 0x17 | I/O control 6 | 0–10000 |
| `30 18 07 xx xx` | 0x18 | RPM control (likely) | 2100–8500 |
| `30 1A 07 xx xx` | 0x1A | I/O control 8 | 0–5000 |
| `30 1C 07 xx xx` | 0x1C | I/O control 9 | 0–10000 |
| `30 30 07 00` | 0x30 | Return to normal | — |
| `30 3A 01` | 0x3A | ReturnControlToECU | — |
| `30 3A 08` | 0x3A | FreezeCurrentState | — |

Control option byte `07` = shortTermAdjustment. Value bytes are uint16 big-endian.

### 4.9 Routine Control (SID 0x31) Commands

| Command | Description |
|---------|-------------|
| `31 25 00` | Start routine 0x25 (injector test) |
| `31 31` | Start routine 0x31 |
| `31 32` | Start routine 0x32 |

---

## 5. NAG1 722.6 Transmission (0x28) — J1850 VPW

### 5.1 Header Variants

| Header | Purpose |
|--------|---------|
| `ATSH242810` | DiagnosticSession / DTC operations |
| `ATSH242811` | ReadDTCByStatus |
| `ATSH242814` | ClearDTC |
| `ATSH242820` | RequestDownload (special) |
| `ATSH242822` | ReadDataByPID (live data) |
| `ATSH242830` | IOControl / RoutineControl |
| `ATSH2428A0` | ReadECUIdentification |
| `ATSH2428A3` | ReadECUIdentification (variant) |

### 5.2 TCM Live Data Parameters (J1850 VPW PID Table)

Read via `ATSH242822` header, command `22 XX`, response `62 XX <data>`.

| PID | Parameter | Unit | Bytes | Formula |
|-----|-----------|------|-------|---------|
| 0x01 | Actual Gear | - | 1 | raw (0=P,1=R,2=N,3-7=D1-D5) |
| 0x02 | Selected Gear | - | 1 | raw |
| 0x03 | Max Gear | - | 1 | raw |
| 0x04 | Shift Selector Position | - | 1 | raw |
| 0x10 | Turbine RPM | rpm | 2 | (HH<<8)\|LL |
| 0x11 | Input RPM (N2) | rpm | 2 | (HH<<8)\|LL |
| 0x12 | Input RPM (N3) | rpm | 2 | (HH<<8)\|LL |
| 0x13 | Output RPM | rpm | 2 | (HH<<8)\|LL |
| 0x14 | Transmission Temp | °C | 1 | raw - 40 |
| 0x15 | TCC Pressure | PSI | 1 | raw * 0.1 |
| 0x16 | Solenoid Supply | V | 1 | raw * 0.1 |
| 0x17 | TCC Clutch State | - | 1 | 0=off,1=partial,2=locked |
| 0x18 | Actual TCC Slip | rpm | 2 | signed int16 |
| 0x19 | Desired TCC Slip | rpm | 2 | signed int16 |
| 0x1A | Act 1245 Solenoid | % | 1 | raw * 0.39 |
| 0x1B | Set 1245 Solenoid | % | 1 | raw * 0.39 |
| 0x1C | Act 2-3 Solenoid | % | 1 | raw * 0.39 |
| 0x1D | Set 2-3 Solenoid | % | 1 | raw * 0.39 |
| 0x1E | Act 3-4 Solenoid | % | 1 | raw * 0.39 |
| 0x1F | Set 3-4 Solenoid | % | 1 | raw * 0.39 |
| 0x20 | Vehicle Speed | km/h | 2 | (HH<<8)\|LL |
| 0x21 | Front Vehicle Speed | km/h | 2 | (HH<<8)\|LL |
| 0x22 | Rear Vehicle Speed | km/h | 2 | (HH<<8)\|LL |
| 0x23 | Shift PSI | PSI | 2 | (HH<<8)\|LL * 0.1 |
| 0x24 | Modulation PSI | PSI | 2 | (HH<<8)\|LL * 0.1 |
| 0x25 | Park Lockout Solenoid | - | 1 | 0=off,1=on |
| 0x26 | Park/Neutral Switch | - | 1 | 0=off,1=on |
| 0x27 | Brake Light Switch | - | 1 | 0=off,1=on |
| 0x28 | Primary Brake Switch | - | 1 | 0=off,1=on |
| 0x29 | Secondary Brake Switch | - | 1 | 0=off,1=on |
| 0x2A | Kickdown Switch | - | 1 | 0=off,1=on |
| 0x2B | Fuel QTY Torque | % | 1 | raw * 0.39 |
| 0x2C | Swirl Solenoid | - | 1 | 0=off,1=on |
| 0x2D | Wastegate Solenoid | % | 1 | raw * 0.39 |
| 0x30 | Calculated Gear | - | 1 | raw |

#### 5.2.1 Freeze Frame Data (DTC ile birlikte kayıt)

| Field | Description |
|-------|-------------|
| AG | Actual Gear at fault |
| CG | Calculated Gear at fault |
| TG | Target Gear at fault |
| Battery | Battery voltage (V) |
| Km | Odometer (km) |
| RPM | Engine RPM |
| RpmTurb | Turbine RPM |
| SLP | Selector Lever Position |
| PIS | Pressure Switch Input State |

### 5.3 NAG1 TCM Fault Code Table (Mercedes ID Format)

| ID | Description |
|----|-------------|
| 02 | Solenoid valve, gearbox shift 1-2 or 4-5 is faulty |
| 03 | Solenoid valve, gearbox shift 2-3 is faulty |
| 04 | Solenoid valve, gearbox shift 3-4 is faulty |
| 05 | Torque Converter lockup PWM solenoid valve is faulty |
| 06 | Modulating pressure control solenoid valve is faulty |
| 07 | Shift pressure control solenoid valve is faulty |
| 08 | Park lockout solenoid valve is faulty |
| 09 | Park/Neutral output circuit |
| 10 | Solenoid valve: power supply — Value/signal outside range |
| 11 | Sensor supply Voltage |
| 12 | Transmission speed sensor 2 defective circuit / open circuit / short circuit |
| 13 | Transmission speed sensor 3 defective circuit / open circuit / short circuit |
| 14 | Difference between transmission input and output speed sensors |
| 15 | Input Sensor Overspeed |
| 17 | Shifter signal invalid |
| 18 | Shifter signal missing |
| 19 | System Overvoltage |
| 20 | Transmission Temp sensor Shorted |
| 21 | System Undervoltage |
| 22 | Rear right wheel speed not plausible |
| 23 | Rear left wheel speed not plausible |
| 24 | Front right wheel speed not plausible |
| 25 | Front left wheel speed not plausible |
| 26 | Engine APP TPS message |
| 27 | Engine torque Message Incorrect |
| 28 | Engine RPM message |
| 29 | Engine torque Message Incorrect |
| 31 | Engine torque Message Incorrect |
| 32 | Engine torque Message Incorrect |
| 33 | ABS Brake message |
| 35 | CAN signal from Engine Control Unit faulty |
| 36 | CAN signal from Engine Control Unit faulty |
| 37 | CAN communication is faulty |
| 38 | ABS CAN messages missing |
| 39 | CAN communication with the Engine Control Unit not plausible |
| 43 | Engine Temp message |
| 44 | Engine T-Case switch Message |
| 46–48 | Internal Controller |
| 49 | Engine Overspeed |
| 50 | Improper transmission gear ratio |
| 51 | Transmission slipping |
| 52 | TCC Stuck On |
| 53 | TCC Over Temp |
| 54 | Engine Torque Reduction |
| 55 | Improper Gear |
| 56–69 | Internal Controller |
| 71 | Solenoid valve, gearbox shift 1-2 or 4-5 is faulty |
| 72 | Solenoid valve, gearbox shift 2-3 is faulty |
| 73 | Solenoid valve gearbox shift 3-4 is faulty |
| 74 | Park/Neutral switch circuit or Transmission oil temperature sensor signal improbable |
| 75 | Transmission oil temperature sensor erratic |
| 76 | Internal Shifter failure |
| 81 | ABS CAN messages incorrect |
| 82–83 | CAN signal from Engine Control Unit faulty |
| 85 | Internal Controller |

### 5.4 TCM DTC Freeze Frame Data

Each stored DTC includes freeze frame data with:
- Actual Gear (AG)
- Calculated Gear (CG)
- Target Gear (TG)
- Battery Voltage
- Kilometres (odometer at time of fault)
- RPM
- Turbine RPM
- SLP (Selector Lever Position)
- PIS

---

## 6. ABS / ESP Module (0x40) — J1850 VPW

### 6.1 Header Variants

| Header | Purpose |
|--------|---------|
| `ATSH244011` | DTC Read |
| `ATSH244022` | Live Data (ReadDataByPID) |
| `ATSH24402F` | I/O Control |
| `ATSH2440B4` | DTC Clear |

### 6.2 ABS Variants Supported
- C1/LH ABS Only
- C3/JR ABS Only
- RS/RG ABS w/Traction Control

### 6.3 ABS Live Data Parameters (J1850 VPW PID Table)

Read via `ATSH244022` header, command `22 XX`, response `62 XX <data>`.

| PID | Parameter | Unit | Bytes | Formula |
|-----|-----------|------|-------|---------|
| 0x01 | LF Wheel Speed | km/h | 2 | (HH<<8)\|LL |
| 0x02 | RF Wheel Speed | km/h | 2 | (HH<<8)\|LL |
| 0x03 | LR Wheel Speed | km/h | 2 | (HH<<8)\|LL |
| 0x04 | RR Wheel Speed | km/h | 2 | (HH<<8)\|LL |
| 0x10 | Vehicle Speed | km/h | 2 | (HH<<8)\|LL |
| 0x20 | Brake Light Switch | - | 1 | 0=off,1=on |
| 0x21 | ABS Active | - | 1 | 0=inactive,1=active |
| 0x22 | Park Brake | - | 1 | 0=off,1=on |
| 0x23 | Traction Control Active | - | 1 | 0=off,1=on |

### 6.4 ABS Fault Code Descriptions

| Description |
|-------------|
| Left Front Sensor Circuit Failure |
| Left Front Wheel Speed Signal Failure |
| Right Front Sensor Circuit Failure |
| Right Front Wheel Speed Signal Failure |
| Left Rear Sensor Circuit Failure |
| Left Rear Wheel Speed Signal Failure |
| Right Rear Sensor Circuit Failure |
| Right Rear Wheel Speed Signal Failure |
| Valve Power Feed Failure |
| Pump Circuit Failure |
| CAB Internal Failure |
| ABS Lamp Circuit Short |
| ABS Lamp Open |
| Brake Lamp Circuit Short |
| Brake Lamp Open |
| Brake Fluid Level Switch |
| G-Switch / Sensor Failure |
| ABS Messages Not Received |
| No BCM Park Brake Messages Received |
| Internal Controller Error |
| Sensor 1–4 Failure |
| Sensor 1–4 Ground Circuit Open |
| Sensor 1–4 Signal Circuit Short to Battery |
| Sensor 1–4 Signal or Battery Circuit Open or Short to Ground |
| Vehicle Speed Failure |

---

## 7. Airbag / ORC Module (0x60) — J1850 VPW

### 7.1 Header Variants

| Header | Purpose |
|--------|---------|
| `ATSH246011` | DTC Read |
| `ATSH246022` | Live Data |
| `ATSH246027` | Security Access |
| `ATSH246031` | Start Routine |
| `ATSH2460A0` | Read ECU Identification |
| `ATSH2460A3` | Read ECU Identification (variant) |
| `ATSH2460B4` | DTC Clear |

### 7.2 Airbag Live Data Parameters

Read via `ATSH246022` header, command `22 XX`, response `62 XX <data>`.

| PID | Parameter | Bytes |
|-----|-----------|-------|
| 0x01 | Airbag Lamp Status | 1 |
| 0x02 | Fault Count | 1 |
| 0x10 | Driver Squib 1 Resistance | 1 |
| 0x11 | Driver Squib 2 Resistance | 1 |
| 0x12 | Passenger Squib 1 Resistance | 1 |
| 0x13 | Passenger Squib 2 Resistance | 1 |
| 0x14 | Driver Curtain Resistance | 1 |
| 0x15 | Passenger Curtain Resistance | 1 |
| 0x20 | Seat Belt Driver | 1 |
| 0x21 | Seat Belt Passenger | 1 |

### 7.3 Airbag Fault Code Descriptions

| Description |
|-------------|
| Airbag Lamp Driver Failure |
| Airbag Lamp Open |
| Driver SQUIB 1 Circuit Open |
| Driver SQUIB 1 Circuit Short |
| Driver SQUIB 1 Short To Battery |
| Driver SQUIB 1 Short To Ground |
| Driver Squib 2 Circuit Open |
| Driver SQUIB 2 Circuit Short |
| Driver SQUIB 2 Short To Battery |
| Driver SQUIB 2 Short To Ground |
| Passenger SQUIB 1 Circuit Open |
| Passenger SQUIB 1 Circuit Short |
| Passenger SQUIB 1 Short To Battery |
| Passenger SQUIB 1 Short To Ground |
| Passenger SQUIB 2 Circuit Open |
| Passenger SQUIB 2 Circuit Short |
| Passenger SQUIB 2 Short To Battery |
| Passenger SQUIB 2 Short To Ground |
| Driver Curtain SQUIB Circuit Open |
| Driver Curtain SQUIB Short To Battery |
| Driver Curtain SQUIB Short To Ground |
| Passenger Curtain SQUIB Circuit Open |
| Passenger Curtain SQUIB Circuit Short |
| Passenger Curtain SQUIB Short To Battery |
| Passenger Curtain SQUIB Short To Ground |
| Driver Side Impact Sensor Internal 1 |
| No Driver Side Impact Sensor Communication |
| Passenger Side Impact Sensor Internal 1 |
| No Passenger Side Impact Sensor Communication |
| Left Front Impact Sensor Internal 1 |
| No Left Front Impact Sensor Communication |
| Right Front Impact Sensor Internal 1 |
| No Right Front Impact Sensor Communication |
| Driver Seat Belt Switch Circuit Open |
| Driver Seat Belt Switch Shorted To Battery |
| Driver Seat Belt Switch Shorted To Ground |
| Passenger Seat Belt Switch Circuit Open |
| Passenger Seat Belt Switch Shorted To Battery |
| Passenger Seat Belt Switch Shorted To Ground |
| ACM Messages Not Received |
| Stored Energy Firing 1 |
| Interrogate AOSIM |
| AOSIM Driver Off Indicator Failure |
| AOSIM Passenger Off Indicator Failure |
| Module Not Configured For AOSIM |
| No AOSIM Message |

---

## 8. BCM — Body Controller Module (0x80) — J1850 VPW

### 8.1 Header Variants

| Header | Purpose |
|--------|---------|
| `ATSH248011` | DTC Read |
| `ATSH248022` | Live Data (ReadDataByPID) |
| `ATSH24802F` | I/O Control |
| `ATSH2480B4` | DTC Clear |

### 8.2 BCM Live Data Parameters

- Battery IOD Voltage / Ignition Voltage / Ignition Volts / Ignition Status
- Fuel Level / Fuel Level Sensor Voltage
- Driver Door Ajar Switch / Passenger Door Ajar Switch / LR Door Ajar Switch / RR Door Ajar Switch / Driver Rear Door Ajar Switch / Passenger Rear Door Ajar Switch
- Driver Front Window Current / Passenger Front Window Current / Driver Rear Window Current / Passenger Rear Window Current
- Driver Door Mirror Horizontal Voltage / Driver Door Mirror Vertical Voltage
- Passenger Door Mirror Horizontal Voltage / Passenger Door Mirror Vertical Voltage
- Key In Ignition Switch / Driver key Cylinder Switch Voltage
- Headlamp Switch / High Beam Relay / High Beam Sense / Auto Headlamp Sense / Fog Lamp Switch
- Wiper Mode Switch Voltage / Wiper HI Sel / Wiper PK Switch / Washer Switch
- Alternator Duty Cycle / Alternator Field Current
- Coolant Level Switch
- Park Brake / Reverse Input / Starter Interlock
- Rolling Counter / R Mux Status / R Mux Volts
- Radio Control Switch / Radio Mute
- Cruise Switch Voltage
- Display Volts
- LED Feedback
- Reference Voltage

### 8.3 BCM Fault Code Descriptions

| Description |
|-------------|
| BCM Eeprom Checksum Failure |
| BCM Flash Checksum Failure |
| BCM Messages Not Received |
| BCM Messages Not Received by MIC |
| Battery IOD Disconnect at BCM |
| Accessory Delay Relay Shorted Hi |
| Low Beam Relay Ckt Lo/Open |
| Low Beam Relay Ckt Shorted Hi |
| Hi Beam Relay Ckt Shorted Hi |
| Park Lamp Relay Ckt Lo/Open |
| Park Lamp Relay Shorted Hi |
| Fog Lamp Relay Ckt Open |
| Fog lamp relay ckt shorted hi |
| Hazard relay ckt shorted hi |
| Horn Relay Ckt Shorted Hi |
| Rear Defog Relay Open |
| Rear Defog Relay Shorted Hi |
| Rear Fog Lamp Relay Ckt Open |
| Rear Fog Relay Output Shorted Hi |
| Wiper On/Off Relay Output Short High |
| Wiper On/Off Relay Output Short Low/Open |
| Wiper Hi/Low Relay Output Open |
| Wiper Hi/Low Relay Output Shorted High |
| Wiper Park Switch Failure |
| Wiper Sw Mux Ckt Open |
| Wiper Sw Mux Ckt Short To Ground |
| Head Lamp Sw Open Ckt |
| Headlamp Sw Short To Ground |
| Dim Sw Open Ckt |
| Dim Sw Short To Ground |
| Remote Radio Sw Short To Ground |
| Lamp Fade Failure Short To Batt |
| Load Shed Failure Short To Batt |
| Panel Lamp Driver Failure |
| Rain Sensor Fault |
| Rain Sensor Messages Not Received |
| Washer Fluid Sensor Failure |
| Loss Of Ignition / Run Only |
| Loss Of Ignition / Run-Start |
| All Outputs Short |
| VIN Mismatch |
| No PCI BUS Transmission |
| No PCI Bus Communication |
| PCI BUS Internal Fault |
| PCI BUS Short To Battery |
| PCI BUS Short To Ground |
| No Bus Messages Received From PCM |
| No Bus Messages Received From BCM |

---

## 9. SKIM — Immobilizer (0x62) — J1850 VPW

### 9.1 Header Variants

| Header | Purpose |
|--------|---------|
| `ATSH246211` | DTC Read |
| `ATSH246222` | Live Data |

### 9.2 SKIM Live Data Parameters

- Keys Programmed
- Key In Ignition Switch

### 9.3 SKIM Fault Code Descriptions

| Description |
|-------------|
| Internal SKIM Failure |
| SKIM Messages Not Received |
| Code Word Incorrect or Missing |
| SKIM Error |
| Write Access to EEPROM Failure |
| Invalid Secret Key in EEPROM |
| Key Communication Timed Out |
| Invalid Key Code Received |
| Transponder Communication Failure |
| Transponder CRC Failure |
| Transponder ID Mismatch |
| Transponder Response Mismatch |
| Rolling Code Failure |

---

## 10. Climate Control / ATC (0x68) — J1850 VPW

### 10.1 Header Variants

| Header | Purpose |
|--------|---------|
| `ATSH246811` | DTC Read |
| `ATSH246822` | Live Data |
| `ATSH246831` | Start Routine |
| `ATSH246833` | Routine Result |

### 10.2 ATC Live Data Parameters

- Outside Air Temperature / Outside Temp Voltage
- AC System Pressure / AC System Pressure Voltage
- EVAP Temp Voltage
- A/C op Phase / Afterrun op Phase
- AC Control Relay
- Cabin/Viscous Relay 1
- Battery Temp / Battery Temp Voltage

### 10.3 ATC Fault Code Descriptions

| Description |
|-------------|
| Ambient Air Temperature Failure |
| Ambient Temperature Sensor Ckt Open |
| Ambient Temperature Sensor Short To Ground |
| Evap Temp Sensor Open |
| Evap Temp Sensor Shorted |
| Blower Select Switch Open |
| Blower Select Switch Shorted |
| Mode Select Switch Open |
| Mode Select Switch Shorted |
| Driver Blend Door Range Too Large |
| Driver Blend Door Range Too Small |
| Driver Blend door Not Responding |
| Passenger Blend Door Range Too Large |
| Passenger Blend Door Range Too Small |
| Passenger Blend Door Not Responding |
| Mode Door Range Too Large |
| Mode Door Range Too Small |
| Mode Motor Not Responding |
| Recirculation Door Range Too Large |
| Recirculation Door Range Too Small |
| Recirculation Motor Not Responding |
| Sensor Voltage Supply Short To Ground |
| Display Voltage Supply Short To Ground |
| No Communication with BCM |

---

## 11. Instrument Cluster / MIC (0x90) — J1850 VPW

### 11.1 Header Variants

| Header | Purpose |
|--------|---------|
| `ATSH249011` | DTC Read |
| `ATSH249022` | Live Data |
| `ATSH24902F` | I/O Control |

### 11.2 Cluster Live Data Parameters

- Display Volts
- Fuel Level / Fuel Level Sensor Voltage
- Vehicle Speed
- Mileage (Odometer)

### 11.3 Cluster Fault Code Descriptions

| Description |
|-------------|
| Cluster Lamp Failure |
| Cluster Message Mismatch |
| PCM Messages Not Received |
| PCM Messages Not Received by MIC |
| BCM Messages Not Received by MIC |
| TCM Messages Not Received |
| No TCM Messages Received |
| No PCM Messages Received |
| SKIM Messages Not Received |
| Module Calibration Mismatch |
| Module Software Mismatch |
| VIN Mismatch |
| Vehicle Speed Failure |

---

## 12. Radio / Audio (0x98) — J1850 VPW

### 12.1 Header Variants

| Header | Purpose |
|--------|---------|
| `ATSH249811` | DTC Read |
| `ATSH249822` | Live Data |
| `ATSH24982F` | I/O Control |
| `ATSH249830` | Routine / Config |

### 12.2 Radio Fault Code Descriptions

| Description |
|-------------|
| Antenna Failure |
| Antenna Hardware Failure |
| Antenna Not Connected |
| Antenna is not Connected |
| Power Amplifier Shutdown |
| Cassette Player Inoperative |
| CD Mechanical Failure |
| CD Read Failure |
| CD Temperature High |
| CD Changer Mechanical Failure |
| CD Changer Play Failure |
| CD Changer Read Failure |
| CD Changer Temperature High |
| CD Changer Temperature Low |
| CD Changer Low Voltage Level |
| Improper Disc In CD Changer |
| No Communication with Amplifier |
| No Communication with CD/DVD |
| No Communication with NAV |
| No Communication with SDARS |
| No Communication with Radio |
| Internal Receiver Failure |
| Internal SDARS Failure |
| Internal NAV Module Failure |
| Radio nad NAV GPS Antenna is Not Connected |
| GPS Antenna in Not Connected |
| Radio Dimming Shorted Hi |
| Rear Display Communication Fault |
| Rear Display LED or Speaker Fault |
| Rear Transmitter Failure |
| Optical Fault Detected |
| AMP Messages Not Received |

---

## 13. Overhead Console / EVIC (0xA0) — J1850 VPW

### 13.1 Header Variants

| Header | Purpose |
|--------|---------|
| `ATSH24A022` | Live Data |
| `ATSH24A02F` | I/O Control |

### 13.2 EVIC Live Data Parameters

- Outside Air Temperature
- Compass heading
- Trip data

### 13.3 EVIC / Overhead Fault Codes

| Description |
|-------------|
| Compass Test Failure |
| Evic Internal Failure |

---

## 14. Additional Modules

### 14.1 Transfer Case (0x2A)
Headers: `ATSH242A22` (read), `ATSH242A2F` (IO), `ATSH242AB7` (variant)

Live Data:
- Transfer Case Position Sensor Voltage
- Transfer Case Switch

### 14.2 Compass / Mini-Trip (0x87)
Headers: `ATSH248722` (read), `ATSH24872F` (IO)

### 14.3 Memory Module (0xA1)
Headers: `ATSH24A122`, `ATSH24A12F`, `ATSH24A131`, `ATSH24A133`

### 14.4 Steering Column (0xC0)
Headers: `ATSH24C011`, `ATSH24C022`, `ATSH24C027`, `ATSH24C02F`, `ATSH24C0B4`

---

## 15. TPMS (Tire Pressure Monitoring) Data

Available via Overhead Console module:

- LF Wheel Sensor / LF Wheel Sensor ID / LF Wheel Sensor Status
- RF Wheel Sensor / RF Wheel Sensor ID / RF Wheel Sensor Status
- LR Wheel Sensor / LR Wheel Sensor ID / LR Wheel Sensor Status
- RR Wheel Sensor / RR Wheel Sensor ID / RR Wheel Sensor Status
- Spare Wheel Sensor / Spare Wheel Sensor ID / Spare Wheel Sensor Status
- Spare Size: Full / Mini / 4 Sensor

---

## 16. Parking Assist Module (PAM) Data

- Sensor 1 / Sensor 1 Distance
- Sensor 2 / Sensor 2 Distance
- Sensor 3 / Sensor 3 Distance
- Sensor 4 / Sensor 4 Distance
- Sensor 5–9
- Sensor Volts
- Sensor Supply
- Obstacle
- Allow Threshold / Inhibit Threshold
- Volts Range

---

## 17. Country / Market Codes

Supported market configurations:
USA, Canada, Europe, Germany, United Kingdom, Australia, Japan, Malaysia, Indonesia, Mexico, Venezuela, Gulf coast, Rest Of World

---

## 18. Odometer Mileage Correction

The instrument cluster supports odometer programming via diagnostic commands. This function requires a reliable ELM327 adapter. Counterfeit/clone ELM327 devices may cause damage to the odometer EEPROM during this operation.

Commands: `30 10 07 xx xx` via Cluster module (ATSH249022 / ATSH24902F).

---

## 19. Security Access (SID 0x27)

Security access is supported by:
- Engine ECU (0x15): `27 01` (seed) / `27 02` (key) — required for injector coding
- Airbag (0x60): `ATSH246027` — required for deployment counter reset
- Steering Column (0xC0): `ATSH24C027`

---

## 20. Communication Error Codes (Bus-Level)

| Message | Description |
|---------|-------------|
| No J1850 Communication | J1850 VPW bus not responding |
| BUS System Communication | General bus error |
| Bus Busy | Bus arbitration failure |
| Bus Messages Missing | Expected messages not received |
| No PCI BUS Transmission | PCI (J1850) transmit failure |
| PCI BUS Shorted To Battery | Bus hardware short |
| PCI BUS Shorted To Ground | Bus hardware short |
| Serial Link External Failure | External serial communication error |
| Serial Link Internal Failure | Internal serial communication error |
| Lost Communication With PCI | Complete bus loss |
| Loss of Communication on Private Bus | Private bus (internal) failure |
