# WJDiag — Jeep Grand Cherokee WJ 2.7 CRD Diagnostic Tool

## Vehicle: 2003 EU-spec WJ 2.7 CRD (OM612 / NAG1)

Qt6 cross-platform diagnostic application + ESP32-S2 ELM327 emulator.
All actuator commands verified via WJdiag-Pro APK connected to ESP32 simulator.

## Complete Module Address Map (APK-Verified via Simulator)

Ref app menu order with confirmed J1850/K-Line addresses:

| # | Ref App Menu | Addr | Bus | Status |
|---|-------------|------|-----|--------|
| 1 | Engine | 0x15 | K-Line ISO14230 | Full data + security + 9 actuators + DTC |
| 2 | Transmission | 0x20 | K-Line ISO14230 | Full data + security + 4 tests + DTC |
| 3 | ABS | 0x28 | J1850 VPW | Read + 12 valve tests + DTC |
| 4 | Airbag | 0x58 | J1850 VPW | Read only (no tests in ref app) |
| 5 | Shifter Lever | 0xC0 | J1850 VPW | 11 LED controls via SID 0x3A (cluster) |
| 6 | SKIM | 0x40 | J1850 VPW | Reset + Indicator + VIN + Key program |
| 7 | Body Computer | 0x98 | J1850 VPW | 10 motor tests + cross-read 0x40 |
| 8 | Auto Temp Control | 0xA0 | J1850 VPW | 16 actuators (windows/mirrors/locks) |
| 9 | Driver Door | 0xA1 | J1850 VPW | 15 actuators + RKE program |
| 10 | Passenger Door | 0x60 | J1850 VPW | NRC always ("no answer") |
| 11 | Electro Mech Cluster | 0x68 | J1850 VPW | Self test + reset |
| 12 | Overhead Console | 0x6D | J1850 VPW | Module not present |
| 13 | Navigation | 0x80 | J1850 VPW | NO DATA |
| 14 | Radio | 0x81 | J1850 VPW | Module not present |
| 15 | CD Changer | 0x62 | J1850 VPW | Module not present |
| 16 | Park Assist | 0xA7 | J1850 VPW | Read + DTC clear |
| 17 | Rain Sensor | 0x2A | J1850 VPW | NO DATA |
| 18 | Adjustable Pedal | 0x87 | J1850 VPW | Module not present |
| 19 | Satellite Audio | 0x90 | J1850 VPW | Module not present |
| 20 | Hands Free | 0x90 | J1850 VPW | Module not present |

**Note:** Ref app menu names don't always match module function. For example "Shifter Lever" controls cluster LEDs via 0xC0, and "Body Computer" controls HVAC motors via 0x98.

### Active Modules on EU 2.7 CRD

| Function | Address | Actuator Tests |
|----------|---------|----------------|
| Engine ECU (Bosch EDC15C2) | K-Line 0x15 | 9 (EGR, Glow, A/C, Fan, etc.) |
| Transmission (NAG1 722.6) | K-Line 0x20 | 4 (Solenoid, Adaptives) |
| ABS | J1850 0x28 | 12 (Valves, Pump, Bleed) |
| ESP / Traction | J1850 0x58 | 0 (read + 50 live PIDs) |
| Body Computer | J1850 0x40 | 14 relays + mode 0xB4 config |
| Cluster (Shifter LED) | J1850 0x61/0xC0 | 11 LEDs + 6 gauges |
| HVAC / ATC | J1850 0x98 | 10 motor positions |
| Driver Door | J1850 0xA0 | 16 (windows/mirrors/locks) |
| Passenger Door | J1850 0xA1 | 15 + RKE |
| Overhead Console | J1850 0x68 | Self test + reset |
| Rain Sensor | J1850 0xA7 | DTC clear only |
| SKIM/Park Assist | J1850 0xC0 | 5 (VIN, keys, indicator) |

### Dead/NRC Modules

0x60 (NRC 0x22), 0x80 (NO DATA), 0x2A (NO DATA), 0x6D/0x81/0x62/0x87/0x90 (not present)

## Controls Tab

Detailed command reference: [RELAY_MAP.md](RELAY_MAP.md)

### Windows (APK-verified PID mapping)

| PID | Function |
|-----|----------|
| 0x01 | Front Window Up |
| 0x02 | Front Window Down |
| 0x03 | Rear Window Up |
| 0x04 | Rear Window Down |

Both doors use: `38 PID 12` ON, `38 PID 00` OFF.
Driver Door: `ATSH24A02F` + `ATRAA0` | Passenger: `ATSH24A12F` + `ATRAA1`

### Body Computer 0x40 Key Commands

| Function | Command |
|----------|---------|
| Hazard flashers | `38 06 20` / `38 06 00` |
| Horn relay | `38 0D 01` / `38 0D 00` |
| Hi Beam | `38 06 08` / `38 06 00` |
| Park lamp | `38 06 04` / `38 06 00` |
| Viper relay | `38 08 01` / `38 08 00` |

### Cluster Gauge Test (0x61)

SID 0x3A: `3A 00 80`=Speedo, `3A 00 40`=Tacho, `3A 00 08`=Fuel, `3A 00 04`=Temp, `3A 01 01`=Oil, `3A 01 04`=CE

## ECU Security Unlock (K-Line KWP2000)

### Algorithm — "ArvutaKoodi" (Bosch EDC15C2)

The ECU uses SID 0x27 challenge-response with a lookup-table based key derivation:

```
Request:  27 01           → Response: 67 01 SEED_HI SEED_LO
Request:  27 02 KEY_HI KEY_LO → Response: 67 02 34 (success)
```

**Key calculation from seed:**

```c
// 4 lookup tables (16 bytes each)
T1 = {C0,D0,E0,F0,00,10,20,30,40,50,60,70,80,90,A0,B0}
T2 = {02,03,00,01,06,07,04,05,0A,0B,08,09,0E,0F,0C,0D}
T3 = {90,80,F0,E0,D0,C0,30,20,10,00,70,60,50,40,B0,A0}
T4 = {0D,0C,0F,0E,09,08,0B,0A,05,04,07,06,01,00,03,02}

s0 = SEED >> 8    // high byte
s1 = SEED & 0xFF  // low byte

// KEY_LO (from low seed byte)
v1 = (s1 + 0x0B) & 0xFF
KEY_LO = T1[v1 >> 4] | T2[v1 & 0x0F]

// KEY_HI (from high seed byte + carry)
carry = (s1 > 0x34) ? 1 : 0
v2 = (s0 + carry + 1) & 0xFF
KEY_HI = T3[v2 >> 4] | T4[v2 & 0x0F]
```

**Example:** Seed=`0xBFDE` → s0=0xBF, s1=0xDE → v1=(0xDE+0x0B)&0xFF=0xE9 → KEY_LO=T1[0xE]=0xA0|T2[0x9]=0x0B=0xAB → carry=1 (0xDE>0x34) → v2=(0xBF+2)&0xFF=0xC1 → KEY_HI=T3[0xC]=0x50|T4[0x1]=0x0C=0x5C → Key=`5C AB`

### TCM Security

TCM uses static seed: `67 01 68 24 89` → Key: `CC 21` (hardcoded in ref app)

### Security Flow

```
81                    → C1 EF 8F          (StartCommunication)
27 01                 → 67 01 XX XX       (RequestSeed)
27 02 KEY_HI KEY_LO   → 67 02 34          (SendKey - success)
```

After unlock: `1A 90` (VIN read), `21 xx` (block read), `30 xx` (actuator control) become available.

## DTC Management

### K-Line (ECU 0x15 / TCM 0x20)

- Read: `18 02 00 00` (ECU) or `18 02 FF 00` (TCM)
- Clear: `14 00 00` → `54 00 00`

### J1850 Modules

- Read: `ATSH24xx18` + `ATRAxx` → response with DTC list
- Clear: `ATSH24xx14` + `ATRAxx` → `FF 00 00`
- Modules with DTC: 0x40, 0x28, 0xA7, 0x58, 0x60, 0x61, 0x68, 0x98, 0xA0, 0xA1, 0xC0

## ESP32-S2 Emulator

WiFi AP "WiFi_OBDII", IP 192.168.0.10, TCP port 35000, HTTP dashboard at port 80.

Features:
- Full K-Line KWP2000 with security unlock (ECU + TCM)
- Per-module J1850 DTC with clear flags (11 modules)
- K-Line ECU + TCM separate DTC with clear flags
- PCAP-verified response database (252 captures)
- Cluster gauge test (SID 0x3A)
- Body Computer mode 0x2F + 0xB4
- ATZ reset clears all DTC flags

## Protocol Notes

- CRC-16/MODBUS (poly=0xA001, init=0xFFFF) — immutable across all boards
- J1850 VPW: ATSP2, header format `24XXYY` (XX=target, YY=mode)
- K-Line ISO14230: ATSP5, `ATWM81XXF13E` + `ATSH81XXF1` init
- ATRA (receive address filter) is mandatory for all J1850 commands
- J1850 modes: 0x22=read, 0x2F=IOControl, 0xB4=extended, 0x14=DTC clear, 0x18=DTC read, 0x10=reset, 0x11=DiagSession
