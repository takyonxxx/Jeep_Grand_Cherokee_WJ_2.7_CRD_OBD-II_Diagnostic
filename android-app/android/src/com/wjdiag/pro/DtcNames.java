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
        M.put("P0335", "Krank mili konum sensörü");
        M.put("P0340", "Eksantrik mili konum sensörü");
        M.put("P0380", "Kızdırma bujisi devresi");
        M.put("P0400", "EGR akış arızası");
        M.put("P0401", "EGR akışı yetersiz");
        M.put("P0500", "Araç hız sensörü");
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
