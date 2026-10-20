package com.wjdiag.pro;

import android.os.Handler;
import android.os.Looper;

import com.wjdiag.pro.Models.WJModule;

import java.util.List;

/** KWP2000 (K-Line) + J1850 helpers: verified init sequences, ArvutaKoodi security, DTC, actuators. */
public final class Kwp2000 {

    public interface BoolCb { void on(boolean ok); }

    private static final int[] T1 = {0xC0,0xD0,0xE0,0xF0,0x00,0x10,0x20,0x30,0x40,0x50,0x60,0x70,0x80,0x90,0xA0,0xB0};
    private static final int[] T2 = {0x02,0x03,0x00,0x01,0x06,0x07,0x04,0x05,0x0A,0x0B,0x08,0x09,0x0E,0x0F,0x0C,0x0D};
    private static final int[] T3 = {0x90,0x80,0xF0,0xE0,0xD0,0xC0,0x30,0x20,0x10,0x00,0x70,0x60,0x50,0x40,0xB0,0xA0};
    private static final int[] T4 = {0x0D,0x0C,0x0F,0x0E,0x09,0x08,0x0B,0x0A,0x05,0x04,0x07,0x06,0x01,0x00,0x03,0x02};

    private final Elm327 conn;
    private final Handler h = new Handler(Looper.getMainLooper());

    public Kwp2000(Elm327 c) { conn = c; }

    private void log(String s) { conn.log(s); }

    // ------------------------------------------------------------------ init

    /** ECU 0x15: ATZ ATZ ATE1 ATH1 ATWM8115F13E ATSH8115F1 ATSP5 ATFI 81 */
    public void initECU(final BoolCb cb) {
        String[] cmds = {"ATZ", "ATZ", "ATE1", "ATH1", "ATWM8115F13E", "ATSH8115F1", "ATSP5"};
        sendSequence(cmds, 0, new Runnable() { @Override public void run() { busInit("ECU 0x15", cb); } });
    }

    /** TCM 0x20: double ATWM for reliability. */
    public void initTCM(final BoolCb cb) {
        String[] cmds = {"ATZ", "ATZ", "ATE1", "ATH1", "ATWM8120F13E", "ATWM8120F13E", "ATSH8120F1", "ATSP5"};
        sendSequence(cmds, 0, new Runnable() { @Override public void run() { busInit("TCM 0x20", cb); } });
    }

    private void busInit(final String name, final BoolCb cb) {
        conn.sendCommand("ATFI", 5000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                conn.sendCommand("81", 3000, new Elm327.Callback() {
                    @Override public void onResponse(String r2) {
                        boolean ok = Models.hasToken(r2, 0xC1) || r2.contains("BUS INIT: OK");
                        log(name + " K-Line init " + (ok ? "OK" : "BAŞARISIZ: " + r2));
                        cb.on(ok);
                    }
                });
            }
        });
    }

    /** J1850 VPW: ATZ ATZ ATSP2 ATIFR0 ATH1 ATSH24xx22 ATRAxx */
    public void initJ1850(WJModule m, final BoolCb cb) {
        final String a = m.hex();
        String[] cmds = {"ATZ", "ATZ", "ATSP2", "ATIFR0", "ATH1", "ATSH24" + a + "22", "ATRA" + a};
        sendSequence(cmds, 0, new Runnable() { @Override public void run() { log("J1850 init OK 0x" + a); cb.on(true); } });
    }

    private void sendSequence(final String[] cmds, final int i, final Runnable done) {
        if (i >= cmds.length) { done.run(); return; }
        conn.sendCommand(cmds[i], 3000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                h.postDelayed(new Runnable() { @Override public void run() { sendSequence(cmds, i + 1, done); } }, 150);
            }
        });
    }

    // ------------------------------------------------------------------ security

    /** ECU security: seed 00 00 = already unlocked (no key sent). */
    public void securityUnlockECU(final BoolCb cb) {
        conn.sendCommand("27 01", 3000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                byte[] b = Models.hexToBytes(r);
                int idx = -1;
                for (int i = 0; i + 1 < b.length; i++) if ((b[i] & 0xFF) == 0x67 && (b[i + 1] & 0xFF) == 0x01) { idx = i; break; }
                if (idx < 0) { cb.on(false); return; }
                if (idx + 3 < b.length) {
                    int hi = b[idx + 2] & 0xFF, lo = b[idx + 3] & 0xFF;
                    if (hi == 0 && lo == 0) { log("ECU seed=0000, zaten açık"); cb.on(true); return; }
                    int[] key = arvutaKoodi(hi, lo);
                    conn.sendCommand(String.format("27 02 %02X %02X", key[0], key[1]), 3000, new Elm327.Callback() {
                        @Override public void onResponse(String r2) { cb.on(r2.contains("67 02") || r2.contains("6702")); }
                    });
                } else if (idx + 2 < b.length && b[idx + 2] == 0) cb.on(true);
                else cb.on(false);
            }
        });
    }

    /** TCM: static seed 68 24 89 -> key CC 21 */
    public void securityUnlockTCM(final BoolCb cb) {
        conn.sendCommand("27 01", 3000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                conn.sendCommand("27 02 CC 21", 3000, new Elm327.Callback() {
                    @Override public void onResponse(String r2) { cb.on(r2.contains("67 02")); }
                });
            }
        });
    }

    static int[] arvutaKoodi(int seedHi, int seedLo) {
        int v1 = (seedLo + 0x0B) & 0xFF;
        int keyLo = T1[(v1 >> 4) & 0xF] | T2[v1 & 0xF];
        int cond = seedLo > 0x34 ? 1 : 0;
        int v2 = (seedHi + cond + 1) & 0xFF;
        int keyHi = T3[(v2 >> 4) & 0xF] | T4[v2 & 0xF];
        return new int[]{keyHi, keyLo};
    }

    // ------------------------------------------------------------------ data

    /** K-Line keepalive = SID 0x81 (NOT 0x3E). */
    public void sendKeepalive() { conn.sendCommand("81", 2000, null); }

    public void readBlock(int block, Elm327.Callback cb) { conn.sendCommand(String.format("21 %02X", block), 3000, cb); }

    public void readDTCs(WJModule m, Elm327.Callback cb) {
        conn.sendCommand(m == WJModule.KLINE_TCM ? "18 02 FF 00" : "18 02 00 00", 8000, cb);
    }

    /** 14 00 00 -> 54 00 00; TCM may answer 7F 14 78 first, the deferred 54 comes with the next read. */
    public void clearDTCs(final WJModule m, final BoolCb cb) {
        final String readCmd = m == WJModule.KLINE_TCM ? "18 02 FF 00" : "18 02 00 00";
        conn.sendCommand("14 00 00", 8000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                if (Models.hasToken(r, 0x54)) { cb.on(true); return; }
                if (!Models.hasNRC(r, 0x78)) { cb.on(false); return; }
                log("DTC silme: response pending (0x78), 54 bekleniyor");
                h.postDelayed(new Runnable() { @Override public void run() {
                    conn.sendCommand(readCmd, 8000, new Elm327.Callback() {
                        @Override public void onResponse(String r2) {
                            List<String> t = Models.tokens(r2);
                            boolean ok = t.contains("54");
                            int i = t.indexOf("58");
                            if (i >= 0 && i + 1 < t.size() && t.get(i + 1).equals("00")) ok = true;
                            cb.on(ok);
                        }
                    });
                } }, 1500);
            }
        });
    }

    // ------------------------------------------------------------------ J1850

    public void setJ1850Header(WJModule m, int mode, final Runnable done) {
        String hdr = String.format("ATSH24%02X%02X", m.addr, mode);
        String filter = String.format("ATRA%02X", m.addr);
        conn.sendCommand(hdr, 1000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                conn.sendCommand(filter, 1000, new Elm327.Callback() {
                    @Override public void onResponse(String r2) { if (done != null) done.run(); }
                });
            }
        });
    }

    /** ESP 0x58 uses "01 00 00" and needs up to 10 attempts; others "FF 00 00". */
    public void clearJ1850DTCs(final WJModule m, final BoolCb cb) {
        final String clearCmd = m == WJModule.ESP ? "01 00 00" : "FF 00 00";
        final int maxAttempts = m == WJModule.ESP ? 10 : 1;
        setJ1850Header(m, 0x14, new Runnable() {
            @Override public void run() { attempt(1); }
            void attempt(final int n) {
                conn.sendCommand(clearCmd, 3000, new Elm327.Callback() {
                    @Override public void onResponse(String r) {
                        if (Models.hasToken(r, 0x54)) { cb.on(true); return; }
                        if (n < maxAttempts) h.postDelayed(new Runnable() { @Override public void run() { attempt(n + 1); } }, 400);
                        else cb.on(false);
                    }
                });
            }
        });
    }

    public void readJ1850Data(WJModule m, final String pid, final Elm327.Callback cb) {
        setJ1850Header(m, 0x22, new Runnable() { @Override public void run() { conn.sendCommand(pid + " 00 00", 3000, cb); } });
    }

    /** ECU actuator (SID 0x30): strip the NRC 0x78 pending line, return the positive part. */
    public void sendActuator(String cmd, final Elm327.Callback cb) {
        conn.sendCommand(cmd, 8000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                if (!Models.hasNRC(r, 0x78)) { cb.onResponse(r); return; }
                StringBuilder sb = new StringBuilder();
                for (String line : r.split("\r")) {
                    if (line.isEmpty() || Models.hasNRC(line, 0x78)) continue;
                    if (sb.length() > 0) sb.append('\r');
                    sb.append(line);
                }
                cb.onResponse(sb.toString());
            }
        });
    }
}
