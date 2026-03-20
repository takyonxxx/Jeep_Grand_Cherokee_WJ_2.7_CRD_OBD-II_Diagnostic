# WJDiag — Jeep Grand Cherokee WJ 2.7 CRD Diagnostic Tool

## Vehicle: 2003 EU-spec WJ 2.7 CRD (OM612 / NAG1)

Qt6 cross-platform diagnostic application + native iOS (Swift/SwiftUI) port + ESP32-S2 ELM327 emulator.
All commands and responses verified on real vehicle via BLE full block dumps and bus capture analysis.

## iOS / Xcode Version (Swift/SwiftUI)

Native iOS port targeting iPhone (iOS 17+). Source code: `xcode/JeepWJDiag/`

### Screenshots

| ECU Live Data | TCM Live Data |
|:---:|:---:|
| ![ECU Dashboard](xcode/ecu_live.png) | ![TCM Dashboard](xcode/tcm_live.png) |

### Features
- **5 tabs**: Conn (connection + dashboard + module list), DTC, Ctrl (quick controls), Acts (actuators), Log
- **ECU Dashboard**: Big FUEL center (L/h stopped, L/100km driving + fuel level liters), SPEED, RPM, RAIL, BOOST, M-TEMP, MAF, BATT
- **TCM Dashboard**: Big GEAR center (D1-D5 green, P/N/R amber, LIMP red), SPEED, TURBIN, T-TEMP, LIMP, LINE-P, TCC, SOL V, BATT
- **Actuator controls**: Hold-to-activate buttons with green highlight for all modules
- **Quick Controls tab**: Driver Door / Passenger Door / BCM quick-access grid
- **BLE auto-connect**: Background scan with OBD device filter list
- **Manual Start/Stop Live Data**: Live data does not auto-start — allows actuator use first
- **Launch screen**: Composite splash image with JeepWjDiag title + Jeep photo

---

## Protocol & Init Sequences (Verified)

### J1850 VPW Init
```
ATZ → ATZ → ATSP2 → ATIFR0 → ATH1 → ATSH24xx22 → ATRAxx
```
Double ATZ for clone ELM327 reliability. ATE1 not sent (echo stays on from ATZ default).
ATH1 comes AFTER ATSP2/ATIFR0, not before.

### K-Line ECU Init (0x15)
```
ATZ → ATE1 → ATH1 → ATWM8115F13E → ATSH8115F1 → ATSP5 → ATFI → 81 → 27 01/02
```
ATFI sends two-part response: `BUS INIT:\r` + 200ms delay + `OK\r\r>`.

### K-Line TCM Init (0x20)
```
ATZ → ATE1 → ATH1 → ATWM8120F13E → ATWM8120F13E → ATSH8120F1 → ATSP5 → ATFI → 81 → 27 01/02
```
Double ATWM for TCM reliability. First `81` can also trigger `BUS INIT: OK` on ELM327
(alternative to ATFI for bus initialization).

### Keepalive
SID `81` (StartCommunication) is used as K-Line keepalive, NOT `3E` (TesterPresent).
ECU responds with `C1 EF 8F` each time.

### ECU Security — Seed=0x0000 Handling
When ECU is already unlocked, it returns seed `67 01 00 00`. This means security is inactive.
Key `9C C9` (ArvutaKoodi with seed=0) is accepted by the ECU.
Blocks 0x62/0xB0/0xB1/0xB2 are readable without explicit security unlock when seed=0.

## Complete Module Address Map (Verified)

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

## Dashboard Gauges (Verified on Real Vehicle)

### ECU Dashboard

| Gauge | Block | Offset | Formula | Verified Value | Notes |
|-------|-------|--------|---------|---------------|-------|
| SPEED | 0x26 | data[2-3] | **raw / 100 = km/h** | 0-80+ | verified: 10000→100km/h |
| RPM | 0x28 (0x12 fallback) | data[0-1] | raw | 750 | per-cyl RPMs at [4-13] |
| FUEL L/h | calculated | rpm × fuelActual | L/h or L/100km | 1.2 | — |
| FUEL LEVEL | 0x21 | data[14-15] | **raw / 10 = %** | 49.5% = 39.0L | 78.7L tank |
| FUEL SENS V | 0x21 | data[16-17] | **raw / 100 = V** | 1.80V | — |
| INJ-Q | 0x32 (0x28 alt) | data[0-1] | /100 = mg/str | 8.81 | 0x28[2-3] for actual |
| M-TEMP | 0x22 | data[0-1] | /10 - 273.1 = °C | 57.8°C | — |
| BOOST | 0x22 | data[14-15] | /1000 = Bar | 0.910 | — |
| RAIL | 0x12 | data[18-19] | **×0.101 = Bar** | 245.5 | constant 0.101 |
| MAF | 0x36 | data[6-7] | /10 = Mg/Str | 473 | — |
| BATT | 0x16 | data[2-3] | **×5/3072 = V** | 13.85 | — |

### TCM Dashboard

| Gauge | Block | Offset | Formula | Verified Value |
|-------|-------|--------|---------|---------------|
| SPEED | 0x32 | data[0] | **single byte km/h** | 0-31+ |
| GEAR | 0x30 | data[9] | 0=P, 1-5=gear | P |
| TURBIN | 0x31 | data[4-5] | raw RPM | 738 |
| T-TEMP | 0x30 | data[11] | **raw - 50 = °C** | 58°C |
| LIMP | 0x30 | data[9]+maxGear | logic | Normal |
| LINE-P | 0x30 | data[9-10] | signed raw | — |
| TCC | 0x30 | data[0-1] | signed raw RPM | 12 |
| SOL V | 0x34 | data[6-7] | /40 = V | 13.05 |
| BATT | 0x34 | data[8-9] | /154.5 = V | 13.30 |

## Known ECU Constants

| Value | Usage |
|-------|-------|
| 0.0049 | Voltage ADC factor (V = raw × 0.0049) |
| 0.101 | Pressure factor (Bar = raw × 0.101) |
| 0.0236 | Secondary ADC factor |
| 0.011 | Temp/voltage factor |
| 0.25 | TCM current factor |
| 0.007 | TCM multiplier |
| -41.0 | TCM offset (for some params) |
| 10.0 | Common divisor |
| 100.0 | Common divisor |
| 1000.0 | Common divisor |

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

- **ECU 0x15**: Dynamic seed. ArvutaKoodi computes 2-byte key. When seed=`00 00` (ECU already unlocked), key=`9C C9` which ECU accepts. Qt code skips key computation and sets `ecuSecurityUnlocked=true`.
- **TCM 0x20**: Static seed `68 24 89` → Key `CC 21` (EGS52 algorithm: swap, XOR 0x5AA5, multiply 0x5AA5)

## DTC

K-Line: `18 02 00 00` read (ECU), `18 02 FF 00` read (TCM), `14 00 00` clear
J1850: `ATSH24xx18` + `FF 00 00` read, `ATSH24xx14` + `FF 00 00` clear
ESP 0x58 DTC clear: `01 00 00` (7 retries before positive response)

**NRC 0x78 on DTC clear**: ECU may return `7F 14 78` (ResponsePending) before `54 00 00` (success). Both arrive in same ELM327 frame.

## ESP32-S2 Emulator

WiFi AP "WiFi_OBDII", IP 192.168.0.10, TCP 35000. All block responses use exact real vehicle BLE hex data.

### Verified Behaviors
- **ATFI two-part response**: `ATFI\rBUS INIT:\r` + 300ms delay + `OK\r\r>` (matches real ELM327 wire format)
- **First `81` = BUS INIT**: When K-Line TCM uses `81` for bus init (no ATFI), first `81` response includes `BUS INIT: OK\r` prefix
- **Seed=0x0000 mode**: ECU returns `67 01 00 00` for first 3 seed requests (simulates already-unlocked state), then switches to dynamic seed. `ecuUnlocked=true` when seed=0 so blocks 62/B0/B1/B2 respond
- **Bare `27 02` handling**: Returns NRC 0x12 for `27 02` with no key bytes (real vehicle behavior when seed=0)
- **Block 0x28 full format**: 28 data bytes with per-cylinder RPMs [4-13] and signed injection corrections [20-25]
- **J1850 bus noise injection**: Random `2D 28 02 51` / `2D 28 0A B9` frames prepended to ~15% of J1850 responses
- **NRC 0x21 simulation**: ~5% of J1850 mode 0x22 reads return `7F 22 21` (busyRepeatRequest) to test retry logic
- **NRC 0x78 for actuators**: `30 3A 08+` commands get `7F 30 78` + positive response in same frame

Dynamic fields: RPM (0x12/0x28 with per-cyl), coolant temp (0x12/0x22), fuel qty (0x32), TCM gear cycling, TCM RPMs, injection corrections.
