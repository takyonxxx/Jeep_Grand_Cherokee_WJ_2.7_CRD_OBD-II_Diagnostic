# WJ Diag — Jeep Grand Cherokee WJ 2.7 CRD Android teşhis uygulaması

iOS `JeepWJDiag` uygulamasının ve `WJdiag-Pro.apk`'nın işlevlerini kapsayan, Gradle'siz derlenen,
imzalı Android uygulaması + Android emülatörüyle konuşan PC simülatörü.

```
android-app/
├── WJDiag.apk            imzalı APK (com.wjdiag.pro, minSdk 21, targetSdk 28)
├── android/              kaynak kod + build.ps1 + wjdiag.jks (şifre: wjdiag2026, alias: wjdiag)
│   ├── src/com/wjdiag/pro/
│   │   ├── Elm327.java       TCP/BT/BLE bağlantı, seri komut kuyruğu, '>' çerçeveleme, J1850 gürültü filtresi, NRC 21 tekrar
│   │   ├── Transports.java   WiFi TCP, Bluetooth SPP (RFCOMM), BLE (FFF0/FFF1/FFF2)
│   │   ├── Kwp2000.java      K-Line init dizileri, ArvutaKoodi güvenlik, DTC oku/sil, J1850 başlık/aktüatör
│   │   ├── WJDiag.java       orkestratör: modül init (SID 82 kapatma, P3max tekrar), SID 81 keepalive,
│   │   │                      ECU/TCM canlı veri + blok çözümleme, DTC, duman testi zinciri
│   │   ├── SmokeTest.java    kara duman testi oturumu, analiz, CSV + WhatsApp raporu
│   │   ├── Models.java       20 modül haritası, EcuStatus/TcmStatus, byte yardımcıları
│   │   ├── DtcNames.java     DTC açıklamaları (TR)
│   │   └── MainActivity.java arayüz (6 sekme)
│   ├── res/                  layout/main.xml, values/styles.xml (koyu tema, turuncu vurgu), drawable, ikon
│   └── AndroidManifest.xml
└── sim/
    ├── wjdiag_sim.py     ESP32 ELM327 emülatörünün PC portu (TCP 35000)
    └── j1850_db.json     gerçek araçtan yakalanmış 275 J1850 yanıtı
```

## Derleme

```powershell
cd C:\Users\turka\Desktop\Jeep_Grand_Cherokee_WJ_2.7_CRD_OBD-II_Diagnostic\android-app\android
.\build.ps1          # aapt2 + javac + d8 + zipalign + apksigner -> ..\WJDiag.apk
```

SDK: `%LOCALAPPDATA%\Android\Sdk` (build-tools 37.0.0, android-36), JDK: Android Studio jbr.

## Simülatör + emülatör testi

```powershell
python C:\Users\turka\Desktop\Jeep_Grand_Cherokee_WJ_2.7_CRD_OBD-II_Diagnostic\android-app\sim\wjdiag_sim.py            # gerçek araç zamanlaması
python C:\Users\turka\Desktop\Jeep_Grand_Cherokee_WJ_2.7_CRD_OBD-II_Diagnostic\android-app\sim\wjdiag_sim.py --fast     # anlık yanıt
python C:\Users\turka\Desktop\Jeep_Grand_Cherokee_WJ_2.7_CRD_OBD-II_Diagnostic\android-app\sim\wjdiag_sim.py --smoke 0  # sağlıklı motor senaryosu (0-3)
```

Uygulamada **PC Simülatör** düğmesi host'u `10.0.2.2:35000` yapar (emülatörden PC'ye giden adres).
Gerçek telefonda aynı ağdaki PC için PC'nin IP'sini yazın. Simülatör ESP32 emülatörüyle aynı
davranır: 40 sn'lik sürüş döngüsü (rölanti → tam gaz 4000 rpm → iki darbe), `ATSMOKE0-3`
arıza senaryoları, `ATSIMDELAY0/1` zamanlama, gerçek ELM327 kablo formatı (ATZ'de 0xFC, ATFI iki parça).

```powershell
adb install -r C:\Users\turka\Desktop\Jeep_Grand_Cherokee_WJ_2.7_CRD_OBD-II_Diagnostic\android-app\WJDiag.apk
```

## Gerçek araçla kullanım

* **WiFi ELM327**: telefonu `WiFi_OBDII` ağına bağla, host `192.168.0.10`, port `35000`, **Bağlan**.
* **Bluetooth**: *Bluetooth* düğmesi → eşleşmiş SPP cihazı seç (OBDII, V-LINK…) ya da *BLE tara*
  (iOS-Vlink, LELink; BLE için konum izni istenir).
* **Bağlantı** sekmesi: modül listesinden seç (ECU/TCM K-Line init + güvenlik, diğerleri J1850).
  ECU/TCM seçiliyken **Canlı Başlat** 14 (+4 güvenlik) / 5 blok döngüsüyle göstergeleri doldurur;
  akü voltajı her tur sonunda `ATRV` ile okunur. Seçili K-Line modülü SID 81 ile canlı tutulur.
* **DTC**: TCM/ECU (SID 18/14), ABS/ESP/BCM/Yağmur/Airbag (J1850 mod 0x22 PID taraması, ESP silme 10 deneme).
  Airbag (ORC, 0x60) WJdiag-Pro ile aynı yöntem: `ATSH246022` + `2E xx 00` (B10xx ↔ PID xx), silme mod 0x14 `FF 00 00`.
  Gerçek araç kaydında 0x60 yalnızca `7F 22 22` ile görülmüştü; airbag PID yanıtları araçta doğrulanmadı.
  DTC sekmesindeki **"Airbag arıza kodlarını her 5 saniyede otomatik sil"** seçeneği işaretliyken uygulama
  5 sn periyotla `ATSH246014` + `FF 00 00` gönderir (sayaç durum satırında); canlı veri durdurulur, Oku/Sil pasifleşir,
  bağlantı kopunca kendini kapatır.
* **Kontrol**: kapı camları/aynalar/kilit ve BCM röleleri — basılı tut = AÇ, bırak = KAPA
  (`38 xx 12` / `38 xx 00`; OFF'a NO DATA gelirse 3 kez tekrarlanır).
* **Aktüatör**: seçili modülün tüm testleri (ECU SID 30, TCM 31/30, gösterge 3A, klima, SKIM, tavan, ABS).
* **Duman Testi**: ECU'yu kendisi başlatır, `ATAT2`/`ATST 19` ile hızlı okuma (0x36, 0x28 her tur,
  0x12/0x26/0x21/0x32/0x37/0x20/0x23 sırayla), İŞARET ile duman anı, bitince özet + bayraklar,
  WhatsApp / dosya / pano paylaşımı (dosya: `Android/data/com.wjdiag.pro/files/SmokeTest_*.txt`).
* **Log**: tüm TX/RX; ham komut gönderme (`ATRV`, `21 12`, `ATSMOKE2`…).

Tüm blok ofsetleri/formüller `docs/RELAY_MAP.md` ve iOS `WJDiagnostics.swift` ile birebirdir; tek fark:

**Blok 0x28 enjeksiyon düzeltmeleri = 5 silindir, bayt [16-25].** Gerçek araç kayıtlarındaki üç 0x28
çerçevesinde (`pcap/full_modules.pcap`) [16-25]'teki beş işaretli kelime her seferinde ≈0'a toplanıyor
(0016 0011 FF72 0036 002F → +0.22 +0.17 −1.42 +0.54 +0.47 = −0.02 mg). Rölanti düzgünlük kontrolü yakıtı
silindirler arasında yeniden dağıttığı için düzeltmelerin toplamı sıfırdır; RELAY_MAP'teki "[16-17] sabit,
[18-19] değişken" aslında 1. ve 2. silindirdir (Qt ve iOS uygulamaları yalnızca 3 silindir gösterir,
WJdiag-Pro 5 gösterir). Bu uygulama ve simülatör 5 düzeltme kullanır. **Değerler yalnızca ECU rutini 0x25 çalışırken dolar:** pcap'te ticari
uygulama `31 25 00` → `71 25 00` gönderip sonra `21 28` okuyor, bitince `32 25`. Uygulama canlı veri ve duman testi
başlarken rutini başlatır, dururken kapatır; gösterge son rölanti değerini tutar (sürüşte ECU sıfır yollar).
