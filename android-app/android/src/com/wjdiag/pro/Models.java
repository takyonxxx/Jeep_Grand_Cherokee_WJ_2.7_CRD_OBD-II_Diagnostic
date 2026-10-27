package com.wjdiag.pro;

import java.util.ArrayList;
import java.util.List;

/** Data model: verified WJ 2.7 CRD module map and the ECU / TCM live-data status (from RELAY_MAP.md). */
public final class Models {
    private Models() {}

    public enum Bus { KLINE, J1850 }

    /** The 20 verified WJ modules. */
    public enum WJModule {
        MOTOR_ECU(0x15, Bus.KLINE, "Motor ECU (EDC15C2)", "K-Line 0x15 | EDC15C2 | 14 blok + 9 aktüatör"),
        KLINE_TCM(0x20, Bus.KLINE, "Şanzıman (NAG1)", "K-Line 0x20 | NAG1 722.6 | 5 blok + 4 test"),
        ABS(0x28, Bus.J1850, "ABS", "J1850 0x28 | 12 valf testi"),
        SHIFTER_LEVER(0x61, Bus.J1850, "Shifter Lever (Vites Seçici)", "J1850 0x61 | vites seçici P/R/N/D"),
        SKIM(0xC0, Bus.J1850, "SKIM / Immobilizer", "J1850 0xC0 | VIN + anahtar"),
        BODY_COMPUTER(0x40, Bus.J1850, "Body Computer (BCM)", "J1850 0x40 | 14 röle"),
        ATC(0x98, Bus.J1850, "Klima / ATC", "J1850 0x98 | 10 motor testi"),
        DRIVER_DOOR(0xA0, Bus.J1850, "Sürücü Kapısı", "J1850 0xA0 | 16 aktüatör"),
        PASSENGER_DOOR(0xA1, Bus.J1850, "Yolcu Kapısı", "J1850 0xA1 | 15 aktüatör"),
        AIRBAG(0x58, Bus.J1850, "Airbag (ORC)", "J1850 0x58 | 2E/2F tarama + 01 00 00 sil"),
        ELECTRO_MECH_CLUSTER(0x60, Bus.J1850, "Electro Mech Cluster", "J1850 0x60 | gösterge modülü"),
        OVERHEAD(0x68, Bus.J1850, "Tavan Konsolu", "J1850 0x68"),
        NAVIGATION(0x6D, Bus.J1850, "Navigasyon", "J1850 0x6D"),
        RADIO(0x80, Bus.J1850, "Radyo", "J1850 0x80 | NO DATA"),
        CD_CHANGER(0x81, Bus.J1850, "CD Değiştirici", "J1850 0x81"),
        PARK_ASSIST(0x62, Bus.J1850, "Park Sensörü", "J1850 0x62"),
        RAIN_SENSOR(0xA7, Bus.J1850, "Yağmur Sensörü", "J1850 0xA7"),
        ADJUSTABLE_PEDAL(0x2A, Bus.J1850, "Ayarlanabilir Pedal", "J1850 0x2A | NO DATA"),
        SAT_AUDIO(0x87, Bus.J1850, "Uydu Radyo", "J1850 0x87"),
        HANDS_FREE(0x90, Bus.J1850, "Hands Free", "J1850 0x90");

        public final int addr;
        public final Bus bus;
        public final String displayName;
        public final String detail;

        WJModule(int addr, Bus bus, String name, String detail) {
            this.addr = addr; this.bus = bus; this.displayName = name; this.detail = detail;
        }

        public String hex() { return String.format("%02X", addr); }
        public boolean isNoData() { return this == RADIO || this == ADJUSTABLE_PEDAL; }
    }

    public static final class DtcEntry {
        public final WJModule module;
        public final String code;
        public final String description;
        public DtcEntry(WJModule m, String c, String d) { module = m; code = c; description = d; }
    }

    /** Actuator button definition: hold (on/off) when offCmd != null, pulse otherwise. */
    public static final class ActDef {
        public final String name, onCmd, offCmd, hdr;
        public ActDef(String name, String onCmd, String offCmd, String hdr) {
            this.name = name; this.onCmd = onCmd; this.offCmd = offCmd; this.hdr = hdr;
        }
    }

    /** ECU live data (block offsets / formulas verified on the real vehicle). */
    public static final class EcuStatus {
        public double rpm, coolantTemp, boostPressure, railPressure, mafFlow, fuelQuantity;
        public double batteryVoltage, vehicleSpeed, fuelLevel, fuelSensorVoltage, injectionQty;
        public double[] cylRPMs = new double[5];
        public double[] injCorrections = new double[5];   // 0x28[16-25]: 5 signed words, sum ~0 (real car)
        public boolean injCorrLive;      // true = values from the current (idle) read, false = held from the last idle
        public long injCorrAt;           // ms timestamp of the last idle read
        public double fuelFlowLH, fuelLPer100km;
        public double pedalPos;
        public int gear;
        public double blk36signed, blk36torque, boostSetpoint, blk36c, iat, mapActual;
        public double[] fuelQty21 = new double[7];
        public double egrMafSetpoint, wastegateRaw, blk20a, blk20b, blk23a, blk23g;
        // security / calibration blocks
        public double egrDuty, wastegateDuty;
        public double fuelRaw14;        // block 0x21[14-15] raw (ECU "fuel level" word, often ~constant)
        public double fuelPctCalibrated; // from sensor voltage via user calibration (-1 = not calibrated)
        public String vin = "";

        public EcuStatus copy() {
            EcuStatus c = new EcuStatus();
            c.rpm = rpm; c.coolantTemp = coolantTemp; c.boostPressure = boostPressure; c.railPressure = railPressure;
            c.mafFlow = mafFlow; c.fuelQuantity = fuelQuantity; c.batteryVoltage = batteryVoltage; c.vehicleSpeed = vehicleSpeed;
            c.fuelLevel = fuelLevel; c.fuelSensorVoltage = fuelSensorVoltage; c.injectionQty = injectionQty;
            c.cylRPMs = cylRPMs.clone(); c.injCorrections = injCorrections.clone();
            c.fuelFlowLH = fuelFlowLH; c.fuelLPer100km = fuelLPer100km; c.pedalPos = pedalPos; c.gear = gear;
            c.blk36signed = blk36signed; c.blk36torque = blk36torque; c.boostSetpoint = boostSetpoint; c.blk36c = blk36c;
            c.iat = iat; c.mapActual = mapActual; c.fuelQty21 = fuelQty21.clone();
            c.egrMafSetpoint = egrMafSetpoint; c.wastegateRaw = wastegateRaw; c.blk20a = blk20a; c.blk20b = blk20b;
            c.blk23a = blk23a; c.blk23g = blk23g; c.egrDuty = egrDuty; c.wastegateDuty = wastegateDuty; c.vin = vin;
            return c;
        }
    }

    public enum Gear {
        PARK("P"), REVERSE("R"), NEUTRAL("N"), D1("D1"), D2("D2"), D3("D3"), D4("D4"), D5("D5"), LIMP("LIMP!"), UNKNOWN("?");
        public final String label;
        Gear(String l) { label = l; }
        public boolean isDrive() { return this == D1 || this == D2 || this == D3 || this == D4 || this == D5; }
    }

    /** TCM live data. */
    public static final class TcmStatus {
        public Gear gear = Gear.UNKNOWN;
        public int selector;
        public double actualTCCSlip, desiredTCCSlip, outputRPM, transTemp, turbineRPM, engineRPM, inputN2;
        public double solenoidVoltage, sensorSupply, batteryVoltage, vehicleSpeed;
        public double tccPressure, shiftPressure, modulationPressure;
    }

    // ---- byte helpers
    public static int u16(byte[] d, int off) {
        if (off + 1 >= d.length) return 0;
        return ((d[off] & 0xFF) << 8) | (d[off + 1] & 0xFF);
    }
    public static int s16(byte[] d, int off) { return (short) u16(d, off); }

    /** Hex byte tokens of a response, ignoring non-hex text such as "NO DATA". */
    public static List<String> tokens(String s) {
        List<String> out = new ArrayList<>();
        if (s == null) return out;
        for (String tok : s.replace('\r', ' ').replace('\n', ' ').split(" ")) {
            if (tok.length() == 2 && isHex(tok.charAt(0)) && isHex(tok.charAt(1))) out.add(tok.toUpperCase());
        }
        return out;
    }
    public static boolean isHex(char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }
    public static byte[] hexToBytes(String hex) {
        if (hex == null) return new byte[0];
        List<String> t = tokens(hex);
        byte[] out = new byte[t.size()];
        for (int i = 0; i < t.size(); i++) out[i] = (byte) Integer.parseInt(t.get(i), 16);
        return out;
    }
    /** Negative response "7F <sid> <code>" anywhere in the response (token match). */
    public static boolean hasNRC(String s, int code) {
        List<String> t = tokens(s);
        String c = String.format("%02X", code);
        for (int i = 0; i + 2 < t.size(); i++) if (t.get(i).equals("7F") && t.get(i + 2).equals(c)) return true;
        return false;
    }
    public static boolean hasToken(String s, int b) { return tokens(s).contains(String.format("%02X", b)); }

    public static int findPayload(byte[] b, int m1, int m2) {
        for (int i = 0; i + 1 < b.length; i++) if ((b[i] & 0xFF) == m1 && (b[i + 1] & 0xFF) == m2) return i;
        return -1;
    }
}
