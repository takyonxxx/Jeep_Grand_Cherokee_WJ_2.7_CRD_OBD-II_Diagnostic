package com.wjdiag.pro;

import android.os.Handler;
import android.os.Looper;

import com.wjdiag.pro.Models.Bus;
import com.wjdiag.pro.Models.DtcEntry;
import com.wjdiag.pro.Models.EcuStatus;
import com.wjdiag.pro.Models.Gear;
import com.wjdiag.pro.Models.TcmStatus;
import com.wjdiag.pro.Models.WJModule;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;

/**
 * Diagnostics orchestrator (port of the iOS WJDiagnostics): module init with
 * K-Line session handling, SID 81 keepalive, ECU / TCM live polling, block
 * parsing with the verified formulas, DTC read/clear, smoke test chain.
 * Runs entirely on the main thread (the Elm327 queue calls back there).
 */
public final class WJDiag {

    public interface Listener {
        void onEcuUpdate();
        void onTcmUpdate();
        void onDtcUpdate();
        void onPollingChanged(boolean polling);
        void onSmokeUpdate();
    }

    public final EcuStatus ecu = new EcuStatus();
    public final TcmStatus tcm = new TcmStatus();
    public final List<DtcEntry> dtcList = new ArrayList<>();
    public final SmokeTest smoke = new SmokeTest();
    public String dtcStatus = "";
    public boolean isPollingLive;
    public WJModule activeModule;
    public WJModule initializedModule;
    public boolean ecuSecurityUnlocked;

    private final Elm327 conn;
    private final Kwp2000 kwp;
    private final Handler h = new Handler(Looper.getMainLooper());
    private Listener listener;

    private static final int[] ECU_BLOCKS = {0x12, 0x30, 0x22, 0x20, 0x23, 0x21, 0x16, 0x32, 0x37, 0x13, 0x36, 0x26, 0x34, 0x28};
    private static final int[] ECU_SEC_BLOCKS = {0x62, 0xB0, 0xB1, 0xB2};
    private static final int[] TCM_BLOCKS = {0x30, 0x31, 0x34, 0x33, 0x32};
    private static final int[] SMOKE_FAST = {0x36, 0x28};
    private static final int[] SMOKE_SLOW = {0x12, 0x26, 0x21, 0x26, 0x12, 0x26, 0x32, 0x26, 0x12, 0x26, 0x37, 0x26, 0x12, 0x26, 0x20, 0x26, 0x12, 0x26, 0x23, 0x26};

    private int currentBlockIndex, smokeStep, smokeSlowIndex;
    private long lastSmokeRead;
    private boolean kLineRetryPending;
    private int pollGeneration;

    public WJDiag(Elm327 c) { conn = c; kwp = new Kwp2000(c); }
    public void setListener(Listener l) { listener = l; }
    private void log(String s) { conn.log(s); }

    // ------------------------------------------------------------------ init

    public void initModule(final WJModule module, final Kwp2000.BoolCb cb) {
        final WJModule previous = initializedModule;
        beginInit();
        if (previous != null && previous.bus == Bus.KLINE && module.bus == Bus.KLINE && !kLineRetryPending) {
            log("[INIT] " + previous.displayName + " oturumu kapatılıyor (SID 82), sonra " + module.displayName);
            conn.sendCommand("82", 2000, new Elm327.Callback() {
                @Override public void onResponse(String r) {
                    h.postDelayed(new Runnable() { @Override public void run() { runKLineInit(module, cb); } }, 600);
                }
            });
            return;
        }
        if (module.bus == Bus.KLINE) runKLineInit(module, cb);
        else kwp.initJ1850(module, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) { if (ok) initializedModule = module; cb.on(ok); }
        });
    }

    private void runKLineInit(final WJModule module, final Kwp2000.BoolCb cb) {
        final Kwp2000.BoolCb finish = new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                if (ok) {
                    kLineRetryPending = false;
                    initializedModule = module;
                    startKeepalive(false);
                    cb.on(true);
                    return;
                }
                if (!kLineRetryPending) {
                    kLineRetryPending = true;
                    log("[INIT] " + module.displayName + " bus init başarısız, P3max (5.5 s) sonra tekrar");
                    h.postDelayed(new Runnable() { @Override public void run() {
                        initModule(module, new Kwp2000.BoolCb() { @Override public void on(boolean ok2) { kLineRetryPending = false; cb.on(ok2); } });
                    } }, 5500);
                    return;
                }
                kLineRetryPending = false;
                cb.on(false);
            }
        };
        if (module == WJModule.MOTOR_ECU) {
            kwp.initECU(new Kwp2000.BoolCb() {
                @Override public void on(boolean ok) {
                    if (!ok) { finish.on(false); return; }
                    kwp.securityUnlockECU(new Kwp2000.BoolCb() {
                        @Override public void on(boolean unlocked) {
                            ecuSecurityUnlocked = unlocked;
                            log("ECU güvenlik: " + (unlocked ? "açık" : "kilitli"));
                            finish.on(true);
                        }
                    });
                }
            });
        } else {
            kwp.initTCM(new Kwp2000.BoolCb() {
                @Override public void on(boolean ok) {
                    if (!ok) { finish.on(false); return; }
                    kwp.securityUnlockTCM(new Kwp2000.BoolCb() { @Override public void on(boolean u) { finish.on(true); } });
                }
            });
        }
    }

    private void ensureModule(WJModule m, Kwp2000.BoolCb cb) {
        if (initializedModule == m && conn.isReady()) { cb.on(true); return; }
        initModule(m, cb);
    }

    private void beginInit() {
        stopKeepalive();
        conn.cancelQueuedCommands();
        initializedModule = null;
    }

    public void onDisconnected() {
        stopLiveData();
        stopKeepalive();
        initializedModule = null;
        activeModule = null;
        ecuSecurityUnlocked = false;
    }

    public void setActiveModule(WJModule m) {
        activeModule = m;
        if (m == null || m.bus != Bus.KLINE) stopKeepalive();
    }

    static double pedalPercent(int raw) { return Math.min(100.0, Math.max(0.0, raw / 100.0)); }

    // ------------------------------------------------------------------ keepalive

    private boolean keepaliveOnlyIdle;
    private final Runnable keepaliveTick = new Runnable() {
        @Override public void run() {
            if (!keepaliveRunning) return;
            if (conn.isReady()) {
                boolean skip = keepaliveOnlyIdle && (System.currentTimeMillis() - lastSmokeRead) <= 1500;
                if (!skip && conn.pendingCommands() == 0) kwp.sendKeepalive();
            }
            h.postDelayed(this, 2000);
        }
    };
    private boolean keepaliveRunning;

    private void startKeepalive(boolean onlyWhenIdle) {
        h.removeCallbacks(keepaliveTick);
        keepaliveOnlyIdle = onlyWhenIdle;
        keepaliveRunning = true;
        h.postDelayed(keepaliveTick, 2000);
    }
    private void stopKeepalive() { keepaliveRunning = false; h.removeCallbacks(keepaliveTick); }
    private void resumeIdleKeepalive() {
        if (activeModule != null && activeModule.bus == Bus.KLINE && conn.isReady()) startKeepalive(false);
        else stopKeepalive();
    }

    // ------------------------------------------------------------------ live data

    public void startECULiveData() {
        if (isPollingLive) return;
        setActiveModule(WJModule.MOTOR_ECU);
        setPolling(true);
        currentBlockIndex = 0;
        final int gen = ++pollGeneration;
        ensureModule(WJModule.MOTOR_ECU, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                if (gen != pollGeneration) return;
                if (!ok) { setPolling(false); return; }
                h.post(ecuPoll);
                startKeepalive(false);
            }
        });
    }

    public void startTCMLiveData() {
        if (isPollingLive) return;
        setActiveModule(WJModule.KLINE_TCM);
        setPolling(true);
        currentBlockIndex = 0;
        final int gen = ++pollGeneration;
        ensureModule(WJModule.KLINE_TCM, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                if (gen != pollGeneration) return;
                if (!ok) { setPolling(false); return; }
                h.post(tcmPoll);
                startKeepalive(false);
            }
        });
    }

    public void stopLiveData() {
        pollGeneration++;
        if (smoke.isRecording) { smoke.finish(); notifySmoke(); }
        setPolling(false);
        h.removeCallbacks(ecuPoll); h.removeCallbacks(tcmPoll);
        conn.cancelQueuedCommands();
        resumeIdleKeepalive();
    }

    private void setPolling(boolean p) {
        if (isPollingLive == p) return;
        isPollingLive = p;
        if (listener != null) listener.onPollingChanged(p);
    }

    private final Runnable ecuPoll = new Runnable() {
        @Override public void run() {
            if (!isPollingLive || smoke.isRecording) return;
            h.postDelayed(this, 100);
            if (conn.pendingCommands() != 0) return;
            int[] blocks = ECU_BLOCKS;
            if (ecuSecurityUnlocked) {
                blocks = new int[ECU_BLOCKS.length + ECU_SEC_BLOCKS.length];
                System.arraycopy(ECU_BLOCKS, 0, blocks, 0, ECU_BLOCKS.length);
                System.arraycopy(ECU_SEC_BLOCKS, 0, blocks, ECU_BLOCKS.length, ECU_SEC_BLOCKS.length);
            }
            final int block = blocks[currentBlockIndex % blocks.length];
            currentBlockIndex++;
            final boolean endOfCycle = currentBlockIndex % blocks.length == 0;
            kwp.readBlock(block, new Elm327.Callback() {
                @Override public void onResponse(String r) {
                    parseECUBlock(block, r);
                    computeFuelFlow();
                    notifyEcu();
                    if (endOfCycle) readBatteryATRV(true);
                }
            });
        }
    };

    private void readBatteryATRV(final boolean forEcu) {
        conn.sendCommand("ATRV", 3000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                try {
                    double v = Double.parseDouble(r.trim().replace("V", "").replace("v", "").trim());
                    if (v > 0) { if (forEcu) { ecu.batteryVoltage = v; notifyEcu(); } else { tcm.batteryVoltage = v; notifyTcm(); } }
                } catch (NumberFormatException ignored) {}
            }
        });
    }

    private void computeFuelFlow() {
        double iq = ecu.fuelQuantity > 0 ? ecu.fuelQuantity : ecu.injectionQty;
        double gs = ecu.rpm * iq * 5.0 / (2.0 * 1000.0 * 60.0);
        ecu.fuelFlowLH = gs * 3600.0 / 832.0;
        ecu.fuelLPer100km = ecu.vehicleSpeed > 5.0 ? ecu.fuelFlowLH / ecu.vehicleSpeed * 100.0 : 0;
    }

    private void parseECUBlock(int block, String r) {
        byte[] b = Models.hexToBytes(r);
        int idx = Models.findPayload(b, 0x61, block);
        if (idx < 0) return;
        byte[] d = new byte[b.length - idx - 2];
        System.arraycopy(b, idx + 2, d, 0, d.length);
        int n = d.length;
        switch (block) {
            case 0x28:
                if (n >= 4) { ecu.rpm = Models.u16(d, 0); ecu.injectionQty = Models.u16(d, 2) / 100.0; }
                if (n >= 14) for (int i = 0; i < 5; i++) ecu.cylRPMs[i] = Models.u16(d, 4 + i * 2);
                // Five per-cylinder smooth-running corrections at [16-25] (real car: 0016 0011 FF72 0036 002F,
                // sum = -0.02 mg in every capture - they redistribute fuel, so they add up to zero). RELAY_MAP's
                // "[16-17] constant / [18-19] varies" are cylinders 1 and 2. Idle only, zero while driving.
                if (n >= 26) for (int i = 0; i < 5; i++) ecu.injCorrections[i] = Models.s16(d, 16 + i * 2) / 100.0;
                break;
            case 0x22:
                if (n >= 2) ecu.coolantTemp = Models.u16(d, 0) / 10.0 - 273.1;
                if (n >= 4) ecu.iat = Models.u16(d, 2) / 10.0 - 273.1;
                if (n >= 16) ecu.boostPressure = Models.u16(d, 14) / 1000.0;
                break;
            case 0x12:
                if (n >= 2) ecu.coolantTemp = Models.u16(d, 0) / 10.0 - 273.1;
                if (n >= 4) ecu.iat = Models.u16(d, 2) / 10.0 - 273.1;
                if (n >= 12 && ecu.rpm == 0) ecu.rpm = Models.u16(d, 10);
                if (n >= 14) ecu.pedalPos = pedalPercent(Models.u16(d, 12));
                if (n >= 18) { ecu.mapActual = Models.u16(d, 16); ecu.boostPressure = ecu.mapActual / 1000.0; }
                if (n >= 20) ecu.railPressure = Models.u16(d, 18) * 0.101;
                break;
            case 0x36:
                if (n >= 2) ecu.blk36signed = Models.s16(d, 0);
                if (n >= 3) ecu.gear = d[2] & 0xFF;
                if (n >= 8) ecu.mafFlow = Models.u16(d, 6) / 10.0;
                if (n >= 10) ecu.boostSetpoint = Models.u16(d, 8) / 1000.0;
                if (n >= 12) ecu.blk36c = Models.u16(d, 10);
                if (n >= 14) ecu.pedalPos = pedalPercent(Models.u16(d, 12));
                if (n >= 24 && ecu.railPressure == 0) ecu.railPressure = Models.u16(d, 22) * 0.101;
                if (n >= 32) ecu.blk36torque = Models.s16(d, 30);
                break;
            case 0x32:
                if (n >= 2) ecu.fuelQuantity = Models.u16(d, 0) / 100.0;
                break;
            case 0x26:
                if (n >= 4) ecu.vehicleSpeed = Models.u16(d, 2) / 100.0;
                break;
            case 0x21:
                for (int i = 0; i < 7; i++) if (n >= (i + 1) * 2) ecu.fuelQty21[i] = Models.u16(d, i * 2) / 100.0;
                if (n >= 16) ecu.fuelLevel = Models.u16(d, 14) / 10.0;
                if (n >= 18) ecu.fuelSensorVoltage = Models.u16(d, 16) / 100.0;
                break;
            case 0x37:
                if (n >= 2) ecu.egrMafSetpoint = Models.u16(d, 0);
                if (n >= 4) ecu.wastegateRaw = Models.u16(d, 2);
                break;
            case 0x20:
                if (n >= 2) ecu.blk20a = Models.u16(d, 0);
                if (n >= 4) ecu.blk20b = Models.u16(d, 2);
                break;
            case 0x23:
                if (n >= 2) ecu.blk23a = Models.u16(d, 0);
                if (n >= 8) ecu.blk23g = Models.u16(d, 6);
                break;
            case 0x62:
                // real vehicle: 33 4A 94 84 -> EGR 51 %, wastegate 74 %
                if (n >= 4) { ecu.egrDuty = (d[0] & 0xFF) * 100.0 / 100.0; ecu.wastegateDuty = (d[2] & 0xFF) * 100.0 / 200.0; }
                break;
            default: break;
        }
        if (smoke.isRecording) { smoke.append(ecu, block); notifySmoke(); }
    }

    private final Runnable tcmPoll = new Runnable() {
        @Override public void run() {
            if (!isPollingLive) return;
            h.postDelayed(this, 120);
            if (conn.pendingCommands() != 0) return;
            final int block = TCM_BLOCKS[currentBlockIndex % TCM_BLOCKS.length];
            currentBlockIndex++;
            final boolean endOfCycle = currentBlockIndex % TCM_BLOCKS.length == 0;
            if (endOfCycle) kwp.sendKeepalive();
            kwp.readBlock(block, new Elm327.Callback() {
                @Override public void onResponse(String r) {
                    parseTCMBlock(block, r);
                    notifyTcm();
                    if (endOfCycle) readBatteryATRV(false);
                }
            });
        }
    };

    private void parseTCMBlock(int block, String r) {
        byte[] b = Models.hexToBytes(r);
        int idx = Models.findPayload(b, 0x61, block);
        if (idx < 0) return;
        byte[] d = new byte[b.length - idx - 2];
        System.arraycopy(b, idx + 2, d, 0, d.length);
        int n = d.length;
        switch (block) {
            case 0x30:
                if (n >= 2) tcm.actualTCCSlip = Models.s16(d, 0);
                if (n >= 4) tcm.desiredTCCSlip = Models.s16(d, 2);
                if (n >= 6) tcm.outputRPM = Models.u16(d, 4);
                if (n >= 8) tcm.selector = d[7] & 0xFF;
                if (n >= 10) {
                    int sel = d[7] & 0xFF, g = d[9] & 0xFF;
                    switch (sel) {
                        case 8: tcm.gear = Gear.PARK; break;
                        case 7: tcm.gear = Gear.REVERSE; break;
                        case 6: tcm.gear = Gear.NEUTRAL; break;
                        case 5:
                            switch (g) {
                                case 1: tcm.gear = Gear.D1; break; case 2: tcm.gear = Gear.D2; break;
                                case 3: tcm.gear = Gear.D3; break; case 4: tcm.gear = Gear.D4; break;
                                case 5: tcm.gear = Gear.D5; break; default: tcm.gear = Gear.D1;
                            }
                            break;
                        default: tcm.gear = Gear.UNKNOWN;
                    }
                }
                if (n >= 12) tcm.transTemp = (d[11] & 0xFF) - 50.0;
                break;
            case 0x31:
                if (n >= 2) tcm.inputN2 = Models.u16(d, 0);
                if (n >= 6) tcm.turbineRPM = Models.u16(d, 4);
                if (n >= 8) tcm.engineRPM = Models.u16(d, 6);
                break;
            case 0x34:
                if (n >= 6) tcm.sensorSupply = Models.u16(d, 4) * 7.0 / 1000.0;
                if (n >= 8) tcm.solenoidVoltage = Models.u16(d, 6) / 40.0;
                break;
            case 0x33:
                if (n >= 2) tcm.tccPressure = Models.u16(d, 0) / 1000.0;
                if (n >= 8) tcm.shiftPressure = Models.u16(d, 6) / 365.0;
                if (n >= 10) tcm.modulationPressure = Models.u16(d, 8) / 462.0;
                break;
            case 0x32:
                if (n >= 1) tcm.vehicleSpeed = d[0] & 0xFF;
                break;
            default: break;
        }
    }

    // ------------------------------------------------------------------ smoke test

    public void startSmokeTest() {
        if (smoke.isRecording) return;
        stopLiveData();
        smoke.begin();
        setActiveModule(WJModule.MOTOR_ECU);
        setPolling(true);
        smokeStep = 0; smokeSlowIndex = 0;
        log("[SMOKE] test başladı");
        notifySmoke();
        final int gen = ++pollGeneration;
        ensureModule(WJModule.MOTOR_ECU, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                if (gen != pollGeneration) return;
                if (!ok) {
                    smoke.error = "ECU init başarısız"; smoke.finish(); setPolling(false); setActiveModule(null); notifySmoke();
                    return;
                }
                startKeepalive(true);
                conn.sendCommand("ATAT2", 2000, new Elm327.Callback() {
                    @Override public void onResponse(String r) {
                        conn.sendCommand("ATST 19", 2000, new Elm327.Callback() {
                            @Override public void onResponse(String r2) {
                                log("[SMOKE] ELM zamanlama (ATAT2, ATST 19)");
                                pollNextSmokeBlock(gen);
                            }
                        });
                    }
                });
            }
        });
    }

    public void stopSmokeTest() {
        if (!smoke.isRecording) return;
        pollGeneration++;
        smoke.finish();
        setPolling(false);
        log(String.format(Locale.US, "[SMOKE] durdu: %d örnek, %.1f s", smoke.samples.size(), smoke.duration()));
        resumeIdleKeepalive();
        notifySmoke();
    }

    public void smokeTestMark() {
        smoke.mark();
        if (!smoke.marks.isEmpty()) log(String.format(Locale.US, "[SMOKE] MARK %.1f s", smoke.marks.get(smoke.marks.size() - 1)));
        notifySmoke();
    }

    public void clearSmokeTest() { if (!smoke.isRecording) { smoke.reset(); notifySmoke(); } }

    private void pollNextSmokeBlock(final int gen) {
        if (!smoke.isRecording || gen != pollGeneration) return;
        final int block;
        if (smokeStep < SMOKE_FAST.length) block = SMOKE_FAST[smokeStep++];
        else { block = SMOKE_SLOW[smokeSlowIndex % SMOKE_SLOW.length]; smokeSlowIndex++; smokeStep = 0; }
        kwp.readBlock(block, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                lastSmokeRead = System.currentTimeMillis();
                parseECUBlock(block, r);
                computeFuelFlow();
                notifyEcu();
                h.postDelayed(new Runnable() { @Override public void run() { pollNextSmokeBlock(gen); } }, 20);
            }
        });
    }

    // ------------------------------------------------------------------ DTC

    private void setDTCStatus(String s) { dtcStatus = s; log("[DTC] " + s); notifyDtc(); }

    public void readDTCs(final WJModule module) {
        setDTCStatus(module.displayName + ": okunuyor…");
        ensureModule(module, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                if (!ok) { setDTCStatus(module.displayName + ": init başarısız"); return; }
                if (module.bus == Bus.KLINE) {
                    kwp.readDTCs(module, new Elm327.Callback() {
                        @Override public void onResponse(String r) {
                            if (r.contains("TIMEOUT") || r.contains("BUS INIT")) { setDTCStatus(module.displayName + ": 18 02 cevapsız (" + r.trim() + ")"); return; }
                            int n = parseKLineDTCs(module, r);
                            setDTCStatus(module.displayName + ": " + n + " DTC");
                        }
                    });
                } else readJ1850DTCsByPIDScan(module);
            }
        });
    }

    public void clearDTCs(final WJModule module) {
        setDTCStatus(module.displayName + ": siliniyor…");
        ensureModule(module, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                if (!ok) { setDTCStatus(module.displayName + ": init başarısız"); return; }
                Kwp2000.BoolCb done = new Kwp2000.BoolCb() {
                    @Override public void on(boolean ok2) {
                        if (ok2) {
                            removeDtcs(module);
                            setDTCStatus(module.displayName + ": silindi");
                            h.postDelayed(new Runnable() { @Override public void run() { readDTCs(module); } }, 500);
                        } else setDTCStatus(module.displayName + ": silme başarısız (54 yok)");
                    }
                };
                if (module.bus == Bus.KLINE) kwp.clearDTCs(module, done); else kwp.clearJ1850DTCs(module, done);
            }
        });
    }

    private void removeDtcs(WJModule m) {
        for (Iterator<DtcEntry> it = dtcList.iterator(); it.hasNext(); ) if (it.next().module == m) it.remove();
    }

    private int parseKLineDTCs(WJModule module, String r) {
        byte[] b = Models.hexToBytes(r);
        int idx = -1;
        for (int i = 0; i < b.length; i++) if ((b[i] & 0xFF) == 0x58) { idx = i; break; }
        removeDtcs(module);
        if (idx < 0) { notifyDtc(); return 0; }
        int count = idx + 1 < b.length ? b[idx + 1] & 0xFF : 0;
        int found = 0;
        for (int i = idx + 2; i + 2 < b.length && found < count; i += 3) {
            String code = decodeDTC(b[i] & 0xFF, b[i + 1] & 0xFF);
            dtcList.add(new DtcEntry(module, code, DtcNames.describe(code)));
            found++;
        }
        notifyDtc();
        return found;
    }

    private void readJ1850DTCsByPIDScan(final WJModule module) {
        final String[][] pids;
        switch (module) {
            case ABS: pids = new String[][]{{"2E 10","C0031"},{"2E 11","C0032"},{"2E 12","C0035"},{"2E 13","C0036"},{"2E 14","C0041"},{"2E 15","C0042"},
                    {"2E 16","C0045"},{"2E 17","C0046"},{"2E 20","C0051"},{"2E 21","C0060"},{"2E 22","C0070"},{"2E 23","C0080"},{"2E 24","C0081"},
                    {"2E 25","C0085"},{"2E 26","C0110"},{"2E 27","C0111"},{"2E 30","C1014"}}; break;
            case BODY_COMPUTER: pids = new String[][]{{"2E 00","B1A00"},{"2E 01","B1A10"},{"2E 02","B2100"},{"2E 03","B2101"},{"2E 05","B2102"},{"2E 0D","B2200"},{"2E 12","B2300"}}; break;
            case RAIN_SENSOR: pids = new String[][]{{"2E 00","B1A00"},{"2E 01","B1A10"}}; break;
            case ESP: pids = new String[][]{{"2E 10","C1010"},{"2E 13","C1013"},{"2E 16","C1016"},{"2E 19","C1019"},{"2E 1C","C101C"},{"2E 1F","C101F"},
                    {"2E 22","C1022"},{"2E 25","C1025"},{"2E 28","C1028"},{"2E 2B","C102B"},{"2E 2E","C102E"},{"2E 37","C1037"},{"2E 3A","C103A"},
                    {"2E 3D","C103D"},{"2E 43","C1043"},{"2E 49","C1049"},{"2E 4C","C104C"},{"2E 4F","C104F"},{"2E 52","C1052"},{"2E 70","C1070"},
                    {"2E 73","C1073"},{"2E 76","C1076"},{"2E 79","C1079"},{"2E 7C","C107C"},{"2E 7F","C107F"},{"2E 82","C1082"},{"2E 85","C1085"},
                    {"2E 88","C1088"},{"2E 8B","C108B"},{"2E 8E","C108E"},{"2E 91","C1091"},{"2E 94","C1094"},{"2E 97","C1097"},{"2E DC","C10DC"},
                    {"2E DF","C10DF"},{"2E E2","C10E2"},{"2E E5","C2103"},{"2E FA","C10FA"},{"2E FD","C10FD"},{"2F 00","C2000"},{"2F 03","C2003"},
                    {"2F 06","C2006"},{"2F 18","C2018"},{"2F 1B","C201B"},{"2F 1E","C201E"},{"2F 21","C2021"},{"2F 24","C2024"},{"2F 27","C2027"},
                    {"2F 2A","C202A"},{"2F 2D","C202D"},{"2F 30","C2030"},{"2F 33","C2033"},{"2F 36","C2036"},{"2F 39","C2039"},{"2F 3C","C203C"}}; break;
            default: pids = new String[][]{{"2E 00","U0001"},{"2E 10","U0010"}};
        }
        final List<DtcEntry> found = new ArrayList<>();
        scanNext(module, pids, 0, found);
    }

    private void scanNext(final WJModule module, final String[][] pids, final int i, final List<DtcEntry> found) {
        if (i >= pids.length) {
            removeDtcs(module); dtcList.addAll(found);
            setDTCStatus(module.displayName + ": " + found.size() + " DTC (" + pids.length + " PID tarandı)");
            return;
        }
        conn.sendCommand(pids[i][0] + " 00", 3000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                byte[] b = Models.hexToBytes(r);
                int idx62 = -1;
                for (int k = 2; k < b.length; k++) if ((b[k] & 0xFF) == 0x62 && (b[k - 1] & 0xFF) == module.addr && (b[k - 2] & 0xFF) == 0x26) { idx62 = k; break; }
                if (idx62 < 0 && !Models.hasNRC(r, 0x21)) for (int k = 0; k < b.length; k++) if ((b[k] & 0xFF) == 0x62) { idx62 = k; break; }
                if (idx62 >= 0 && idx62 + 3 < b.length) {
                    int d0 = b[idx62 + 1] & 0xFF, d1 = b[idx62 + 2] & 0xFF, d2 = b[idx62 + 3] & 0xFF;
                    int raw = (d0 << 8) | d1;
                    boolean unsupported = d1 == 0xFF && d2 == 0xFF;
                    if (raw != 0 && raw != 0xFFFF && !unsupported) found.add(new DtcEntry(module, pids[i][1], DtcNames.describe(pids[i][1])));
                }
                setDTCStatus(module.displayName + ": taranıyor " + (i + 1) + "/" + pids.length + "…");
                h.postDelayed(new Runnable() { @Override public void run() { scanNext(module, pids, i + 1, found); } }, 100);
            }
        });
    }

    private static String decodeDTC(int hi, int lo) {
        String prefix = new String[]{"P", "C", "B", "U"}[(hi >> 6) & 3];
        return String.format("%s%01X%01X%02X", prefix, (hi >> 4) & 3, hi & 0xF, lo);
    }

    // ------------------------------------------------------------------ custom / actuators

    public void sendCustomCommand(String cmd) { sendCustomCommand(cmd, 1); }

    private void sendCustomCommand(final String cmd, final int attempt) {
        conn.sendCommand(cmd, 5000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                log("[CMD] " + cmd + " -> " + r.replace("\r", " | "));
                String u = cmd.toUpperCase(Locale.US);
                boolean actuatorOff = u.startsWith("38 ") && u.endsWith(" 00");
                if (actuatorOff && r.contains("NO DATA") && attempt < 3) {
                    log("[CMD] OFF tekrar " + attempt);
                    h.postDelayed(new Runnable() { @Override public void run() { sendCustomCommand(cmd, attempt + 1); } }, 150);
                }
            }
        });
    }

    /** Header (if any) then the command, 150 ms apart like the iOS HoldButton. */
    public void sendActuator(final String hdr, final String cmd) {
        if (hdr != null) {
            sendCustomCommand(hdr);
            h.postDelayed(new Runnable() { @Override public void run() { sendCustomCommand(cmd); } }, 150);
        } else sendCustomCommand(cmd);
    }

    public void readEcuId(final Elm327.Callback cb) {
        ensureModule(WJModule.MOTOR_ECU, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                if (!ok) { cb.onResponse("init başarısız"); return; }
                conn.sendCommand("1A 90", 4000, new Elm327.Callback() {
                    @Override public void onResponse(String r) {
                        byte[] b = Models.hexToBytes(r);
                        int i = Models.findPayload(b, 0x5A, 0x90);
                        if (i >= 0) {
                            StringBuilder sb = new StringBuilder();
                            for (int k = i + 2; k < b.length - 1 && sb.length() < 17; k++) sb.append((char) (b[k] & 0xFF));
                            ecu.vin = sb.toString();
                        }
                        cb.onResponse(i >= 0 ? "VIN " + ecu.vin : "VIN okunamadı: " + r);
                    }
                });
            }
        });
    }

    // ------------------------------------------------------------------ notify
    private void notifyEcu() { if (listener != null) listener.onEcuUpdate(); }
    private void notifyTcm() { if (listener != null) listener.onTcmUpdate(); }
    private void notifyDtc() { if (listener != null) listener.onDtcUpdate(); }
    private void notifySmoke() { if (listener != null) listener.onSmokeUpdate(); }
}
