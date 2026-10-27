# Engine (0x15, K-Line) canlı veri logları

WJdiag-Pro'da Engine > tüm sensörler > live data. Kullanıcının verdiği ham loglar
sırayla buraya işleniyor. APK değiştirilmeyecek, sadece kayıt + analiz.

## Log 1 (motor calisir, tum degerler dolu)
Init: ATWM8115F13E, ATSH8115F1, ATSP5, 81->C1 EF 8F
Guvenlik: 27 01 -> 67 01 8B 05 (seed), 27 02 C1 7F -> 67 02 34 (anahtar OK), sonra 67 01 00 00
Okuma: 1A 90 (VIN), 1A 91, 21 62, 1A 86

Canli veri blok okuma SIRASI (dongu halinde):
  21 12 -> 21 30 -> 21 22 -> 21 20 -> 21 23 -> 21 21 -> 21 16 -> 21 32 -> 21 37 -> 21 13 -> 21 36 -> 21 26 -> 21 34 -> (basa don)

Ornek ham yanitlar (1. tur):
  61 12 0D ED 0B D8 08 B7 08 B7 00 00 06 99 27 10 0E 73 03 B7 22 03 02 A6 01 2A 00 42 09 7F 03 A0 00 00
  61 30 02 EE 00 00 00 00 0C 91 0C 92 03 E5 00 00 00 00 00 00 0B 77 00 00 00 00
  61 22 0D ED 0B E8 08 B7 08 B7 00 00 00 00 02 11 04 60 0B 97 03 94 02 4E 02 E4 02 E4 02 BF 08 B7 00 0F
  61 20 01 C6 07 46 03 FE 00 00 00 94 00 48 01 A8 01 63 01 08 02 E5 02 4D 00 90 00 BF 03 A0 01 FA
  61 23 0D 0E 02 4D FF F9 0D 3A 03 9F 02 7A 00 7E 00 30 03 FD 01 2A
  61 21 17 C0 0E 8E 0E 8E 14 50 01 2A 01 2A 0E 8E 01 EF 00 B4 01 5D
  61 16 01 2C 21 40 00 00 ... 27 10 07 DA ... 01 F4 00 00
  61 32 0F 4B 0A D8 00 38 00 38 0C E4 0F 4B 0F 4B 01 89 01 A2 00 FA 00 30 02 6E 02 C9 00 ...
  61 37 0C 97 11 48 00 79 00 00 00 08 ... 00 4E ... 01 05 00 40 ...
  61 13 03 93 02 4A 02 E4 02 E4 00 00 08 B7 00 00 02 50 FF FC 0B D7 00 85 03 FD 0B CC
  61 36 00 03 04 00 0E A6 1C 70 07 AA 03 92 27 10 00 00 03 98 00 00 06 26 28 2C FF FF 1C 70 00 A2 07 08 00 04 87 F0 00 01
  61 26 00 00 18 B6 00 00 5C B1 7F FF 00 00 2F A0 00 29 00 29 00 29 00 29 00 48 00 23 00 00 0C 77
  61 34 00 48 10 00 00 00 00 04 ... 03 FF 00 03 ...

NOT: Sensor ISIMLERI telde yok, WJdiag-Pro UI'da olusuyor. Isim+sira icin canli veri EKRAN RESMI gerekli.
Resim gelince: her isim+deger -> logdaki blok/byte/formul eslemesi yapilacak.

## WJdiag-Pro Engine canli veri SENSOR SIRASI + ISIM + DEGER (resimlerden, motor rolanti ~754 rpm)
 1. Engine RPM: 754 Rpm
 2. Low Idle Setpoint SPD: 750 Rpm
 3. Accelerator Pedal Position Sensor 1: 0 %
 4. Accelerator Pedal Position Sensor 2: 0 %
 5. Accelerator Pedal Position Sensor 1 Voltage: 0.73 V
 6. Accelerator Pedal Position Sensor 2 Voltage: 0.35 V
 7. Boost Pressure Sensor: 0.930 Bar
 8. Boost Pressure Voltage: 1.74 V
 9. Boost Pressure Setpoint: 0.997 Bar
10. Fuel Level: 50 %
11. Fuel Level Sensor Voltage: 4.22 V
12. Fuel Pressure Regulator Output: 0 %
13. Fuel Rail Pressure Sensor, Actual: 515.419 Bar
14. Fuel Pressure Volts: 1.29 V
15. Fuel Pressure Setpoint: 296.560 Bar
16. Desired Fuel QTY Pedal: 0.00 Mg/Str
17. Desired fuel QTY Cruise: 0.00 Mg/Str
18. Desired Fuel QTY Demand: 0.00 Mg/Str
19. Desired Fuel QTY Driver: 0.00 Mg/Str
20. Actual Fuel Quantity: 8.80 Mg/Str
21. Fuel QTY Start Setpoint: 27.76 Mg/Str
22. Fuel QTY Limit: 33.00 Mg/Str
23. Fuel QTY Torque: 8.80 Mg/Str
24. Fuel QTY Low-Idle Gov: 8.80 Mg/Str
25. Battery Voltage: 13.92 V
26. Battery Temp: 41.2 C
27. Battery Temp Voltage: 2.48 V
28. Alternator Field Current: 1.5 A
29. Alternator Duty Cycle: 45 %
30. Oil Pressure Sensor: 1.920 Bar
31. Oil Pressure Voltage: 1.71 V
32. Coolant Temp: 85.7 C
33. Coolant Sensor Voltage: 1.76 V
34. Air Intake Temp: 30.0 C
35. Air Intake Volts: 7.83 V
36. Outside Air Temperature: 28.9 C
37. Mass Air Flow: 724.9 Mg/Str
38. Mass Air Flow Voltage: 2.08 V
39. Barometric Pressure: 0.916 Bar
40. Barometer Pressure Voltage: 3.63 V
41. AC System Pressure: 6.338 Bar
42. AC System Pressure Voltage: 0.94 V
43. Vehicle Speed: 61 Km/h
44. Vehicle Speed Setpoint: 0 Km/h
45. Cruise Switch Voltage: 4.54 V
46. MAF for EGR Setpoint: 322 Mg/Str
47. Wastegate Solenoid: 85 %
48. Transfer Case Position Sensor Voltage: 1.460 V
49. Camshaft/crankshaft Synchronization: In-Sync
50. Injector Bank 1 Capacitor: 91.7 (V?)

YAKIT NOTU: WJdiag-Pro'nun kendi "Fuel Level" = %50 (bizim tespit ettigimiz blok 0x21 sahte sabit ile AYNI!).
Ayrica ayri bir "Fuel Level Sensor Voltage" = 4.22 V var (gercek sender voltaji). Yani WJdiag-Pro da
yakit SEVIYESINI %50 sabit gosteriyor; gercek sinyal sender voltaji. Bizim yaklasim dogruydu.
SONRAKI ADIM: her ismi log blok/byte/formul ile esle (deger eslesmesiyle).

## FUEL CORRECTION TEST (enjektor duzeltme) = RUTIN 0x25
Dizi: 81 -> 21 12 -> 81 -> 27 01 (67 01 00 00) -> 27 02 (7F 27 12) -> 27 01 -> **31 25 00 -> 71 25** -> sonra tekrar tekrar **21 28**.

Blok 0x28 yapisi (motor calisir + rutin 0x25 aktif), ornek:
  61 28 02 E8 | 03 70 | 02 E8 02 E8 02 E8 02 E8 02 E8 | 00 00 | 00 11 00 15 FF 71 00 33 00 32 | 00 00
  - [0-1]=02 E8 genel; [2-3]=03 70 sabit referans (880)
  - [4-13] = 5 silindir degeri (hepsi ~02 E8 = dengeli)
  - [16-17][18-19][20-21][22-23][24-25] = 5 SILINDIR DUZELTMESI (signed 16-bit):
      cyl1=00 11=17, cyl2=00 15=21, cyl3=FF 71=-143, cyl4=00 33=51, cyl5=00 32=50
  - cyl3'te buyuk negatif duzeltme. Degerler turlar arasi degisiyor (17-23, 12-21, -137..-143, 49-54, 48-50).
Bazi yanitlar farkli format: 61 28 07 D2 0E B2 00 00.. veya 61 28 05 7A 00 00.. (olcum ara fazi) -> [16-25] bos.
ONAY: Bizim app yontemi DOGRU. Rutin 0x25 gonderilmeden [16-25] sifir gelir (aracta hep sifir gormenin nedeni).
Bizim kod zaten canli veri/duman testi basinda 31 25 00 gonderiyor. ESLESIYOR.

## INJECTOR LEARN (enjektor ogrenme) -- "no answer" (tamamlanmadi)
Dizi: 27 01 (67 01 00 00) x2 -> 27 02 9C C9 (7F 27 12) -> 27 01 -> sonra tekrar tekrar **30 3A 01 -> 70 3A 01**.
- Servis 0x30 (inputOutputControl/aktuator), alt 0x3A, param 01. Cevap 70 3A 01 = sadece komut ack.
- WJdiag-Pro "no answer" dedi: ack geliyor ama ogrenme SONUC yaniti gelmiyor.
- Muhtemel sebep: ogrenme calisir/sicak motor + rolanti sarti istiyor, ya da enjektor kodlama yok.
- Komut dogru (30 3A 01); sonuc bu kosulda gelmiyor.

## MAXIMUM VALUES = blok 21 B0 / 21 B1 / 21 B2 (2 bayt her biri)
- 61 B0 37 0F -> 0x370F = 14095
- 61 B1 D2 15 -> 0xD215 = 53781
- 61 B2 E0 4B -> 0xE04B = 57419
- Sabit saklı max degerler (ecu_live pcap'te de ayni).
- EKRAN ESLESMESI (resimden):
    21 B0 (37 0F) = Max Coolant Temp = 117 C  (formul belirsiz: 0x0F37=3895 ya da 0x370F=14095)
    21 B1 (D2 15) = Max engine RPM = 5586 rpm  (LITTLE-ENDIAN: 0x15D2=5586)
    21 B2 (E0 4B) = Max Vehicle speed = 194 Km/h  (LITTLE-ENDIAN: 0x4BE0=19424, /100=194.24)
- NOT: RPM ve hiz byte-swapped (little-endian) okunuyor.

## AKTUATOR TESTLERI (ECU 0x15, servis 0x30)
### EGR Solenoid actuating
- Keepalive 81 -> C1 EF 8F
- AC: 30 11 07 13 88 -> 70 11 07 13 88 (deger 0x1388=5000, muhtemelen %50 / hedef)
- KAPAT: 30 11 07 00 00 -> 70 11 07 00 00
- Format: 30 11 07 <16-bit deger>. Cevap 70 11 07 ...

### Cabin/Viscous Heater Relay actuating
- AC: 30 1C 07 27 10 -> 70 1C 07 27 10 (0x2710=10000=%100)
- KAPAT: 30 1C 07 00 00 -> 70 1C 07 00 00
- DEGER BIRIMI: 0.01% -> 10000=%100, 5000=%50. Aktuator ID teste ozel (EGR=11 07, isitici=1C 07).
- Genel format: 30 <id2byte> <16-bit deger 0..2710>. Cevap 70 <id> <deger>.

### Glow Plug Relay 1 actuating
- AC: 30 16 07 27 10 -> 70 16 07 27 10 (%100)
- KAPAT: 30 16 07 00 00 -> 70 16 07 00 00

### AKTUATOR ID LISTESI (30 <id> <deger>)
- EGR Solenoid: 11 07 (EGR icin ornek 13 88=%50; AC/KAPAT icin 27 10 / 00 00 de olur)
- Cabin/Viscous Heater Relay: 1C 07
- Glow Plug Relay 1: 16 07
- Glow Plug Relay 2: 17 07
- A/C Control: 14 07  (AC 27 10, KAPAT 00 00)
- Swirl Solenoid: 1A 07  (AC 13 88=%50, KAPAT 00 00)
- Boost Pressure: 12 07  (AC 00 10=16 farkli birim, KAPAT 00 00)
- Hydraulic Rad Fan: 18 07  (LOW 08 34=%21, HIGH 21 34=8500=%85, KAPAT 00 00) -- hiz degerle ayarlanir

### Compression Test
- Blok 21 12 okuyor (ana motor blogu), muhtemelen surekli -> silindir basi devir dalgalanmasi izleniyor.
- Ornek: 61 12 0E 61 0B F3 08 B7 08 B7 00 00 03 52 00 00 03 70 03 A2 0F EF 02 A6 01 2A 00 42 09 7F 03 A0 00 00
- Tek sample; silindir bazli analiz icin birkac tur gerek.

## DURUM / ANAHTARLAR ekrani (digital inputs + op phases)
Blok okuma dongusu: 21 14 -> 21 16 -> 21 34 -> 21 48 (tekrar).
  61 14 = hep 00 (bu araçta)
  61 16 = 01 2C 21 40 00..00 27 10 07 DA 00..00 01 F4 00 00
  61 34 = 00 48 10 00 00 00 00 04 00..00 03 FF 00 03 00..00 03 00..00 04 00 00
  61 48 = hep 00
Ekran item sirasi + deger (resimlerden):
  Park/Neutral Switch: D/R | Primary Brake: Released | Secondary Brake: Released
  EGR Duty Cycle: 3% | AC Control Relay: 0% | Swirl Solenoid: Off | Cabin/Viscous Relay 1: Off
  Glow Plug Display: On | Glow Plug Relay 1: On | Glow Plug Relay 2: 0% | Hydraulic Rad Fan: 0% | Water in Fuel: No
  Start op Phase: No | Afterrun op Phase: No | EGR op Phase: Yes | Boost op Phase: No | A/C op Phase: No
  Steering Control op Phase: No | Cutout: --- | Cutout Error/On-Off/Cancel/Coast/Set/Accel-Resume Switch: Released
NOT: Bit->isim kesin eslemesi icin anahtarlari tek tek degistirip tekrar bakmak gerek (cogu 0/Released).
