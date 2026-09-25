# Proje durumu — 2026-09-25

Bu dosya, projeye yeni bir oturumda bakan kişinin (veya asistanın) beş dakikada
"neredeyiz, ne değişti, ne bekliyor" sorusuna cevap bulması için tutulur.
Her anlamlı adımda güncellenir; ayrıntı için işaret edilen dosyalara gidilir.

## Araç ve donanım
- 2003 Jeep Grand Cherokee WJ 2.7 CRD Overland (OM612, EDC15C2, NAG1/W5A580), ~700 m rakım (baro ≈ 0,93 bar).
- Adaptör: WiFi ELM327 klon (OBDII v1.5). K-Line: ECU 0x15, TCM 0x20 (KWP2000, SID 81 keepalive, seed 00 00 = kilit yok). Diğer modüller J1850 VPW.
- ECU flaş: MPPS 13.02 + ECM Titanium (sürücü J293_219), Windows 7 x64 VMware sanal makinesinde (USB denetleyici USB 2.0 olmalı; VMware Tools için KB4474419 gerekti).

## ECU yazılımı — araçta yüklü olan
**`ecu-firmware/293-822-EGR-OFF-BOOST.bin`** (SHA-256 `2134716c…0354b885`, 24.09.2026'da flaşlandı). Taban `293-822-egr-off.bin`; ona göre 149 word farklı:
1. Sürücü isteği `0x07750A` — kısmi gazda eco şekillendirme (≤%20 ve %100 pedal stok).
2. Boost hedefi `0x075E68` — 1000–1800 rpm satırları 2400 rpm satırına çekildi (tavan 2250 mbar); VNT kalkışta erken kapanır.
3. Boost tabanlı yakıt sınırlayıcı (duman haritası) `0x076F0A` — 800–2000 rpm × 900–1300 mbar ×1,12, 1400–1500 mbar ×1,06.
4. Checksum 0x7BD7C = 8BE2 E674 (ECM Titanium ile düzeltildi).

Tam tablolar, adresler ve gerekçe: `ecu-firmware/293-822_maps.md` (sondaki "Uygulanan değişiklikler" bölümü). Stok dosya `293-822.bin`, referans `409-438.bin` (2004, aynı kalibrasyon). Diğer .bin'ler başka araçlardan/ticari dosya, kullanılmıyor.

**Sonuç (duman testi 25.09.2026 08:57, sıcak motor):** kalkış yakıtı 26–33 → 36–48 mg/str (1000–2150 rpm), turbo +0,5 bar'a 2,5 s → 1,3 s, boost maks 2,16 bar abs (hedef 2,23), boost açığı ≤0,06 bar, A/F tam yükte 16–17, MAF/teorik = 1,00, rail 1263–1339 bar. 0–100 km/h ECU hızından 15,0 s (12:41 soğuk logda 15,7). Duman yalnızca park hâlinde boş gaz verirken (MAP <1,3 bar'da rpm hızla geçerken) — kabul edilmiş bedel. Tam yük yakıtı ve boost tavanı stok; mekanik zorlanma yok.

**Karar:** yazılım tarafı hedefe ulaştı, başka harita değişikliği planlanmıyor. Sürücü hissi 0–100 <10 s diyor, veri 15 s; çözüm GPS ile bağımsız ölçüm (bkz. Yapılacaklar). Stage-1 (+%15–20 tam yük) istenirse ayrı dosya olarak yapılır; beklenti 12,5–13 s, duman/EGT/şanzıman yükü artar.

## Uygulamalar
- `ios-app/` SwiftUI (iPhone, Mac'te derlenir), `qt-app/` Qt6 masaüstü, `esp32-emulator/` ELM327+ECU+TCM emülatörü (PlatformIO). Blok yerleşimleri gerçek araç loglarından doğrulandı: README "Block layout" tabloları ve `docs/RELAY_MAP.md`.
- iOS duman testi: 0x36/0x28 hızlı + yavaş blok round-robin, özet (çekişler, A/F, spool, 0–60/80/100), CSV.

## Commit bekleyen değişiklikler (25.09.2026, derlenmedi!)
`git status`: README.md, esp32-emulator/src/elm327_emu.cpp, ios SmokeTest.swift, ios WJDiagnostics.swift, qt mainwindow.cpp, qt wjdiagnostics.cpp.
- **Akü voltajı 13,3 ↔ 8,4 V zıplaması:** TCM bloğu 0x34 [8-9] "akü /154,5" diye eşlenmişti; gerçekte oturum boyunca sabit (0x0504 → "8,3 V"), akü değil. Eşleme kaldırıldı, akü yalnızca ATRV'den (iOS + Qt + README + emülatör yorumu).
- **Transmission "BUS INIT: ERROR":** Connection ekranında TCM seçilip Dashboard'da Start basılınca uygulama açık oturum üstüne yeniden ATZ+ATFI gönderiyordu; TCM P3max (~5 s) dolmadan 5-baud init'i yok sayar. Düzeltme: `startECULiveData/startTCMLiveData/startSmokeTest` → `ensureModule` (oturum açıksa init yok); K-Line→K-Line modül geçişinde önce SID 82 + 0,6 s; ERROR'da 5,5 s sonra bir otomatik tekrar (`runKLineInit`, log: `[INIT] …`).
- **Duman özeti A/F bayrağı:** gaza basılan ilk 0,5 s'de MAF geride kaldığı için "A/F 12,5 kara duman" yanlış bayrağı çıkıyordu; tip-in ayrı satır, bayraksız.
Önerilen commit mesajı: `fix: TCM re-init on open session, 0x34[8-9] is not battery, smoke A/F tip-in`.

## Yapılacaklar
1. Mac'te iOS build; araçta Transmission seç → Dashboard Start: hatasız okuma + BATT sabit 13,x → commit.
2. GPS ile 0–100 doğrulaması: ya telefonda GPS uygulaması ile aynı çekiş, ya iOS uygulamasına CoreLocation `gps_kmh` sütunu + özette "ECU vs GPS" (≈1 saat iş).
3. İki depo dolumuyla tüketim ölçümü (beklenti karışık 10–11 l/100 km, eco haritanın katkısı %3–5).
4. Opsiyonel: `WJKEY.keystore` git geçmişinde duruyor (`git filter-repo`), `.gitignore`'da zaten var.

## Bilinen kısıtlar
- ELM klon: K-Line blok okuması ~0,28 s; duman testinde 1–2 s'lik örnekleme boşlukları (adaptör takılması) olabilir, özet raporlar.
- 0x36[0-1] işaretli küçük kelime pedal DEĞİL (pedal [12-13]); 0x12[0-1] soğutma suyu, rpm [10-11]. 0x34[8-9] bilinmiyor.
- ECM Titanium'un "injection at part throttle (Boost×RPM)" etiketli 16×20 haritaları enjektör açma süresidir (rail × mg → µs); dokunulmaz.
