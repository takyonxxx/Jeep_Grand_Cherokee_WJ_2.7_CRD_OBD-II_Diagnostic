# WJ 2.7 CRD — J1850 Actuator Relay Command Reference

## Door LEFT 0xA0 — Mode 0x2F (Sequential)

Header: `ATSH24A02F`

| PID | Actuator | ON | OFF |
|-----|----------|-----|-----|
| 0x00 | Front Window Down | `38 00 12` | `38 00 00` |
| 0x01 | Front Window Up | `38 01 12` | `38 01 00` |
| 0x02 | Lock | `38 02 12` | `38 02 00` |
| 0x03 | Mirror Down | `38 03 12` | `38 03 00` |
| 0x04 | Mirror Heater | `38 04 12` | `38 04 00` |
| 0x05 | Mirror Left | `38 05 12` | `38 05 00` |
| 0x06 | Mirror Right | `38 06 12` | `38 06 00` |
| 0x07 | Mirror Up | `38 07 12` | `38 07 00` |
| 0x08 | Rear Window Down | `38 08 12` | `38 08 00` |
| 0x09 | Rear Window Up | `38 09 12` | `38 09 00` |
| 0x0A | Switch Illumination | `38 0A 12` | `38 0A 00` |
| 0x0B | Unlock | `38 0B 12` | `38 0B 00` |
| 0x0C | Mirror Fold In | `38 0C 12` | `38 0C 00` |
| 0x0D | Mirror Fold Out | `38 0D 12` | `38 0D 00` |

## Door RIGHT 0x40 — Mode 0x2F (Bitmask)

Header: `ATSH24402F`

Register 0x06 shared bitmask: Lock=02, RearWinUp=04, MirrorHeat=08, MirrorL=10, MirrorR=20

| Actuator | ON | OFF |
|----------|-----|-----|
| Front Window Down | `38 08 01` | `38 08 00` |
| Front Window Up | `38 07 01` | `38 07 00` |
| Lock | `38 06 02` | `38 06 00` |
| Mirror Down | `38 02 01` | `38 02 00` |
| Mirror Heater | `38 06 08` | `38 06 00` |
| Mirror Left | `38 06 10` | `38 06 00` |
| Mirror Right | `38 06 20` | `38 06 00` |
| Mirror Up | `38 0C 02` | `38 0C 00` |
| Rear Window Down | `38 08 02` | `38 08 00` |
| Rear Window Up | `38 06 04` | `38 06 00` |
| Illumination | `38 0D 01` | `38 0D 00` |
| Release All | `3A 02 FF` | — |

## BCM 0x80 — Mode 0x2F

Header: `ATSH24802F`

Hazard and ParkLamp are inverted: ON=0x00, OFF=0x01.

| Actuator | ON | OFF |
|----------|-----|-----|
| Horn | `38 00 CC` | `38 00 00` |
| Hi Beam | `38 00 FF` | `38 00 00` |
| Low Beam | `38 02 05` | `38 02 00` |
| Hazard (inverted) | `38 01 00` | `38 01 01` |
| Park Lamp (inverted) | `38 09 00` | `38 09 01` |

## BCM 0x80 — Mode 0xB4

Header: `ATSH2480B4`

Pre-activation: `ATSH248022` → `ATRA80` → `28 0D 00` → `ATSH2480B4` → `28 0D 01`

| Actuator | ON | OFF |
|----------|-----|-----|
| Rear Defog | `38 02 02` | `38 02 00` |
| Rear Fog | `38 09 01` | `38 09 00` |
| Front Fog | `38 02 04` | `38 02 00` |
| VTSS Lamp | `38 04 01` | `38 04 00` |
| Wiper | `38 04 02` | `38 04 00` |
| Chime | `38 02 03` | `38 02 00` |
| EU Daylights | `38 04 04` | `38 04 00` |
| Single Wipe | `38 04 03` | `38 04 00` |

## ECU SID 0x30 — Actuator Control (K-Line)

Format: `30 PID 07 VALUE_HI VALUE_LO`

| PID | ON Value | OFF |
|-----|----------|-----|
| 0x11 | 13 88 | 00 00 |
| 0x12 | 00 10 | 00 00 |
| 0x14 | 27 10 | 00 00 |
| 0x16 | 27 10 | 00 00 |
| 0x17 | 27 10 | 00 00 |
| 0x18 | 08 34 | 00 00 |
| 0x1A | 13 88 | 00 00 |
| 0x1C | 27 10 | 00 00 |

## Notes

- 0xA0 = LEFT/Driver door (US tools mislabel as "Passenger Door")
- 0x40 = ABS module with door relay capability
- Right door has no dedicated J1850 module
- No DiagSession required for relay commands
- BCM (0x80) does not respond to J1850 read commands, only relay
- OM612 has no MAF sensor — MAF=0 at idle is normal
