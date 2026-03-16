# ECU + TCM Block Byte Mapping — Jeep WJ 2.7 CRD (OM612/NAG1)
## Verified: Real Vehicle BLE Full Dump + WJDiag Pro Cross-Reference

### Dashboard Parameters (VERIFIED)

| # | Gauge | WJDiag Pro Name | Block | Parser | Formula | WJDiag Pro |
|---|-------|----------------|-------|--------|---------|-----------|
| 1 | RPM | Engine RPM | 0x12 (0x28 override) | u16(12) | raw | 751 |
| 2 | M-TEMP | Coolant Temp | 0x22 | u16(2) | /10-273.1=C | 54.7C |
| 3 | BOOST | Boost Pressure Sensor | 0x22 | u16(16) | MAP/1000=Bar | 0.913 |
| 4 | RAIL | Fuel Rail Pressure | 0x12 | u16(20) | /10=Bar | 294.236 |
| 5 | MAF | Mass Air Flow | 0x36 | u16(8) | /10=Mg/Str | 478.2 |
| 6 | INJ-Q | Actual Fuel Quantity | 0x32 | u16(2) | /100=mg/str | 8.60 |
| 7 | BATT | Battery Voltage | 0x16 | u16(4) | *5/3072=V | 13.85 |
| 8 | FUEL | calculated | - | rpm*fuelActual | L/h | - |

### Notes
- Boost = MAP(mbar) / 1000 = Bar (atmospheric ~0.9, turbo adds)
- Battery uses ADC formula: raw * 5.0 / 3072
- Rail comes from 0x12 ONLY (0x22[16-17] is Air Intake Volts, NOT Rail!)
- Many non-dashboard params use complex native lib formulas (not fully decoded)
