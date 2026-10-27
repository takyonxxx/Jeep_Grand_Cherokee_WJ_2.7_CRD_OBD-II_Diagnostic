# ============ TAM TABLO (ESP32 capture + pcap ile DOGRULANDI) ============
#
# 20 MODUL:
#  Engine 0x15 (K-Line) | Transmission 0x20 (K-Line) | ABS 0x28 | Airbag 0x58 | Shifter Lever 0x61
#  SKIM 0xC0 | Body Computer 0x40 | Automatic Temp Control 0x98 | Driver Door 0xA0 | Passenger Door 0xA1
#  Electro Mech Cluster 0x60 | Overhead Console 0x68 | Navigation 0x6D | Radio 0x80 | CD Changer 0x81
#  Park Assist 0x62 | Rain Sensor 0xA7 | Adjustable Pedal 0x2A | Satellite Audio 0x87 | UConnect HandsFree 0x90
#
# YONTEMLER:
#  K-LINE (Engine 0x15, TCM 0x20): init ATWM81<addr>F13E + ATSH81<addr>F1 + ATSP5 + ATFI(ECU)/81(TCM) -> C1 EF 8F
#    Guvenlik: 27 01 -> 67 01 <seed>; 27 02 <key> -> 67 02 / 7F 27 12(zaten acik)
#    DTC OKU: 18 02 FF 00 (TCM) / 18 02 00 00 (ECU) -> 58 <count> <dtc dtc status>*
#    DTC SIL: 14 00 00 -> 54
#    Canli veri: 21 xx bloklari (ECU: 12,30,22,20,23,21,16,32,37,13,36,26,34 | TCM: 30,31,32,33,34,35)
#    Max values: 21 B0/B1/B2 (B1 RPM little-endian, B2 hiz LE /100)
#    Aktuator: 30 <id2> <16bit deger 0..2710=%100> -> 70 ... (EGR=11 07, Isitici=1C 07, GlowPlug1/2=16/17 07,
#      AC=14 07, Swirl=1A 07, Boost=12 07, RadFan=18 07[LOW 0834/HIGH 2134])
#    Rutin: 31 xx -> 71 xx (Fuel Correction=31 25 -> 21 28 oku; TCM Reset=31 31, Store=31 32)
#    Injector Learn: 30 3A 01 (ack var, sonuc yok); TCM Solenoid Test: 30 10 07 <val> (7F 30 22 kosul)
#  J1850 (ATSP2, ATIFR0, ATH1):
#    DTC OKU: ATSH24<addr>22 + 20/24/28 info + 2E/2F <pid> 00 tarama -> 26 <addr> 62 hi lo durum (hi/lo!=0 ariza)
#    DTC SIL: ATSH24<addr>14 + "01 00 00"(0x58) / "FF 00 00"(diger) -> 26 <addr> 54 (0x58 ~7 retry)
#    Canli veri: ATSH24<addr>22 + 32 <pid> 00 -> 26 <addr> 62 <raw> 00 00 ; VOLTAJ = raw*5/255
#    Aktuator: ATSH24<addr>2F + 38 <id> <val> -> 26 <addr> 6F 38 <id> <val> <xx> (basili tutarken tekrar)
#    Konfig: ATSH24<addr>B4 + 28 xx ; ayrica 3A xx, 2E xx
#
# APK'DA DUZELTILECEK (diger 17 adres dogru):
#  1. Airbag: 0x60 -> 0x58 (yontem 2E tarama + 14/"01 00 00" sil). 18 02 airbag yontemini KALDIR.
#  2. 0x60 = Electro Mech Cluster (yeni modul; "Airbag" etiketi buraya aitti).
#  3. 0x61 = Shifter Lever (eski "Gosterge Paneli/CLUSTER" etiketi yanlis).
#  Opsiyonel: menudeki tum 20 modul + eksik aktuator/canli veri ID'leri eklenebilir.
# =========================================================================

# WJdiag-Pro gerçek modül adres haritası (ESP32 capture ile doğrulanıyor)

Kullanıcı WJdiag-Pro menüsünden her modülü sırayla çağırıyor, loglar buraya işleniyor.
APK henüz DEĞİŞTİRİLMEYECEK — önce tüm adresler doğrulanacak.

WJdiag-Pro menü sırası: Engine, Transmission, ABS, Airbag, Shifter Lever, SKIM,
Body Computer, Automatic Temp Control, Driver Door, Passenger Door, Electro Mech Cluster,
Overhead Console, Navigation system, Radio, CD Changer, Park Assist, Rain Sensor,
Adjustable Pedal Module, Satellite Audio Receiver, UConnect Hands Free.

| # | Menü adı | Yol | Başlık | Adres | Bizim eski adres | Not |
|---|----------|-----|--------|-------|------------------|-----|
| 1 | Engine | K-Line ISO (ATSP5) | ATSH8115F1 | **0x15** | 0x15 ✓ | doğru |
| 2 | Transmission | K-Line ISO (ATSP5) | ATSH8120F1 | **0x20** | 0x20 ✓ | doğru |
| 3 | ABS | J1850 (ATSP2) | ATSH2428 22 | **0x28** | 0x28 ✓ | doğru |
| 4 | Airbag | J1850 (ATSP2) | ATSH2458 22 | **0x58** | 0x60 ✗ | DÜZELT: 0x60->0x58. Bizim "ESP"(0x58) aslinda buydu |
| 5 | Shifter Lever | J1850 (ATSP2) | ATSH2461 22 | **0x61** | — | Bizim CLUSTER(0x61) "Gosterge Paneli" YANLIS; burasi Shifter Lever |
| 6 | SKIM | J1850 (ATSP2) | ATSH24C0 22 | **0xC0** | 0xC0 ✓ | doğru |
| 7 | Body Computer | J1850 (ATSP2) | ATSH2440 22 | **0x40** | 0x40 ✓ | doğru |
| 8 | Automatic Temp Control | J1850 (ATSP2) | ATSH2498 22 | **0x98** | 0x98 ✓ | doğru |
| 9 | Driver Door | J1850 (ATSP2) | ATSH24A0 22 | **0xA0** | 0xA0 ✓ | doğru |
| 10 | Passenger Door | J1850 (ATSP2) | ATSH24A1 22 | **0xA1** | 0xA1 ✓ | doğru |
| 11 | Electro Mech Cluster | J1850 (ATSP2) | ATSH2460 22 | **0x60** | 0x60="Airbag" ✗ | 0x60 = EMC, airbag DEGIL. Airbag<->EMC yer degistirmis |
| 12 | Overhead Console | J1850 (ATSP2) | ATSH2468 22 | **0x68** | 0x68 ✓ | doğru |
| 13 | Navigation system | J1850 (ATSP2) | ATSH246D 22 | **0x6D** | 0x6D ✓ | doğru (araçta yok, NO DATA) |
| 14 | Radio | J1850 (ATSP2) | ATSH2480 22 | **0x80** | 0x80 ✓ | doğru (NO DATA) |
| 15 | CD Changer | J1850 (ATSP2) | ATSH2481 22 | **0x81** | 0x81 ✓ | doğru (NO DATA) |
| 16 | Park Assist | J1850 (ATSP2) | ATSH2462 22 | **0x62** | 0x62 ✓ | doğru (NO DATA) |
| 17 | Rain Sensor | J1850 (ATSP2) | ATSH24A7 22 | **0xA7** | 0xA7 ✓ | doğru. Silme FF 00 00 (hemen 54) |
| 18 | Adjustable Pedal Module | J1850 (ATSP2) | ATSH242A 22 | **0x2A** | 0x2A ✓ | doğru (NO DATA) |
| 19 | Satellite Audio Receiver | J1850 (ATSP2) | ATSH2487 22 | **0x87** | 0x87 ✓ | doğru (NO DATA) |
| 20 | UConnect Hands Free | J1850 (ATSP2) | ATSH2490 22 | **0x90** | 0x90 ✓ | doğru (NO DATA) |

## SONUÇ: Düzeltilecek 3 adres (diğer 17 doğru)
1. **Airbag**: 0x60 -> **0x58** (bizim "ESP / Cekis"(0x58) aslinda Airbag; listede ESP yok)
2. **Electro Mech Cluster**: bizim "Airbag"(0x60) aslinda EMC -> 0x60'i "Electro Mech Cluster" yap
3. **Shifter Lever**: bizim "Gosterge Paneli / CLUSTER"(0x61) aslinda Shifter Lever -> 0x61'i "Shifter Lever" yap

Silme komutu: 0x58 (airbag) = "01 00 00" (7 retry); diger J1850 = "FF 00 00" (hemen).
APK HENUZ DEGISTIRILMEDI (airbag 0x58 degisikligi onceden yapildi; EMC/Shifter etiketleri bekliyor).
Kullanici "simdi duzelt" deyince yapilacak.

## Detaylar

### Engine (0x15, K-Line)
- Init: ATWM8115F13E, ATSH8115F1, ATSP5, ATFI, 81 -> C1 EF 8F
- Güvenlik: 27 01 -> 67 01 00 00 (seed 0000 = kilit açık), 27 02 <key> -> 7F 27 12
- Okuma: 1A 90 (VIN 1J8GWE82X2Y122006), 1A 91, 21 62, 1A 86

### Engine DTC oku/sil (0x15, K-Line)
- Oku: 18 02 00 00 -> 58 <count> <dtc_hi dtc_lo status>* (ornek: 58 01 07 02 E0 = 1 ariza 07 02)
- Sil: 14 00 00 -> 54 00 00
- Tekrar: 18 02 00 00 -> 58 00 (temiz)
- Bizim yontemle AYNI (dogru).

### Transmission (0x20, K-Line)
- Init: ATWM8120F13E, ATSH8120F1, ATSP5, 81 -> BUS INIT: OK, C1 EF 8F
- Okuma: 1A 90 (TCM VIN bos = 00..0), 1A 86
- Güvenlik yok (bu okumada)

### Transmission DTC + live data (0x20, K-Line)
- DTC oku: 18 02 FF 00 -> 58 01 22 10 20 (1 ariza, kod 22 10). TCM FF maskesi (motor 00 00). Bizim app DOGRU.
- DTC sil: 14 00 00 -> 54 00 00
- Live data bloklari: 21 30, 21 31, 21 32, 21 33, 21 34 (dongu)
- Ornek: 61 31 degerleri her tur degisiyor (RPM canli). 61 34 02 0C 03 FF 03 32 02 0A 08 07 00 01 00 28 sabit.
- Sensor sirasi + deger (motor calisir, ~2050 rpm):
   1 Transmission Temp: 58 C | 2 Output RPM: 0 | 3 Input RPM (N2): 1209 | 4 Input RPM (N3): 0
   5 Turbine RPM: 1988 | 6 Engine RPM: 2050 | 7 Des TCC slip: 0 | 8 Actual TCC slip: 0
   9 Battery: 13.10 V | 10 Sensor Supply: 5.73 V | 11 Solenoid Supply: 13.05 V
   12 LF wheel speed: 0 | 13 RF wheel speed: 0 | 14 LR wheel speed: 0 | 15 RR wheel speed: 0
   16 Rear Vehicle speed: 0 Km/h | 17 Front Vehicle speed: 0 Km/h | 18 TCC pressure: 0.000 Bar
   19 Shift PSI: 1.904 Bar | 20 Modulation PSI: 1.499 Bar | 21 TPS percent: 18 % | 22 Uphill Grad: 0 %
- NOT: byte->sensor kesin eslemesi icin deger korelasyonu gerek (sonra).

### TCM DURUM/VITES ekrani (0x20) -- bloklar 21 30, 32, 33, 34, 35
Ornek: 61 30 00 14 00 1E 01 F4 00 05 04 01 11 6F FF F6 FF F6 00 00 96 18 00 08
        61 35 hep 00
Item + deger (P vitesde, motor calisir):
  Torque Converter Clutch state: Open | Gear: 1 | Actual Gear: 1 | Target Gear: 1
  Kickdown Switch Actuated: No | Fault Set: No | Limp In Set: No | Max Gear: N/A
  Set 1245 Solenoid: No | Set 2-3 Solenoid: No | Set 3-4 Solenoid: Yes | Act 1245 Solenoid: No
  Act 3-4 Solenoid: Yes | **Shifter Lever Position: P** | Shifter Lever Position Input: High
  C1: High | C2: High | C3: Low | C4: Low | C5: Off
  Park Lockout Solenoid: On | Starter Interlock: Invalid | Transfer Case Switch: (kesik)
ONEMLI: Shifter Lever Position = P/R/N/D kesin vites bilgisi TCM'de! Dashboard gear icin bu kullanilacak.
  Blok 0x30'da seleft byte (bizim app zaten 0x30'dan selector okuyor). Byte korelasyonu sonra.

### TCM Reset Adaptives (0x20)
- 81 -> C1 EF 8F, sonra 31 31 -> 71 31 (tekrar). Rutin 0x31 (startRoutine). Cevap 71 31 olumlu.
### TCM Store Adaptives (0x20)
- 31 32 -> 71 32 (tekrar). (Reset=31 31, Store=31 32)
### TCM Solenoid Test (0x20) -- "no answer"
- 30 10 07 00 02 -> 7F 30 22 (NRC 0x22 conditionsNotCorrect). Komut dogru ama kosul yetersiz (arac dur/motor kapali gerekebilir).
- Park Lockout Solenoid Test: 30 10 07 04 00 -> 7F 30 22 (ayni). Format 30 10 07 <deger> (deger testi secer).

### ABS (0x28, J1850)
- Init: ATSP2, ATIFR0, ATH1, ATSH242822, ATRA28
- Okuma: 20 00/01/02, 24 00, 28 01, 20 07/08 -> cevap 26 28 62 ...
- Not: cevap basligi 26 28
- LIVE DATA (no answer bu araçta): header ATSH2428 22, info (20 00/01/02, 24 00, 28 01, 20 07/08), sonra
  32 10 00 -> 26 28 62 10 00 00, 32 11 00 -> 26 28 62 11 00 00 (servis 0x32 PID; degerler 00 00 bos).
  Sensorler (8): Reference Voltage, Pump Voltage, Ignition Voltage, LF/RF/LR/RR Wheel Speed, Vehicle Speed.
  Bos geliyor -> arac hareketli olmali ya da desteklenmiyor.

### Airbag (0x58, J1850)  [ESP32 capture'da oku+sil de goruldu]
- Init: ATSP2, ATIFR0, ATH1, ATSH245822, ATRA58
- Okuma: 20 00/01/02, 24 00, sonra 2E xx 00 / 2F xx 00 PID taramasi -> 26 58 62 hi lo durum
- Silme: ATSH245814 + 01 00 00 (tekrar, 7. denemede 26 58 54)
- Bizim app 0x60 = YANLIS. Dogru 0x58. "ESP / Cekis" etiketimiz bu modulmus (listede ESP yok).

### Driver Door live data (0xA0, J1850) -- J1850 body live-data yontemi
- header ATSH24A0 22, sonra 32 00 00 .. 32 04 00 -> 26 A0 62 <raw> 00 00
- PID eslemesi:
    32 00 = Rear Window Current (A), raw 00
    32 01 = Front Window Current (A), raw 00
    32 02 = Mirror Horizontal Voltage: raw 90=144 -> 2.82 V
    32 03/04 = Mirror Vertical / Key Cylinder Switch Voltage: raw FF=255 -> 5.00 V
- VOLTAJ FORMULU: V = raw * 5 / 255 (FF=5.00, 90=2.82). Akim PID'leri amper.
- GENEL: J1850 body modul canli veri = servis 32 <pid> 00, cevap 26 <addr> 62 <raw> 00 00.

### Driver Door AKTUATOR testleri (0xA0) -- J1850 body aktuator yontemi
- Header ATSH24A0 2F (aktuator modu 0x2F), sonra 38 <id> 12 -> 26 A0 6F 38 <id> 12 <xx> (6F=2F+40 olumlu).
- Basili tutarken 38 <id> 12 tekrar tekrar gonderiliyor (hold-button).
- 16 aktuator (id 00-0F):
    00 Courtesy Lamp | 01 Front Window Up Relay | 02 Front Window Down Relay
    03 Rear Window Up Relay | 04 Rear Window Down Relay | 05 Lock Relay | 06 Unlock Relay
    07 Mirror Up | 08 Mirror Down | 09 Mirror Left | 0A Mirror Right
    0B Foldaway In | 0C Foldaway Out | 0D Mirror Heater | 0E Switch Illumination | 0F Set Memory LED
- GENEL J1850 body aktuator: ATSH24<addr>2F + 38 <id> 12 (sonu 12, 00 degil!), cevap 26 <addr> 6F 38 <id> 12 <xx>.

### Body Computer komutlari (0x40, J1850)
- AKTUATOR: ATSH2440 2F + 38 <id> <val> -> 26 40 6F 38 <id> <val> <xx>
  Gozlenen: 38 08 01, 38 07 01, 38 02 01, 38 0D 01, 38 08 02; 38 06 <bitmask 02/04/08/10/20> (alt fonksiyonlar)
- KONFIG: ATSH2440 B4 + 28 xx (28 3F 00 -> 26 40 F4 28 3F 00 16); 3A 02 FF -> 26 40 6F 3A 02 FF; 2E 0D 00 (7F 22 sonra 62)
- Isimler (resim): Reset Module, Viper relay, VTSS lamp, Front Fog Lamps, Chime, Hi Beam relay,
  Rear fog lamp relay, Hazard flashers, R Defog relay, HI LOW wiper relay, Park lamp relay, Horn relay,
  Low beam relay, VTSS Mode, Alarm Tripped by, Change Country Code, Disable EU Daylights
- NOT: 28 07 -1 -> "?" WJdiag-Pro BUG (gecersiz "-1"). Tam id->isim eslemesi icin sirali basim gerek.

### Shifter Lever (0x61, J1850)
- Init: ATSP2, ATIFR0, ATH1, ATSH246122, ATRA61
- Okuma: 20 00/01/02, 24 00 -> 26 61 62 ...
- Bizim CLUSTER(0x61)="Gosterge Paneli" YANLIS. 0x61 = Shifter Lever.

### Electro Mech Cluster (0x60, J1850)
- Init: ATSP2, ATIFR0, ATH1, ATSH246022, ATRA60
- Okuma: 20 0B 00 ... (cevaplar firmware airbag-echo yuzunden sahte; adres kesin 0x60)
- ONEMLI: 0x60 = Electro Mech Cluster, bizim app'te YANLIS olarak "Airbag" idi.
- Ozet swap: Airbag=0x58, EMC=0x60 (bizde tersiydi: Airbag=0x60, ESP=0x58).

### Rain Sensor (0xA7, J1850)
- Init: ATSP2, ATIFR0, ATH1, ATSH24A722, ATRAA7
- Okuma: 20 00/01/02, 24 00, 28 01, 2E 10 00 ... -> 26 A7 62 ...
- Silme: ATSH24A714 + FF 00 00 -> 26 A7 54 FF 00 00 (hemen, retry yok)
- SILME KOMUT FARKI: airbag(0x58)=01 00 00 (7 retry), RainSensor(0xA7)=FF 00 00 (hemen). Eski mantik dogru.
