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
    /** ECU routine 0x25 ("fuel correction test") active: the EDC15 only fills the per-cylinder
     *  corrections of block 0x28 while it runs (real car, pcap/full_modules.pcap: 31 25 00 -> 71 25 00). */
    private boolean corrRoutine;
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
        corrRoutine = false;   // a new ATZ init ends any running routine
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

    /** 31 25 00 -> 71 25 00 : start the EDC15 smooth-running / fuel-correction routine so 0x28[16-25] is populated. */
    private void startCorrRoutine(final Runnable then) {
        conn.sendCommand("31 25 00", 3000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                corrRoutine = Models.hasToken(r, 0x71);
                log("[ECU] rutin 0x25 (enjeksiyon düzeltme) " + (corrRoutine ? "başladı" : "başlamadı: " + r.trim()));
                if (then != null) then.run();
            }
        });
    }

    /** 32 25 -> 72 25 : stop the routine (sent when live data / smoke test stops). */
    private void stopCorrRoutine() {
        if (!corrRoutine) return;
        corrRoutine = false;
        if (conn.isReady()) conn.sendCommand("32 25", 2000, null);
    }

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
                startCorrRoutine(new Runnable() { @Override public void run() {
                    if (gen != pollGeneration) return;
                    h.post(ecuPoll);
                    startKeepalive(false);
                } });
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
        stopCorrRoutine();
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
                // The EDC15 only computes them at idle (< ~1000 rpm): while driving the
                // car sends zeros. Keep the last idle set on screen instead of flashing 0.
                if (n >= 26) {
                    boolean any = false;
                    for (int i = 0; i < 5; i++) if (Models.s16(d, 16 + i * 2) != 0) { any = true; break; }
                    if (any) {
                        for (int i = 0; i < 5; i++) ecu.injCorrections[i] = Models.s16(d, 16 + i * 2) / 100.0;
                        ecu.injCorrLive = true; ecu.injCorrAt = System.currentTimeMillis();
                    } else ecu.injCorrLive = false;
                }
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
                // Fuel (verified against real car + WJdiag-Pro screen 2026-10-28):
                //   block 0x21 data[0-1] = fuel sender ADC; voltage = raw * 0.0048  (real: 465 -> 2.23 V)
                //   WJdiag-Pro "Fuel Level" % is derived from that voltage; linear sender fit from two
                //   real points (2.02 V~25 %, 2.23 V=32 %): % = (V - 1.27) * 33.3, clamped 0..100.
                if (n >= 2) {
                    ecu.fuelRaw14 = Models.u16(d, 0);
                    ecu.fuelSensorVoltage = ecu.fuelRaw14 * 0.0048;
                    ecu.fuelLevel = Math.max(0, Math.min(100, (ecu.fuelSensorVoltage - 1.27) * 33.3));
                }
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
                                startCorrRoutine(new Runnable() { @Override public void run() { pollNextSmokeBlock(gen); } });
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
        stopCorrRoutine();
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
                if (module.bus == Bus.KLINE) kwp.clearDTCs(module, done);
                else kwp.clearJ1850DTCs(module, done);
            }
        });
    }

    /** Clear only (no re-read afterwards): used by the periodic airbag auto-clear. */
    public void clearDTCsQuiet(final WJModule module, final Kwp2000.BoolCb cb) {
        ensureModule(module, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                if (!ok) { cb.on(false); return; }
                if (module.bus == Bus.KLINE) kwp.clearDTCs(module, cb);
                else kwp.clearJ1850DTCs(module, cb);
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
            // ABS 0x28. code = PID, description = WJdiag-Pro's exact name (res VeadABS2E<pid>00).
            case ABS: pids = new String[][]{{"2E 10","2E 10","Left Front Sensor Circuit Failure"},{"2E 11","2E 11","Left Front Wheel Speed Signal Failure"},{"2E 12","2E 12","Right Front Sensor Circuit Failure"},{"2E 13","2E 13","Right Front Wheel Speed Signal Failure"},{"2E 14","2E 14","Left Rear Sensor Circuit Failure"},{"2E 15","2E 15","Left Rear Wheel Speed Signal Failure"},
                    {"2E 16","2E 16","Right Rear Sensor Circuit Failure"},{"2E 17","2E 17","Right Rear Wheel Speed Signal Failure"},{"2E 20","2E 20","Pump Circuit Failure"},{"2E 21","2E 21","Valve Power Feed Failure"},{"2E 22","2E 22","CAB Internal Failure"},{"2E 23","2E 23","G-Switch / Sensor Failure"},{"2E 24","2E 24","System Under Voltage"},
                    {"2E 25","2E 25","Cluster Lamp Failure"},{"2E 26","2E 26","BUS System Communication"},{"2E 27","2E 27","System Over Voltage"},{"2E 30","2E 30","Brake Fluid Level Switch"}}; break;
            // BCM 0x40. code = PID, description = WJdiag-Pro primary name (res VeadBody2E<pid>00_0).
            case BODY_COMPUTER: pids = new String[][]{{"2E 00","2E 00","BCM Eeprom Checksum Failure"},{"2E 01","2E 01","Head Lamp Sw Open Ckt"},{"2E 02","2E 02","Pcm Message Not Recd"},{"2E 03","2E 03","Ambient Temperature Sensor Ckt Open"},{"2E 05","2E 05","Wiper Park Switch Failure"},{"2E 12","2E 12","Fog Lamp Relay Ckt Shorted Hi"}}; break;
            // Rain Sensor 0xA7. WJdiag-Pro scans PID 2E 10 (res VeadRainSensor2E1000_0..2).
            case RAIN_SENSOR: pids = new String[][]{{"2E 10","2E 10","Rain Sensor Internal/Optical Fault"}}; break;
            // Airbag/ORC is module 0x58. Confirmed from the WJdiag-Pro ESP32 capture: its airbag
            // read = ATSH245822 + the SAME 2E/2F PID scan below; clear = ATSH245814 + "01 00 00".
            // Airbag/ORC (0x58). code = PID, description = WJdiag-Pro's exact fault name
            // (resources VeadAirbag2E1000_<scan-index>). 2E E5 = "Right Front Impact Sensor
            // Internal 1" matches the real car / pcap. The 2E/2F scan index maps 1:1 to the name.
            case AIRBAG: pids = new String[][]{{"2E 10","2E 10","Accelerometer 1"},{"2E 13","2E 13","Output Driver 1"},{"2E 16","2E 16","Driver SQUIB 1 Circuit Open"},
                    {"2E 19","2E 19","Passenger SQUIB 1 Circuit Open"},{"2E 1C","2E 1C","Internal 1"},{"2E 1F","2E 1F","Driver SQUIB 1 Circuit Short"},
                    {"2E 22","2E 22","Passenger SQUIB 1 Circuit Short"},{"2E 25","2E 25","Driver SQUIB 1 Short To Battery"},{"2E 28","2E 28","Passenger SQUIB 1 Short To Battery"},
                    {"2E 2B","2E 2B","Driver SQUIB 1 Short To Ground"},{"2E 2E","2E 2E","Passenger SQUIB 1 Short To Ground"},{"2E 37","2E 37","Stored Energy Firing 1"},
                    {"2E 3A","2E 3A","Warning Indicator Short"},{"2E 3D","2E 3D","Warning Indicator Open"},{"2E 43","2E 43","No PCI Transmission"},
                    {"2E 49","2E 49","Loss Of Ignition / Run-Start"},{"2E 4C","2E 4C","Loss Of Ignition / Run Only"},{"2E 4F","2E 4F","No Cluster Message"},
                    {"2E 52","2E 52","Cluster Message Mismatch"},{"2E 70","2E 70","Driver SQUIB 2 Circuit Open"},{"2E 73","2E 73","Passenger SQUIB 2 Circuit Open"},
                    {"2E 76","2E 76","Driver SQUIB 2 Circuit Short"},{"2E 79","2E 79","Passenger SQUIB 2 Circuit Short"},{"2E 7C","2E 7C","Driver SQUIB 2 Short To Battery"},
                    {"2E 7F","2E 7F","Passenger SQUIB 2 Short To Battery"},{"2E 82","2E 82","Driver SQUIB 2 Short To Ground"},{"2E 85","2E 85","Passenger SQUIB 2 Short To Ground"},
                    {"2E 88","2E 88","Driver Seat Belt Switch Circuit Open"},{"2E 8B","2E 8B","Passenger Seat Belt Switch Circuit Open"},{"2E 8E","2E 8E","Driver Seat Belt Switch Shorted To Ground"},
                    {"2E 91","2E 91","Passenger Seat Belt Switch Shorted To Ground"},{"2E 94","2E 94","Driver Seat Belt Switch Shorted To Battery"},{"2E 97","2E 97","Passenger Seat Belt Switch Shorted To Battery"},
                    {"2E DC","2E DC","No Left Front Impact Sensor Communication"},{"2E DF","2E DF","No Right Front Impact Sensor Communication"},{"2E E2","2E E2","Left Front Impact Sensor Internal 1"},
                    {"2E E5","2E E5","Right Front Impact Sensor Internal 1"},{"2E FA","2E FA","Interrogate AOSIM"},{"2E FD","2E FD","No AOSIM Message"},
                    {"2F 00","2F 00","AOSIM Driver Off Indicator Failure"},{"2F 03","2F 03","AOSIM Passenger Off Indicator Failure"},{"2F 06","2F 06","Module Not Configured For AOSIM"},
                    {"2F 18","2F 18","Driver Curtain SQUIB Circuit Open"},{"2F 1B","2F 1B","Passenger Curtain SQUIB Circuit Open"},{"2F 1E","2F 1E","Driver Curtain SQUIB Circuit Short"},
                    {"2F 21","2F 21","Passenger Curtain SQUIB Circuit Short"},{"2F 24","2F 24","Driver Curtain SQUIB Short To Battery"},{"2F 27","2F 27","Passenger Curtain SQUIB Short To Battery"},
                    {"2F 2A","2F 2A","Driver Curtain SQUIB Short To Ground"},{"2F 2D","2F 2D","Passenger Curtain SQUIB Short To Ground"},{"2F 30","2F 30","Accelerometer 2"},
                    {"2F 33","2F 33","No Driver Side Impact Sensor Communication"},{"2F 36","2F 36","No Passenger Side Impact Sensor Communication"},{"2F 39","2F 39","Driver Side Impact Sensor Internal 1"},
                    {"2F 3C","2F 3C","Passenger Side Impact Sensor Internal 1"}}; break;
            default: pids = new String[][]{{"2E 00","U0001"},{"2E 10","U0010"}};
        }
        final List<DtcEntry> found = new ArrayList<>();
        // Re-assert the J1850 read header (ATSH24xx22 + ATRAxx) before scanning.
        // ensureModule() short-circuits re-init when the module is already current, so a
        // previous clear/auto-clear (which leaves the header in mode 0x14) would otherwise
        // make every 2E/2F read come back NO DATA. WJdiag-Pro also warms the airbag module
        // with a 20/24/28 identity+status block read first — replicate that for 0x58.
        kwp.setJ1850Header(module, 0x22, new Runnable() {
            @Override public void run() {
                if (module == WJModule.AIRBAG) {
                    String[] warm = {"20 00 00", "20 01 00", "20 02 00", "24 00 00", "28 00 00", "20 07 00"};
                    sendWarmup(warm, 0, new Runnable() { @Override public void run() { scanNext(module, pids, 0, found); } });
                } else scanNext(module, pids, 0, found);
            }
        });
    }

    /** Sequentially send the WJdiag-Pro airbag warm-up blocks before the DTC scan. */
    private void sendWarmup(final String[] cmds, final int i, final Runnable done) {
        if (i >= cmds.length) { done.run(); return; }
        conn.sendCommand(cmds[i], 2000, new Elm327.Callback() {
            @Override public void onResponse(String r) {
                conn.log("[DTC warm] " + cmds[i] + " -> " + r.replace("\r", " | "));
                h.postDelayed(new Runnable() { @Override public void run() { sendWarmup(cmds, i + 1, done); } }, 80);
            }
        });
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
                    if (raw != 0 && raw != 0xFFFF && !unsupported) {
                        String desc = pids[i].length > 2 ? pids[i][2] : DtcNames.describe(pids[i][1]);
                        found.add(new DtcEntry(module, pids[i][1], desc));
                    }
                }
                conn.log("[DTC " + module.hex() + "] " + pids[i][0] + " -> " + r.replace("\r", " | "));
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
