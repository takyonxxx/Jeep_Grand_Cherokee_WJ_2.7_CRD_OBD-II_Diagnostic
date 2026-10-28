package com.wjdiag.pro;

import java.util.HashMap;
import java.util.Map;

/** Short Turkish descriptions for the DTCs seen on the WJ 2.7 CRD (plus generic prefixes). */
public final class DtcNames {
    private DtcNames() {}
    private static final Map<String, String> M = new HashMap<>();
    static {
        M.put("P0702", "Şanzıman kontrol sistemi elektrik arızası");
        M.put("P0701", "Şanzıman kontrol sistemi aralık/performans");
        M.put("P0700", "Şanzıman kontrol sistemi (MIL isteği)");
        M.put("P0715", "Giriş/türbin devir sensörü devresi");
        M.put("P0720", "Çıkış devir sensörü devresi");
        M.put("P0730", "Yanlış vites oranı");
        M.put("P0740", "Tork konvertör kavrama devresi");
        M.put("P0741", "TCC performans / takılı açık");
        // NAG1 722.6 şanzıman kodları (WJdiag-Pro GearBoxFaultDiisel adlarıyla, araç/pcap'te doğrulanan P2210 dahil)
        M.put("P2210", "ID 17 Shifter signal invalid");  // gerçek araç: 58 01 22 10 20
        M.put("P0703", "Fren anahtarı B devresi");
        M.put("P0705", "Vites konum sensörü (PRNDL) devresi");
        M.put("P0706", "Vites konum sensörü aralık/performans");
        M.put("P0710", "Şanzıman yağ sıcaklık sensörü devresi");
        M.put("P0712", "Şanzıman yağ sıcaklık sensörü düşük");
        M.put("P0713", "Şanzıman yağ sıcaklık sensörü yüksek");
        M.put("P0716", "Giriş/türbin devir sensörü aralık/performans");
        M.put("P0731", "Vites 1 oranı yanlış");
        M.put("P0732", "Vites 2 oranı yanlış");
        M.put("P0733", "Vites 3 oranı yanlış");
        M.put("P0734", "Vites 4 oranı yanlış");
        M.put("P0735", "Vites 5 oranı yanlış");
        M.put("P0743", "TCC kavrama solenoid elektrik");
        M.put("P0748", "Basınç kontrol solenoidi elektrik");
        M.put("P0751", "Shift solenoid A performans / takılı");
        M.put("P0753", "Shift solenoid A elektrik");
        M.put("P0756", "Shift solenoid B performans / takılı");
        M.put("P0758", "Shift solenoid B elektrik");
        M.put("P0100", "Hava kütle ölçer (MAF) devresi");
        M.put("P0101", "MAF aralık/performans");
        M.put("P0105", "MAP / barometrik basınç devresi");
        M.put("P0110", "Emme havası sıcaklık sensörü");
        M.put("P0115", "Motor soğutma suyu sıcaklık sensörü");
        M.put("P0120", "Gaz pedalı konum sensörü");
        M.put("P0190", "Yakıt rail basınç sensörü");
        M.put("P0191", "Rail basıncı aralık/performans");
        M.put("P0234", "Turbo aşırı basınç");
        M.put("P0235", "Turbo basınç sensörü devresi");
        M.put("P0299", "Turbo düşük basınç (underboost)");
        M.put("P0201", "Silindir 1 enjektör devresi");
        M.put("P0202", "Silindir 2 enjektör devresi");
        M.put("P0203", "Silindir 3 enjektör devresi");
        M.put("P0204", "Silindir 4 enjektör devresi");
        M.put("P0205", "Silindir 5 enjektör devresi");
        M.put("P0335", "Krank mili konum sensörü");
        M.put("P0340", "Eksantrik mili konum sensörü");
        M.put("P0380", "Kızdırma bujisi 1 röle devresi");
        M.put("P0381", "Kızdırma bujisi 2 röle devresi");
        M.put("P0400", "EGR akış arızası");
        M.put("P0401", "EGR akışı yetersiz");
        M.put("P0403", "EGR solenoid kontrol devresi");
        M.put("P0460", "Yakıt seviye sensörü devresi");
        M.put("P0500", "Araç hız sensörü");
        M.put("P0645", "A/C kompresör kavrama rölesi devresi");
        M.put("P2120", "Gaz pedalı konum sensörü 1 devresi");
        M.put("P2125", "Gaz pedalı konum sensörü 2 devresi");
        M.put("P0560", "Sistem voltajı");
        M.put("P0562", "Sistem voltajı düşük");
        M.put("P0563", "Sistem voltajı yüksek");
        M.put("P1D44", "EDC15 iç hata");
        M.put("C0031", "LF tekerlek hız sensörü devresi");
        M.put("C0032", "LF tekerlek hız sensörü aralık");
        M.put("C0035", "RF tekerlek hız sensörü devresi");
        M.put("C0036", "RF tekerlek hız sensörü aralık");
        M.put("C0041", "LR tekerlek hız sensörü devresi");
        M.put("C0042", "LR tekerlek hız sensörü aralık");
        M.put("C0045", "RR tekerlek hız sensörü devresi");
        M.put("C0046", "RR tekerlek hız sensörü aralık");
        M.put("C0051", "Direksiyon açı sensörü");
        M.put("C0060", "Yanal ivme sensörü");
        M.put("C0070", "Yaw sensörü");
        M.put("C0080", "ABS pompa motoru");
        M.put("C0081", "ABS pompa rölesi");
        M.put("C0085", "ABS valf rölesi");
        M.put("C0110", "ABS pompa motoru devresi");
        M.put("C0111", "ABS pompa motoru hız");
        M.put("C1014", "ABS kontrol modülü iç hata");
        M.put("C2103", "ESP: hız sensörü sinyal hatası");
        M.put("B1A00", "Body: iç hata / EEPROM");
        M.put("B1A10", "Body: haberleşme hatası");
        M.put("B2100", "Body: kapı kilit devresi");
        M.put("B2101", "Body: kapı kilit rölesi");
        M.put("B2102", "Body: kilit açma rölesi");
        M.put("B2200", "Body: aydınlatma devresi");
        M.put("B2300", "Body: korna rölesi");
        // Airbag / ORC (0x60)
        M.put("B1000", "Airbag lambası sürücü devresi arızası");
        M.put("B1001", "Airbag lambası devresi açık");
        M.put("B1010", "Sürücü squib 1 devresi açık");
        M.put("B1011", "Sürücü squib 1 kısa devre");
        M.put("B1012", "Sürücü squib 1 aküye kısa");
        M.put("B1013", "Sürücü squib 1 şaseye kısa");
        M.put("B1014", "Sürücü squib 2 devresi açık");
        M.put("B1015", "Sürücü squib 2 kısa devre");
        M.put("B1016", "Sürücü squib 2 aküye kısa");
        M.put("B1017", "Sürücü squib 2 şaseye kısa");
        M.put("B1020", "Yolcu squib 1 devresi açık");
        M.put("B1021", "Yolcu squib 1 kısa devre");
        M.put("B1022", "Yolcu squib 1 aküye kısa");
        M.put("B1023", "Yolcu squib 1 şaseye kısa");
        M.put("B1024", "Yolcu squib 2 devresi açık");
        M.put("B1025", "Yolcu squib 2 kısa devre");
        M.put("B1026", "Yolcu squib 2 aküye kısa");
        M.put("B1027", "Yolcu squib 2 şaseye kısa");
        M.put("B1030", "Sürücü perde airbag squib devresi açık");
        M.put("B1031", "Sürücü perde airbag squib aküye kısa");
        M.put("B1032", "Sürücü perde airbag squib şaseye kısa");
        M.put("B1033", "Yolcu perde airbag squib devresi açık");
        M.put("B1034", "Yolcu perde airbag squib kısa devre");
        M.put("B1035", "Yolcu perde airbag squib aküye kısa");
        M.put("B1036", "Yolcu perde airbag squib şaseye kısa");
        M.put("B1040", "Sürücü yan darbe sensörü iç arıza");
        M.put("B1041", "Sürücü yan darbe sensörü haberleşme yok");
        M.put("B1042", "Yolcu yan darbe sensörü iç arıza");
        M.put("B1043", "Yolcu yan darbe sensörü haberleşme yok");
        M.put("B1050", "Sürücü emniyet kemeri anahtarı devresi açık");
        M.put("B1051", "Sürücü emniyet kemeri anahtarı aküye kısa");
        M.put("B1052", "Sürücü emniyet kemeri anahtarı şaseye kısa");
        M.put("B1053", "Yolcu emniyet kemeri anahtarı devresi açık");
        M.put("B1054", "Yolcu emniyet kemeri anahtarı aküye kısa");
        M.put("B1055", "Yolcu emniyet kemeri anahtarı şaseye kısa");
        M.put("U0001", "Yüksek hızlı CAN/bus hatası");
        M.put("U0010", "Orta hızlı bus hatası");
    }
    public static String describe(String code) {
        String d = M.get(code);
        if (d != null) return d;
        if (code == null || code.isEmpty()) return "";
        switch (code.charAt(0)) {
            case 'P': return "Motor / şanzıman arıza kodu";
            case 'C': return "Şasi (ABS/ESP) arıza kodu";
            case 'B': return "Karoser arıza kodu";
            case 'U': return "Haberleşme arıza kodu";
            default: return "";
        }
    }
}
