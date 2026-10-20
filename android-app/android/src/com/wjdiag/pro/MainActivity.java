package com.wjdiag.pro;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.StrictMode;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import com.wjdiag.pro.Models.ActDef;
import com.wjdiag.pro.Models.Bus;
import com.wjdiag.pro.Models.DtcEntry;
import com.wjdiag.pro.Models.EcuStatus;
import com.wjdiag.pro.Models.Gear;
import com.wjdiag.pro.Models.TcmStatus;
import com.wjdiag.pro.Models.WJModule;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public class MainActivity extends Activity implements Elm327.Listener, WJDiag.Listener {

    private static final String[] TAB_NAMES = {"BAĞLANTI", "DTC", "KONTROL", "AKTÜATÖR", "DUMAN TESTİ", "LOG"};
    private static final int C_GREEN = 0xFF00E08A, C_AMBER = 0xFFD0A040, C_RED = 0xFFFF4D4D, C_ORANGE = 0xFFFF8C1A, C_DIM = 0xFF9A9AA3, C_CYAN = 0xFF40D0FF;

    private final Handler h = new Handler();
    private Elm327 elm;
    private WJDiag diag;
    private SharedPreferences prefs;

    private final List<Button> tabs = new ArrayList<>();
    private final View[] pages = new View[6];
    private int currentTab = 0;

    private View stateDot, liveDot;
    private TextView stateText, liveText, dashTitle, connInfo, dtcCount, dtcStatus, actTitle, actInfo, ctrlInfo, logText, smokeNotice, smokeSummary;
    private Button btnTopConnect, btnConnect, btnDisconnect, btnLive, btnBt, btnSim, btnDtcRead, btnDtcClear;
    private Button btnSmokeStart, btnSmokeStop, btnSmokeMark, btnSmokeClear;
    private EditText host, port, rawCmd;
    private LinearLayout tabConn, ecuDash, tcmDash, moduleList, dtcSources, dtcList, ctrlGroups, ctrlGrid, actGrid, smokeGrid, smokeShareRow;
    private ScrollView dashScroll, connScroll, logScroll;

    private final Map<String, TextView> gauges = new HashMap<>();
    private final Map<WJModule, View> moduleRows = new LinkedHashMap<>();
    private WJModule selectedModule;
    private boolean switching;
    private int dtcSource = 0;
    private int ctrlGroup = -1;
    private final List<Button> dtcChips = new ArrayList<>(), ctrlChips = new ArrayList<>();
    private static final WJModule[] DTC_MODULES = {WJModule.KLINE_TCM, WJModule.MOTOR_ECU, WJModule.ABS, WJModule.ESP, WJModule.BODY_COMPUTER, WJModule.RAIN_SENSOR};
    private static final String[] DTC_LABELS = {"TCM", "ECU", "ABS", "ESP", "BCM", "Yağmur"};

    private final StringBuilder logBuf = new StringBuilder();
    private boolean logDirty, ecuDirty, tcmDirty, smokeDirty;

    // ================================================================== lifecycle

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.main);
        prefs = getSharedPreferences("wjdiag", MODE_PRIVATE);
        StrictMode.setVmPolicy(new StrictMode.VmPolicy.Builder().build());
        elm = new Elm327();
        elm.setListener(this);
        diag = new WJDiag(elm);
        diag.setListener(this);

        stateDot = findViewById(R.id.stateDot); liveDot = findViewById(R.id.liveDot);
        stateText = (TextView) findViewById(R.id.stateText); liveText = (TextView) findViewById(R.id.liveText);
        dashTitle = (TextView) findViewById(R.id.dashTitle); connInfo = (TextView) findViewById(R.id.connInfo);
        dtcCount = (TextView) findViewById(R.id.dtcCount); dtcStatus = (TextView) findViewById(R.id.dtcStatus);
        actTitle = (TextView) findViewById(R.id.actTitle); actInfo = (TextView) findViewById(R.id.actInfo); ctrlInfo = (TextView) findViewById(R.id.ctrlInfo);
        logText = (TextView) findViewById(R.id.logText); smokeNotice = (TextView) findViewById(R.id.smokeNotice); smokeSummary = (TextView) findViewById(R.id.smokeSummary);
        btnTopConnect = (Button) findViewById(R.id.btnTopConnect); btnConnect = (Button) findViewById(R.id.btnConnect);
        btnDisconnect = (Button) findViewById(R.id.btnDisconnect); btnLive = (Button) findViewById(R.id.btnLive);
        btnBt = (Button) findViewById(R.id.btnBt); btnSim = (Button) findViewById(R.id.btnSim);
        btnDtcRead = (Button) findViewById(R.id.btnDtcRead); btnDtcClear = (Button) findViewById(R.id.btnDtcClear);
        btnSmokeStart = (Button) findViewById(R.id.btnSmokeStart); btnSmokeStop = (Button) findViewById(R.id.btnSmokeStop);
        btnSmokeMark = (Button) findViewById(R.id.btnSmokeMark); btnSmokeClear = (Button) findViewById(R.id.btnSmokeClear);
        host = (EditText) findViewById(R.id.host); port = (EditText) findViewById(R.id.port); rawCmd = (EditText) findViewById(R.id.rawCmd);
        tabConn = (LinearLayout) findViewById(R.id.tabConn); ecuDash = (LinearLayout) findViewById(R.id.ecuDash); tcmDash = (LinearLayout) findViewById(R.id.tcmDash);
        moduleList = (LinearLayout) findViewById(R.id.moduleList); dtcSources = (LinearLayout) findViewById(R.id.dtcSources); dtcList = (LinearLayout) findViewById(R.id.dtcList);
        ctrlGroups = (LinearLayout) findViewById(R.id.ctrlGroups); ctrlGrid = (LinearLayout) findViewById(R.id.ctrlGrid); actGrid = (LinearLayout) findViewById(R.id.actGrid);
        smokeGrid = (LinearLayout) findViewById(R.id.smokeGrid); smokeShareRow = (LinearLayout) findViewById(R.id.smokeShareRow);
        dashScroll = (ScrollView) findViewById(R.id.dashScroll); connScroll = (ScrollView) findViewById(R.id.connScroll); logScroll = (ScrollView) findViewById(R.id.logScroll);

        pages[0] = tabConn; pages[1] = findViewById(R.id.tabDtc); pages[2] = findViewById(R.id.tabCtrl);
        pages[3] = findViewById(R.id.tabAct); pages[4] = findViewById(R.id.tabSmoke); pages[5] = findViewById(R.id.tabLog);

        host.setText(prefs.getString("host", "192.168.0.10"));
        port.setText(String.valueOf(prefs.getInt("port", 35000)));

        buildTabs();
        buildEcuDash();
        buildTcmDash();
        buildModuleList();
        buildDtcSources();
        buildCtrlGroups();
        buildSmokeGrid();
        applyOrientation(getResources().getConfiguration());
        wireButtons();
        setDot(stateDot, 0xFF666666);
        setDot(liveDot, 0xFF666666);
        refreshEnabled();
        refreshEcu();
        refreshTcm();
        refreshSmoke();
        h.post(uiTick);
        selectTab(0);
    }

    @Override protected void onDestroy() {
        super.onDestroy();
        h.removeCallbacksAndMessages(null);
        diag.stopLiveData();
        elm.disconnect();
    }

    @Override public void onConfigurationChanged(Configuration c) {
        super.onConfigurationChanged(c);
        applyOrientation(c);
    }

    private void applyOrientation(Configuration c) {
        boolean land = c.orientation == Configuration.ORIENTATION_LANDSCAPE;
        tabConn.setOrientation(land ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        LinearLayout.LayoutParams a = (LinearLayout.LayoutParams) dashScroll.getLayoutParams();
        LinearLayout.LayoutParams b = (LinearLayout.LayoutParams) connScroll.getLayoutParams();
        if (land) { a.width = 0; a.height = ViewGroup.LayoutParams.MATCH_PARENT; a.weight = 1.1f; b.width = 0; b.height = ViewGroup.LayoutParams.MATCH_PARENT; b.weight = 1f; }
        else { a.width = ViewGroup.LayoutParams.MATCH_PARENT; a.height = ViewGroup.LayoutParams.WRAP_CONTENT; a.weight = 0; b.width = ViewGroup.LayoutParams.MATCH_PARENT; b.height = 0; b.weight = 1f; }
        dashScroll.setLayoutParams(a); connScroll.setLayoutParams(b);
    }

    /** 10 Hz UI refresh: coalesces log / gauge updates. */
    private final Runnable uiTick = new Runnable() {
        @Override public void run() {
            if (logDirty) { logDirty = false; logText.setText(logBuf); if (currentTab == 5) logScroll.post(new Runnable() { @Override public void run() { logScroll.fullScroll(View.FOCUS_DOWN); } }); }
            if (ecuDirty) { ecuDirty = false; refreshEcu(); }
            if (tcmDirty) { tcmDirty = false; refreshTcm(); }
            if (smokeDirty) { smokeDirty = false; refreshSmoke(); }
            h.postDelayed(this, 120);
        }
    };

    // ================================================================== tabs

    private void buildTabs() {
        LinearLayout bar = (LinearLayout) findViewById(R.id.tabBar);
        for (int i = 0; i < TAB_NAMES.length; i++) {
            final int idx = i;
            Button t = new Button(this, null, 0, R.style.Tab);
            t.setText(TAB_NAMES[i]);
            t.setMinWidth(dp(96));
            t.setGravity(Gravity.CENTER);
            t.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { selectTab(idx); } });
            bar.addView(t, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(40)));
            tabs.add(t);
        }
    }

    private void selectTab(int i) {
        currentTab = i;
        for (int k = 0; k < tabs.size(); k++) {
            tabs.get(k).setSelected(k == i);
            tabs.get(k).setTextColor(k == i ? C_ORANGE : C_DIM);
            pages[k].setVisibility(k == i ? View.VISIBLE : View.GONE);
        }
        if (i == 3) buildActuators();
        if (i == 5) { logText.setText(logBuf); logScroll.post(new Runnable() { @Override public void run() { logScroll.fullScroll(View.FOCUS_DOWN); } }); }
    }

    // ================================================================== buttons

    private void wireButtons() {
        View.OnClickListener connect = new View.OnClickListener() { @Override public void onClick(View v) { onConnectClicked(); } };
        btnConnect.setOnClickListener(connect);
        btnTopConnect.setOnClickListener(connect);
        btnDisconnect.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { doDisconnect(); } });
        btnSim.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
            host.setText("10.0.2.2"); port.setText("35000");
            toast("PC simülatörü: emülatör 10.0.2.2:35000 (wjdiag_sim.py çalışıyor olmalı)");
        } });
        btnBt.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { pickBluetooth(); } });
        btnLive.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
            if (diag.isPollingLive) { diag.stopLiveData(); return; }
            if (selectedModule == WJModule.KLINE_TCM) diag.startTCMLiveData(); else diag.startECULiveData();
        } });
        btnDtcRead.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
            diag.stopLiveData(); diag.readDTCs(DTC_MODULES[dtcSource]);
        } });
        btnDtcClear.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
            final WJModule m = DTC_MODULES[dtcSource];
            new AlertDialog.Builder(MainActivity.this).setTitle("Arıza kodları silinsin mi?")
                .setMessage(m.displayName + " modülündeki arıza kodları silinecek.")
                .setNegativeButton("Vazgeç", null)
                .setPositiveButton("Sil", new android.content.DialogInterface.OnClickListener() {
                    @Override public void onClick(android.content.DialogInterface d, int w) { diag.stopLiveData(); diag.clearDTCs(m); }
                }).show();
        } });
        btnSmokeStart.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { smokeNotice.setText(""); diag.startSmokeTest(); } });
        btnSmokeStop.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { diag.stopSmokeTest(); } });
        btnSmokeMark.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { diag.smokeTestMark(); } });
        btnSmokeClear.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { diag.clearSmokeTest(); smokeNotice.setText(""); } });
        findViewById(R.id.btnSmokeWa).setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { shareText(diag.smoke.reportText(), "com.whatsapp"); } });
        findViewById(R.id.btnSmokeShare).setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { shareFile(diag.smoke.fileName(), diag.smoke.reportText()); } });
        findViewById(R.id.btnSmokeCopy).setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
            ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            cm.setPrimaryClip(ClipData.newPlainText("smoke", diag.smoke.reportText()));
            smokeNotice.setText("Rapor panoya kopyalandı");
        } });
        findViewById(R.id.btnLogClear).setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { logBuf.setLength(0); elm.clearLog(); logText.setText(""); } });
        findViewById(R.id.btnLogShare).setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { shareFile("WJDiag_log.txt", logBuf.toString()); } });
        findViewById(R.id.btnRawSend).setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { sendRaw(); } });
        rawCmd.setOnEditorActionListener(new TextView.OnEditorActionListener() {
            @Override public boolean onEditorAction(TextView v, int a, android.view.KeyEvent e) { if (a == EditorInfo.IME_ACTION_SEND) { sendRaw(); return true; } return false; }
        });
    }

    private void sendRaw() {
        String c = rawCmd.getText().toString().trim();
        if (c.isEmpty()) return;
        if (!elm.isReady()) { toast("Önce bağlanın"); return; }
        rawCmd.setText("");
        diag.sendCustomCommand(c);
    }

    private void onConnectClicked() {
        if (elm.getState() == Elm327.State.CONNECTING) { elm.disconnect(); return; }
        if (elm.isReady()) { doDisconnect(); return; }
        String hs = host.getText().toString().trim();
        int p;
        try { p = Integer.parseInt(port.getText().toString().trim()); } catch (NumberFormatException e) { p = 35000; }
        if (hs.isEmpty()) hs = "192.168.0.10";
        prefs.edit().putString("host", hs).putInt("port", p).apply();
        elm.connect(new Transports.Tcp(hs, p));
    }

    private void doDisconnect() {
        diag.stopLiveData();
        diag.setActiveModule(null);
        selectedModule = null;
        elm.disconnect();
        refreshModuleRows();
    }

    // ================================================================== Bluetooth

    private void pickBluetooth() {
        final BluetoothAdapter ad = BluetoothAdapter.getDefaultAdapter();
        if (ad == null) { toast("Bu cihazda Bluetooth yok"); return; }
        if (!ad.isEnabled()) { startActivity(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)); return; }
        final List<BluetoothDevice> devs = new ArrayList<>();
        final List<String> names = new ArrayList<>();
        try { for (BluetoothDevice d : ad.getBondedDevices()) { devs.add(d); names.add((d.getName() != null ? d.getName() : "?") + "  (" + d.getAddress() + ")  [SPP]"); } }
        catch (SecurityException e) { toast("Bluetooth izni yok"); }
        names.add("BLE cihaz tara… (VLink, iOS-Vlink, LELink)");
        new AlertDialog.Builder(this).setTitle("Bluetooth ELM327 seç")
            .setItems(names.toArray(new String[0]), new android.content.DialogInterface.OnClickListener() {
                @Override public void onClick(android.content.DialogInterface d, int w) {
                    if (w < devs.size()) elm.connect(new Transports.Spp(devs.get(w)));
                    else scanBle(ad);
                }
            }).setNegativeButton("Vazgeç", null).show();
    }

    private void scanBle(final BluetoothAdapter ad) {
        if (Build.VERSION.SDK_INT >= 23 && checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION}, 7);
            toast("BLE taraması için konum izni verin, sonra tekrar deneyin");
            return;
        }
        final BluetoothLeScanner sc = ad.getBluetoothLeScanner();
        if (sc == null) { toast("BLE tarayıcı yok"); return; }
        final List<BluetoothDevice> found = new ArrayList<>();
        final List<String> names = new ArrayList<>();
        final AlertDialog dlg = new AlertDialog.Builder(this).setTitle("BLE taranıyor (8 sn)…").setMessage("Cihaz aranıyor").setNegativeButton("Vazgeç", null).show();
        final ScanCallback cb = new ScanCallback() {
            @Override public void onScanResult(int type, ScanResult r) {
                BluetoothDevice d = r.getDevice();
                for (BluetoothDevice x : found) if (x.getAddress().equals(d.getAddress())) return;
                String n = d.getName();
                if (n == null && r.getScanRecord() != null) n = r.getScanRecord().getDeviceName();
                if (n == null) return;
                found.add(d); names.add(n + "  (" + d.getAddress() + ")");
                dlg.setMessage(TextUtils.join("\n", names));
            }
        };
        try { sc.startScan(cb); } catch (SecurityException e) { toast("Bluetooth izni yok"); return; }
        h.postDelayed(new Runnable() { @Override public void run() {
            try { sc.stopScan(cb); } catch (Exception ignored) {}
            dlg.dismiss();
            if (found.isEmpty()) { toast("BLE cihaz bulunamadı"); return; }
            new AlertDialog.Builder(MainActivity.this).setTitle("BLE cihaz seç")
                .setItems(names.toArray(new String[0]), new android.content.DialogInterface.OnClickListener() {
                    @Override public void onClick(android.content.DialogInterface d, int w) { elm.connect(new Transports.Ble(MainActivity.this, found.get(w))); }
                }).setNegativeButton("Vazgeç", null).show();
        } }, 8000);
    }

    // ================================================================== Elm327.Listener

    @Override public void onState(Elm327.State s) {
        int col; String txt;
        switch (s) {
            case READY: col = C_GREEN; txt = "Bağlı"; break;
            case CONNECTING: col = C_AMBER; txt = "Bağlanıyor…"; break;
            case ERROR: col = C_RED; txt = "Hata"; break;
            default: col = 0xFF666666; txt = "Bağlı değil";
        }
        setDot(stateDot, col);
        if (s != Elm327.State.READY) { diag.onDisconnected(); selectedModule = null; refreshModuleRows(); }
        refreshEnabled();
        updateStateText(txt);
    }

    private void updateStateText(String base) {
        String m = selectedModule != null ? "  |  " + selectedModule.displayName : "";
        stateText.setText(base + m);
    }

    @Override public void onLog(String line) {
        logBuf.append(line).append('\n');
        if (logBuf.length() > 120000) logBuf.delete(0, logBuf.length() - 100000);
        logDirty = true;
    }

    private void refreshEnabled() {
        boolean ready = elm.isReady();
        Elm327.State s = elm.getState();
        btnTopConnect.setText(ready ? "KES" : s == Elm327.State.CONNECTING ? "İPTAL" : "BAĞLAN");
        btnConnect.setText(ready ? "Kes" : s == Elm327.State.CONNECTING ? "İptal" : "Bağlan");
        btnDisconnect.setVisibility(View.GONE);
        host.setEnabled(!ready && s != Elm327.State.CONNECTING); port.setEnabled(host.isEnabled());
        btnBt.setEnabled(!ready && s != Elm327.State.CONNECTING);
        btnLive.setEnabled(ready && !switching);
        btnDtcRead.setEnabled(ready && !diag.smoke.isRecording); btnDtcClear.setEnabled(ready && !diag.smoke.isRecording);
        btnSmokeStart.setEnabled(ready);
        for (Button c : ctrlChips) c.setEnabled(ready && !switching);
        for (Map.Entry<WJModule, View> e : moduleRows.entrySet()) { e.getValue().setEnabled(ready && !switching); e.getValue().setAlpha(ready && !switching ? 1f : 0.45f); }
        setDot(liveDot, diag.isPollingLive ? C_GREEN : 0xFF666666);
        liveText.setText(diag.isPollingLive ? (diag.smoke.isRecording ? "CANLI (duman testi)" : "CANLI") : "Durdu");
        liveText.setTextColor(diag.isPollingLive ? C_GREEN : C_DIM);
        btnLive.setText(diag.isPollingLive ? "Durdur" : "Canlı Başlat");
        btnLive.setBackgroundResource(diag.isPollingLive ? R.drawable.btn_danger : R.drawable.btn_accent);
        btnLive.setTextColor(diag.isPollingLive ? Color.WHITE : 0xFF111111);
    }

    // ================================================================== WJDiag.Listener

    @Override public void onEcuUpdate() { ecuDirty = true; }
    @Override public void onTcmUpdate() { tcmDirty = true; }
    @Override public void onDtcUpdate() { refreshDtc(); }
    @Override public void onPollingChanged(boolean p) { refreshEnabled(); smokeDirty = true; }
    @Override public void onSmokeUpdate() { smokeDirty = true; }

    // ================================================================== dashboards

    private TextView gauge(LinearLayout row, String key, String title, String unit, float weight) {
        LinearLayout cell = new LinearLayout(this);
        cell.setOrientation(LinearLayout.VERTICAL);
        cell.setGravity(Gravity.CENTER);
        cell.setBackgroundResource(R.drawable.cell_bg);
        cell.setPadding(dp(2), dp(5), dp(2), dp(5));
        TextView t = text(title, 10, C_DIM, false);
        TextView v = text("-", 19, C_GREEN, true); v.setTypeface(Typeface.MONOSPACE, Typeface.BOLD); v.setSingleLine(true);
        TextView u = text(unit, 9, 0xFF777780, false);
        cell.addView(t); cell.addView(v); cell.addView(u);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, weight);
        lp.setMargins(dp(2), dp(2), dp(2), dp(2));
        row.addView(cell, lp);
        gauges.put(key, v);
        return v;
    }

    private LinearLayout row(LinearLayout parent) {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        parent.addView(r, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return r;
    }

    private LinearLayout bigCell(LinearLayout row, String key, String title, String unit, String key2, String key3, float weight) {
        LinearLayout cell = new LinearLayout(this);
        cell.setOrientation(LinearLayout.VERTICAL);
        cell.setGravity(Gravity.CENTER);
        cell.setBackgroundResource(R.drawable.cell_big);
        cell.setPadding(dp(4), dp(6), dp(4), dp(6));
        cell.addView(text(title, 11, C_DIM, false));
        TextView v = text("-", 44, C_GREEN, true); v.setTypeface(Typeface.MONOSPACE, Typeface.BOLD); v.setSingleLine(true);
        cell.addView(v); gauges.put(key, v);
        TextView u = text(unit, 10, C_DIM, false); cell.addView(u); gauges.put(key + ".unit", u);
        if (key2 != null) { TextView v2 = text("", 20, C_CYAN, true); v2.setTypeface(Typeface.MONOSPACE, Typeface.BOLD); cell.addView(v2); gauges.put(key2, v2); }
        if (key3 != null) { TextView v3 = text("", 13, C_CYAN, false); v3.setTypeface(Typeface.MONOSPACE); cell.addView(v3); gauges.put(key3, v3); }
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, weight);
        lp.setMargins(dp(2), dp(2), dp(2), dp(2));
        row.addView(cell, lp);
        return cell;
    }

    private LinearLayout column(LinearLayout row, float weight) {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        row.addView(c, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, weight));
        return c;
    }

    private void buildEcuDash() {
        LinearLayout top = row(ecuDash);
        LinearLayout left = column(top, 1f);
        LinearLayout lr1 = row(left); gauge(lr1, "e.speed", "HIZ", "km/h", 1f);
        LinearLayout lr2 = row(left); gauge(lr2, "e.rpm", "DEVİR", "rpm", 1f);
        bigCell(top, "e.fuel", "YAKIT", "L/sa", "e.fuelL", "e.fuelPct", 1.3f);
        LinearLayout right = column(top, 1f);
        LinearLayout rr1 = row(right); gauge(rr1, "e.injq", "ENJ-Q", "mg/str", 1f);
        LinearLayout rr2 = row(right); gauge(rr2, "e.rail", "RAIL", "bar", 1f);
        LinearLayout r2 = row(ecuDash);
        gauge(r2, "e.boost", "BOOST", "bar", 1f); gauge(r2, "e.temp", "M-SICAK", "°C", 1f); gauge(r2, "e.maf", "MAF", "mg/str", 1f); gauge(r2, "e.batt", "AKÜ", "V", 1f);
        LinearLayout r3 = row(ecuDash);
        gauge(r3, "e.pedal", "PEDAL", "%", 1f); gauge(r3, "e.bset", "B-HEDEF", "bar", 1f); gauge(r3, "e.iat", "EMME HAVA", "°C", 1f); gauge(r3, "e.gear", "VİTES", "0x36", 1f);
        LinearLayout r4 = row(ecuDash);
        gauge(r4, "e.cyl", "SİLİNDİR RPM", "1-5", 2f); gauge(r4, "e.corr", "ENJ DÜZELTME (silindir 1-5)", "mg/str  (+ yakıt ekleniyor, − kısılıyor)", 2f);
        LinearLayout r5 = row(ecuDash);
        gauge(r5, "e.egr", "EGR", "%", 1f); gauge(r5, "e.wg", "WASTEGATE", "%", 1f); gauge(r5, "e.fsens", "YAKIT SENS", "V", 1f); gauge(r5, "e.af", "A/F", "hava/yakıt", 1f);
    }

    private void buildTcmDash() {
        LinearLayout top = row(tcmDash);
        LinearLayout left = column(top, 1f);
        LinearLayout lr1 = row(left); gauge(lr1, "t.speed", "HIZ", "km/h", 1f);
        LinearLayout lr2 = row(left); gauge(lr2, "t.temp", "ŞANZ-SICAK", "°C", 1f);
        bigCell(top, "t.gear", "VİTES", "", "t.sel", null, 1.3f);
        LinearLayout right = column(top, 1f);
        LinearLayout rr1 = row(right); gauge(rr1, "t.turb", "TÜRBİN", "rpm", 1f);
        LinearLayout rr2 = row(right); gauge(rr2, "t.limp", "LIMP", "", 1f);
        LinearLayout r2 = row(tcmDash);
        gauge(r2, "t.line", "HAT-P", "bar", 1f); gauge(r2, "t.tcc", "TCC KAYMA", "rpm", 1f); gauge(r2, "t.sol", "SOL V", "V", 1f); gauge(r2, "t.batt", "AKÜ", "V", 1f);
        LinearLayout r3 = row(tcmDash);
        gauge(r3, "t.eng", "MOTOR", "rpm", 1f); gauge(r3, "t.n2", "N2 GİRİŞ", "rpm", 1f); gauge(r3, "t.out", "ÇIKIŞ", "rpm", 1f); gauge(r3, "t.mod", "MOD-P", "bar", 1f);
    }

    private void set(String key, String val) { TextView t = gauges.get(key); if (t != null) t.setText(val); }
    private void set(String key, String val, int color) { TextView t = gauges.get(key); if (t != null) { t.setText(val); t.setTextColor(color); } }
    private static String f(String fmt, double v) { return String.format(Locale.US, fmt, v); }

    private void refreshEcu() {
        EcuStatus e = diag.ecu;
        set("e.speed", f("%.0f", e.vehicleSpeed));
        set("e.rpm", f("%.0f", e.rpm), e.rpm > 4500 ? C_RED : e.rpm > 3500 ? C_ORANGE : C_GREEN);
        boolean moving = e.vehicleSpeed > 5;
        set("e.fuel", f("%.1f", moving ? e.fuelLPer100km : e.fuelFlowLH));
        set("e.fuel.unit", moving ? "L/100km" : "L/sa");
        if (e.fuelLevel > 0) {
            double liters = e.fuelLevel * 78.7 / 100.0;
            int col = liters < 10 ? C_RED : liters < 20 ? C_ORANGE : C_CYAN;
            set("e.fuelL", f("%.1f L", liters), col); set("e.fuelPct", f("(%%%.0f depo)", e.fuelLevel), col);
        } else { set("e.fuelL", ""); set("e.fuelPct", ""); }
        set("e.injq", f("%.1f", e.fuelQuantity > 0 ? e.fuelQuantity : e.injectionQty));
        set("e.rail", f("%.0f", e.railPressure), e.railPressure > 1400 ? C_RED : C_GREEN);
        set("e.boost", f("%.2f", e.boostPressure), e.boostPressure > 2.0 ? C_RED : C_GREEN);
        set("e.temp", f("%.0f", e.coolantTemp), e.coolantTemp > 105 ? C_RED : e.coolantTemp > 95 ? C_ORANGE : C_GREEN);
        set("e.maf", f("%.0f", e.mafFlow));
        set("e.batt", e.batteryVoltage > 0 ? f("%.1f", e.batteryVoltage) : "-", e.batteryVoltage > 0 && e.batteryVoltage < 11.5 ? C_RED : C_GREEN);
        set("e.pedal", f("%.0f", e.pedalPos), e.pedalPos > 60 ? C_ORANGE : C_GREEN);
        set("e.bset", f("%.2f", e.boostSetpoint), (e.boostSetpoint - e.boostPressure) > 0.4 && e.pedalPos > 50 ? C_RED : C_GREEN);
        set("e.iat", f("%.0f", e.iat), e.iat > 60 ? C_ORANGE : C_GREEN);
        set("e.gear", e.gear == 0 ? "P/N" : String.valueOf(e.gear));
        StringBuilder cyl = new StringBuilder();
        for (int i = 0; i < 5; i++) { if (i > 0) cyl.append(' '); cyl.append((int) e.cylRPMs[i]); }
        set("e.cyl", cyl.toString());
        double maxCorr = 0; StringBuilder corr = new StringBuilder();
        for (int i = 0; i < 5; i++) { if (i > 0) corr.append(" "); corr.append(f("%+.2f", e.injCorrections[i])); maxCorr = Math.max(maxCorr, Math.abs(e.injCorrections[i])); }
        set("e.corr", corr.toString(), maxCorr > 3 ? C_RED : C_GREEN);
        set("e.egr", diag.ecuSecurityUnlocked ? f("%.0f", e.egrDuty) : "kilit", C_GREEN);
        set("e.wg", diag.ecuSecurityUnlocked ? f("%.0f", e.wastegateDuty) : "kilit", C_GREEN);
        set("e.fsens", f("%.2f", e.fuelSensorVoltage));
        double fuel = e.injectionQty; double af = fuel > 0.5 ? e.mafFlow / fuel : 0;
        set("e.af", af > 0 ? f("%.1f", af) : "-", af == 0 ? C_DIM : af < 15 ? C_RED : af < 17 ? C_ORANGE : C_GREEN);
        TextView v = gauges.get("e.cyl"); if (v != null) v.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        TextView c = gauges.get("e.corr"); if (c != null) c.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
    }

    private void refreshTcm() {
        TcmStatus t = diag.tcm;
        set("t.speed", f("%.0f", t.vehicleSpeed));
        set("t.temp", f("%.0f", t.transTemp), t.transTemp > 105 ? C_RED : t.transTemp > 95 ? C_ORANGE : C_GREEN);
        int gc = t.gear.isDrive() ? C_GREEN : t.gear == Gear.LIMP ? C_RED : t.gear == Gear.UNKNOWN ? C_DIM : C_AMBER;
        set("t.gear", t.gear.label, gc);
        String sel = t.selector == 8 ? "P" : t.selector == 7 ? "R" : t.selector == 6 ? "N" : t.selector == 5 ? "D" : "-";
        set("t.sel", "Kol: " + sel);
        set("t.turb", f("%.0f", t.turbineRPM));
        set("t.limp", "Normal", C_GREEN);
        set("t.line", f("%.2f", t.shiftPressure));
        set("t.tcc", f("%.0f", t.actualTCCSlip));
        set("t.sol", f("%.1f", t.solenoidVoltage), t.solenoidVoltage < 9 ? C_RED : t.solenoidVoltage < 11 ? C_ORANGE : C_GREEN);
        set("t.batt", t.batteryVoltage > 0 ? f("%.1f", t.batteryVoltage) : "-", t.batteryVoltage > 0 && t.batteryVoltage < 11.5 ? C_RED : C_GREEN);
        set("t.eng", f("%.0f", t.engineRPM)); set("t.n2", f("%.0f", t.inputN2)); set("t.out", f("%.0f", t.outputRPM)); set("t.mod", f("%.2f", t.modulationPressure));
    }

    // ================================================================== modules

    private void buildModuleList() {
        int n = 1;
        for (final WJModule m : WJModule.values()) {
            LinearLayout rowV = new LinearLayout(this);
            rowV.setOrientation(LinearLayout.HORIZONTAL);
            rowV.setGravity(Gravity.CENTER_VERTICAL);
            rowV.setBackgroundResource(R.drawable.module_row);
            rowV.setPadding(dp(10), dp(6), dp(10), dp(6));
            View dot = new View(this); setDot(dot, 0xFF555560);
            rowV.addView(dot, new LinearLayout.LayoutParams(dp(7), dp(7)));
            LinearLayout col = new LinearLayout(this); col.setOrientation(LinearLayout.VERTICAL); col.setPadding(dp(8), 0, 0, 0);
            TextView label = text(n + ". " + m.displayName, 13, 0xFFECECEC, true); label.setGravity(Gravity.START);
            TextView det = text(m.detail, 10, C_DIM, false); det.setTypeface(Typeface.MONOSPACE); det.setGravity(Gravity.START);
            col.addView(label); col.addView(det);
            rowV.addView(col, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            TextView chk = text("✓", 14, C_GREEN, true); chk.setVisibility(View.INVISIBLE);
            rowV.addView(chk);
            rowV.setTag(new View[]{dot, label, chk});
            rowV.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { toggleModule(m); } });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.setMargins(0, 0, 0, dp(3));
            moduleList.addView(rowV, lp);
            moduleRows.put(m, rowV);
            n++;
        }
    }

    private void refreshModuleRows() {
        for (Map.Entry<WJModule, View> e : moduleRows.entrySet()) {
            boolean sel = e.getKey() == selectedModule;
            View[] parts = (View[]) e.getValue().getTag();
            e.getValue().setSelected(sel);
            setDot(parts[0], sel ? C_GREEN : 0xFF555560);
            ((TextView) parts[1]).setTextColor(sel ? C_GREEN : 0xFFECECEC);
            parts[2].setVisibility(sel ? View.VISIBLE : View.INVISIBLE);
        }
        boolean tcm = selectedModule == WJModule.KLINE_TCM;
        ecuDash.setVisibility(tcm ? View.GONE : View.VISIBLE);
        tcmDash.setVisibility(tcm ? View.VISIBLE : View.GONE);
        dashTitle.setText(tcm ? "ŞANZIMAN (NAG1)" : "MOTOR (EDC15C2)");
        btnLive.setVisibility(selectedModule == null || selectedModule.bus == Bus.KLINE ? View.VISIBLE : View.INVISIBLE);
        updateStateText(elm.isReady() ? "Bağlı" : elm.getState() == Elm327.State.CONNECTING ? "Bağlanıyor…" : "Bağlı değil");
        if (currentTab == 3) buildActuators();
    }

    private void toggleModule(final WJModule m) {
        if (!elm.isReady() || switching) return;
        if (selectedModule == m) {
            diag.stopLiveData(); diag.setActiveModule(null); selectedModule = null; refreshModuleRows(); return;
        }
        switching = true; refreshEnabled();
        diag.stopLiveData();
        toast(m.displayName + " başlatılıyor…");
        diag.initModule(m, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                switching = false;
                if (ok) { selectedModule = m; diag.setActiveModule(m); toast(m.displayName + " hazır"); }
                else toast(m.displayName + " başlatılamadı (log sekmesine bakın)");
                refreshModuleRows(); refreshEnabled();
            }
        });
    }

    // ================================================================== DTC

    private void buildDtcSources() {
        for (int i = 0; i < DTC_MODULES.length; i++) {
            final int idx = i;
            Button b = chip(DTC_LABELS[i]);
            b.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { dtcSource = idx; refreshDtc(); } });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(38), 1f); lp.setMargins(dp(2), 0, dp(2), 0);
            dtcSources.addView(b, lp); dtcChips.add(b);
        }
        refreshDtc();
    }

    private Button chip(String label) {
        Button b = new Button(this, null, 0, R.style.Btn);
        b.setText(label); b.setBackgroundResource(R.drawable.chip); b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13); b.setTypeface(null, Typeface.BOLD);
        b.setAllCaps(false); b.setStateListAnimator(null); b.setTextColor(0xFFECECEC); b.setGravity(Gravity.CENTER);
        return b;
    }

    private void refreshDtc() {
        for (int i = 0; i < dtcChips.size(); i++) { dtcChips.get(i).setSelected(i == dtcSource); dtcChips.get(i).setTextColor(i == dtcSource ? 0xFF111111 : 0xFFECECEC); }
        WJModule m = DTC_MODULES[dtcSource];
        dtcList.removeAllViews();
        int n = 0;
        for (DtcEntry d : diag.dtcList) {
            if (d.module != m) continue;
            n++;
            LinearLayout r = new LinearLayout(this); r.setOrientation(LinearLayout.HORIZONTAL); r.setGravity(Gravity.CENTER_VERTICAL);
            r.setBackgroundResource(R.drawable.cell_bg); r.setPadding(dp(10), dp(8), dp(10), dp(8));
            TextView code = text(d.code, 17, C_ORANGE, true); code.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
            TextView desc = text(d.description, 12, C_DIM, false); desc.setPadding(dp(12), 0, 0, 0);
            r.addView(code); r.addView(desc, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT); lp.setMargins(0, 0, 0, dp(4));
            dtcList.addView(r, lp);
        }
        if (n == 0) {
            TextView t = text("✓  Kayıtlı arıza kodu yok", 14, C_GREEN, false); t.setGravity(Gravity.CENTER); t.setPadding(0, dp(30), 0, 0);
            dtcList.addView(t);
        }
        dtcCount.setText(m.displayName + ": " + n + " arıza kodu");
        dtcStatus.setText(diag.dtcStatus);
    }

    // ================================================================== controls (hold buttons)

    private void buildCtrlGroups() {
        String[] names = {"Sürücü Kapısı", "Yolcu Kapısı", "Body Ctrl"};
        for (int i = 0; i < names.length; i++) {
            final int idx = i;
            Button b = chip(names[i]);
            b.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { selectCtrlGroup(idx); } });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(40), 1f); lp.setMargins(dp(2), 0, dp(2), 0);
            ctrlGroups.addView(b, lp); ctrlChips.add(b);
        }
    }

    private void selectCtrlGroup(final int idx) {
        if (ctrlGroup == idx) { ctrlGroup = -1; refreshCtrl(); return; }
        final WJModule m = idx == 0 ? WJModule.DRIVER_DOOR : idx == 1 ? WJModule.PASSENGER_DOOR : WJModule.BODY_COMPUTER;
        switching = true; refreshEnabled();
        ctrlInfo.setText(m.displayName + " başlatılıyor…");
        diag.stopLiveData();
        diag.initModule(m, new Kwp2000.BoolCb() {
            @Override public void on(boolean ok) {
                switching = false;
                ctrlGroup = ok ? idx : -1;
                if (ok) { selectedModule = m; diag.setActiveModule(m); refreshModuleRows(); }
                ctrlInfo.setText(ok ? m.displayName + " hazır. Düğmeyi basılı tut: basınca AÇ, bırakınca KAPA." : m.displayName + " başlatılamadı");
                refreshCtrl(); refreshEnabled();
            }
        });
    }

    private void refreshCtrl() {
        for (int i = 0; i < ctrlChips.size(); i++) { ctrlChips.get(i).setSelected(i == ctrlGroup); ctrlChips.get(i).setTextColor(i == ctrlGroup ? 0xFF111111 : 0xFFECECEC); }
        ctrlGrid.removeAllViews();
        if (ctrlGroup < 0) return;
        List<ActDef> acts = new ArrayList<>();
        if (ctrlGroup == 0 || ctrlGroup == 1) {
            String hdr = ctrlGroup == 0 ? "ATSH24A02F" : "ATSH24A12F";
            acts.add(new ActDef("Ön Cam YUKARI", "38 01 12", "38 01 00", hdr)); acts.add(new ActDef("Ön Cam AŞAĞI", "38 02 12", "38 02 00", hdr));
            acts.add(new ActDef("Arka Cam YUKARI", "38 03 12", "38 03 00", hdr)); acts.add(new ActDef("Arka Cam AŞAĞI", "38 04 12", "38 04 00", hdr));
            acts.add(new ActDef("Kilitle", "38 05 12", "38 05 00", hdr)); acts.add(new ActDef("Kilit Aç", "38 06 12", "38 06 00", hdr));
            acts.add(new ActDef("Ayna YUKARI", "38 07 12", "38 07 00", hdr)); acts.add(new ActDef("Ayna AŞAĞI", "38 08 12", "38 08 00", hdr));
            acts.add(new ActDef("Ayna SOL", "38 09 12", "38 09 00", hdr)); acts.add(new ActDef("Ayna SAĞ", "38 0A 12", "38 0A 00", hdr));
        } else {
            String hd = "ATSH24402F";
            acts.add(new ActDef("Dörtlü Flaşör", "38 06 20", "38 06 00", hd)); acts.add(new ActDef("Korna", "38 0D 01", "38 0D 00", hd));
            acts.add(new ActDef("Uzun Far", "38 06 08", "38 06 00", hd)); acts.add(new ActDef("Park Lambası", "38 06 04", "38 06 00", hd));
            acts.add(new ActDef("Ön Sis", "38 06 02", "38 06 00", hd)); acts.add(new ActDef("Arka Sis", "38 06 10", "38 06 00", hd));
            acts.add(new ActDef("Silecek", "38 08 01", "38 08 00", hd)); acts.add(new ActDef("Uyarı Sesi", "38 02 01", "38 02 00", hd));
        }
        fillGrid(ctrlGrid, acts, 2);
    }

    // ================================================================== actuators

    private void buildActuators() {
        actGrid.removeAllViews();
        WJModule m = selectedModule;
        if (m == null) { actTitle.setText("Aktüatörler"); actInfo.setText("Bağlantı sekmesinden bir modül seçin (ECU, TCM, kapılar, BCM, gösterge, klima, SKIM, tavan)."); return; }
        List<ActDef> acts = actuatorsFor(m);
        actTitle.setText("Aktüatörler: " + m.displayName);
        if (acts.isEmpty()) { actInfo.setText("Bu modül için aktüatör testi yok."); return; }
        actInfo.setText("Basılı tut = AÇ/KAPA (hold), tek dokunuş = darbe komutu. Komutlar LOG sekmesinde görünür.");
        if (m == WJModule.MOTOR_ECU) {
            Button vin = new Button(this, null, 0, R.style.Btn); vin.setText("ECU kimliği / VIN oku (1A 90)"); vin.setBackgroundResource(R.drawable.btn_blue); vin.setTextColor(Color.WHITE); vin.setAllCaps(false); vin.setStateListAnimator(null); vin.setGravity(Gravity.CENTER);
            vin.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { diag.readEcuId(new Elm327.Callback() { @Override public void onResponse(String r) { toast(r); } }); } });
            actGrid.addView(vin, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(44)));
        }
        fillGrid(actGrid, acts, 2);
    }

    private List<ActDef> actuatorsFor(WJModule m) {
        List<ActDef> a = new ArrayList<>();
        switch (m) {
            case DRIVER_DOOR: doorActs(a, "ATSH24A02F"); break;
            case PASSENGER_DOOR: doorActs(a, "ATSH24A12F"); break;
            case BODY_COMPUTER: {
                String hd = "ATSH24402F";
                String[][] d = {{"VTSS Lambası","38 07 01","38 07 00"},{"Ön Sis","38 06 02","38 06 00"},{"Uyarı Sesi","38 02 01","38 02 00"},{"Uzun Far","38 06 08","38 06 00"},
                        {"Arka Sis","38 06 10","38 06 00"},{"Dörtlü Flaşör","38 06 20","38 06 00"},{"Silecek","38 08 01","38 08 00"},{"Park Lambası","38 06 04","38 06 00"},
                        {"Korna","38 0D 01","38 0D 00"},{"Viper Rölesi","38 08 01","38 08 00"}};
                for (String[] x : d) a.add(new ActDef(x[0], x[1], x[2], hd));
                a.add(new ActDef("Kısa Far (3A)", "3A 02 FF", null, hd));
                a.add(new ActDef("Modül Reset", "01 05 00", null, "ATSH244011"));
                break;
            }
            case CLUSTER: {
                String hd = "ATSH246122";
                String[][] d = {{"Hız Göstergesi","3A 00 80","3A 00 00"},{"Devir Göstergesi","3A 00 40","3A 00 00"},{"3 Led","3A 00 20","3A 00 00"},{"4 Led","3A 00 10","3A 00 00"},
                        {"Yakıt / Drive","3A 00 08","3A 00 00"},{"Sıcaklık / Neutral","3A 00 04","3A 00 00"},{"Geri Led","3A 00 02","3A 00 00"},{"Park Led","3A 00 01","3A 00 00"},
                        {"Yağ / 4Hi Led","3A 01 01","3A 01 00"},{"T-Case Ntrl","3A 01 02","3A 01 00"},{"CE / 4Low Led","3A 01 04","3A 01 00"}};
                for (String[] x : d) a.add(new ActDef(x[0], x[1], x[2], hd));
                break;
            }
            case ATC:
                a.add(new ActDef("Modül Reset", "01 01 00", null, "ATSH249811")); a.add(new ActDef("Kendi Testi", "01 FF FF", null, "ATSH249830"));
                a.add(new ActDef("Mod MTR Full Def", "02 FF FF", null, "ATSH249830")); a.add(new ActDef("Mod MTR Full Panel", "03 FF FF", null, "ATSH249830"));
                a.add(new ActDef("Sürücü Blend Sıcak", "38 03 00", null, "ATSH24982F")); a.add(new ActDef("Sürücü Blend Soğuk", "38 04 00", null, "ATSH24982F"));
                a.add(new ActDef("Yolcu Blend Sıcak", "38 07 00", null, "ATSH24982F")); a.add(new ActDef("Yolcu Blend Soğuk", "38 08 00", null, "ATSH24982F"));
                a.add(new ActDef("Recirc Temiz Hava", "38 0B 00", null, "ATSH24982F")); a.add(new ActDef("Recirc İç Dolaşım", "38 0C 00", null, "ATSH24982F"));
                break;
            case SKIM:
                a.add(new ActDef("Modül Reset", "01 01 00", null, "ATSH24C011")); a.add(new ActDef("Gösterge Lambası", "38 00 01", "38 00 00", "ATSH24C02F"));
                a.add(new ActDef("SKIM VIN Oku", "28 10 00", null, "ATSH24C022"));
                break;
            case OVERHEAD:
                a.add(new ActDef("Kendi Testi 0x31", "01 00 00", null, "ATSH246831")); a.add(new ActDef("Kendi Testi 0x33", "01 00 00", null, "ATSH246833"));
                a.add(new ActDef("Modül Reset", "01 01 00", null, "ATSH246811"));
                break;
            case ABS:
                a.add(new ActDef("Pinion Faktörü", "02 00 00", null, "ATSH242810")); a.add(new ActDef("Fren Havası Al", "00 00 00", null, "ATSH242820"));
                a.add(new ActDef("LF Giriş Valfi", "01 02 00", null, "ATSH242811")); a.add(new ActDef("RF Giriş Valfi", "36 00 00", null, "ATSH242822"));
                a.add(new ActDef("LR Giriş Valfi", "01 FE FF", null, "ATSH242830")); a.add(new ActDef("ABS Testi Bitir", "02 00 00", null, "ATSH242810"));
                break;
            case MOTOR_ECU: {
                String[][] d = {{"EGR Solenoidi","30 11 07 13 88","30 11 07 00 00"},{"Kabin Isıtıcı","30 1C 07 27 10","30 1C 07 00 00"},
                        {"Kızdırma Rölesi 1","30 16 07 27 10","30 16 07 00 00"},{"Kızdırma Rölesi 2","30 17 07 27 10","30 17 07 00 00"},
                        {"A/C Kontrol","30 14 07 27 10","30 14 07 00 00"},{"SWIRL Solenoidi","30 1A 07 13 88","30 1A 07 00 00"},
                        {"Boost Basıncı","30 12 07 00 10","30 12 07 00 00"},{"Fan Düşük","30 18 07 08 34","30 18 07 00 00"},{"Fan Tam","30 18 07 21 34","30 18 07 00 00"}};
                for (String[] x : d) a.add(new ActDef(x[0], x[1], x[2], null));
                break;
            }
            case KLINE_TCM:
                a.add(new ActDef("Adaptasyon Sıfırla", "31 31", null, null)); a.add(new ActDef("Adaptasyon Kaydet", "31 32", null, null));
                a.add(new ActDef("Solenoid Testi", "30 10 07 00 02", "30 10 07 00 00", null)); a.add(new ActDef("Park Kilidi Sol.", "30 10 07 04 00", null, null));
                break;
            default: break;
        }
        return a;
    }

    private void doorActs(List<ActDef> a, String hdr) {
        String[][] d = {{"Tavan Lambası","38 00 12","38 00 00"},{"Ön Cam YUKARI","38 01 12","38 01 00"},{"Ön Cam AŞAĞI","38 02 12","38 02 00"},
                {"Arka Cam YUKARI","38 03 12","38 03 00"},{"Arka Cam AŞAĞI","38 04 12","38 04 00"},{"Kilitle","38 05 12","38 05 00"},{"Kilit Aç","38 06 12","38 06 00"},
                {"Ayna YUKARI","38 07 12","38 07 00"},{"Ayna AŞAĞI","38 08 12","38 08 00"},{"Ayna SOL","38 09 12","38 09 00"},{"Ayna SAĞ","38 0A 12","38 0A 00"},
                {"Ayna Katla İÇ","38 0B 12","38 0B 00"},{"Ayna Katla DIŞ","38 0C 12","38 0C 00"},{"Ayna Isıtıcı","38 0D 12","38 0D 00"},
                {"Düğme Aydınlatma","38 0E 12","38 0E 00"},{"Hafıza LED","38 0F 12","38 0F 00"}};
        for (String[] x : d) a.add(new ActDef(x[0], x[1], x[2], hdr));
    }

    private void fillGrid(LinearLayout grid, List<ActDef> acts, int cols) {
        LinearLayout r = null;
        for (int i = 0; i < acts.size(); i++) {
            if (i % cols == 0) r = row(grid);
            final ActDef a = acts.get(i);
            Button b = new Button(this, null, 0, R.style.Btn);
            b.setText(a.offCmd != null ? a.name : a.name + " ▸");
            b.setBackgroundResource(R.drawable.btn_hold); b.setTextColor(0xFFECECEC); b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
            b.setTypeface(null, Typeface.BOLD); b.setAllCaps(false); b.setStateListAnimator(null); b.setGravity(Gravity.CENTER);
            if (a.offCmd != null) {
                b.setOnTouchListener(new View.OnTouchListener() {
                    @Override public boolean onTouch(View v, MotionEvent ev) {
                        switch (ev.getActionMasked()) {
                            case MotionEvent.ACTION_DOWN: v.setPressed(true); diag.sendActuator(a.hdr, a.onCmd); return true;
                            case MotionEvent.ACTION_UP: case MotionEvent.ACTION_CANCEL: v.setPressed(false); diag.sendActuator(a.hdr, a.offCmd); return true;
                            default: return true;
                        }
                    }
                });
            } else {
                b.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { diag.sendActuator(a.hdr, a.onCmd); } });
            }
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(54), 1f); lp.setMargins(dp(3), dp(3), dp(3), dp(3));
            r.addView(b, lp);
        }
        if (r != null) while (r.getChildCount() % cols != 0) { View sp = new View(this); r.addView(sp, new LinearLayout.LayoutParams(0, dp(54), 1f)); }
    }

    // ================================================================== smoke test

    private void buildSmokeGrid() {
        LinearLayout r1 = row(smokeGrid);
        gauge(r1, "s.rpm", "DEVİR", "rpm", 1f); gauge(r1, "s.pedal", "PEDAL", "%", 1f); gauge(r1, "s.fuel", "YAKIT", "mg/str", 1f); gauge(r1, "s.maf", "MAF", "mg/str", 1f);
        LinearLayout r2 = row(smokeGrid);
        gauge(r2, "s.af", "A/F", "hava/yakıt", 1f); gauge(r2, "s.boost", "BOOST", "bar abs", 1f); gauge(r2, "s.bset", "B-HEDEF", "bar abs", 1f); gauge(r2, "s.rail", "RAIL", "bar", 1f);
        LinearLayout r3 = row(smokeGrid);
        gauge(r3, "s.temp", "M-SICAK", "°C", 1f); gauge(r3, "s.iat", "IAT", "°C", 1f); gauge(r3, "s.time", "SÜRE", "s", 1f); gauge(r3, "s.n", "ÖRNEK", "0 işaret", 1f);
    }

    private void refreshSmoke() {
        EcuStatus e = diag.ecu; SmokeTest s = diag.smoke;
        set("s.rpm", f("%.0f", e.rpm), e.rpm > 4500 ? C_RED : C_GREEN);
        set("s.pedal", f("%.0f", e.pedalPos), e.pedalPos > 60 ? C_ORANGE : C_GREEN);
        double fuel = e.injectionQty; double af = fuel > 0.5 ? e.mafFlow / fuel : 0;
        set("s.fuel", f("%.1f", fuel)); set("s.maf", f("%.0f", e.mafFlow));
        set("s.af", af > 0 ? f("%.1f", af) : "-", af == 0 ? C_DIM : af < 15 ? C_RED : af < 17 ? C_ORANGE : C_GREEN);
        set("s.boost", f("%.2f", e.boostPressure));
        set("s.bset", f("%.2f", e.boostSetpoint), (e.boostSetpoint - e.boostPressure) > 0.4 && e.pedalPos > 50 ? C_RED : C_GREEN);
        set("s.rail", f("%.0f", e.railPressure));
        set("s.temp", f("%.0f", e.coolantTemp), e.coolantTemp < 70 ? C_ORANGE : C_GREEN);
        set("s.iat", f("%.0f", e.iat));
        set("s.time", f("%.1f", s.duration()), s.isRecording ? C_GREEN : C_DIM);
        set("s.n", String.valueOf(s.samples.size()), s.isRecording ? C_GREEN : C_DIM);
        TextView nu = gauges.get("s.n"); if (nu != null && nu.getParent() instanceof LinearLayout) { View u = ((LinearLayout) nu.getParent()).getChildAt(2); if (u instanceof TextView) ((TextView) u).setText(s.marks.size() + " işaret"); }
        boolean rec = s.isRecording;
        btnSmokeStart.setVisibility(rec ? View.GONE : View.VISIBLE);
        btnSmokeStop.setVisibility(rec ? View.VISIBLE : View.GONE);
        btnSmokeMark.setVisibility(rec ? View.VISIBLE : View.GONE);
        btnSmokeClear.setVisibility(!rec && s.hasData() ? View.VISIBLE : View.GONE);
        smokeShareRow.setVisibility(!rec && s.hasData() ? View.VISIBLE : View.GONE);
        if (s.isInitializing()) smokeNotice.setText("ECU başlatılıyor, ilk tur bekleniyor…");
        else if (s.error != null) smokeNotice.setText(s.error);
        else if (rec) smokeNotice.setText("KAYIT: " + s.samples.size() + " örnek");
        else if (s.hasData()) smokeNotice.setText("Durdu: " + s.samples.size() + " örnek, " + f("%.1f", s.duration()) + " s. Raporu WhatsApp ile gönderin.");
        if (!rec && s.hasData()) {
            SmokeTest.Summary sum = s.summary();
            StringBuilder sb = new StringBuilder("ÖZET  (" + s.samples.size() + " örnek, " + f("%.1f", s.duration()) + " s)\n");
            for (String l : sum.lines) sb.append(l).append('\n');
            if (!sum.flags.isEmpty()) { sb.append("\n"); for (String fl : sum.flags) sb.append("! ").append(fl).append('\n'); }
            smokeSummary.setText(sb.toString().trim());
            smokeSummary.setVisibility(View.VISIBLE);
        } else smokeSummary.setVisibility(View.GONE);
        refreshEnabled();
    }

    // ================================================================== sharing

    private void shareText(String text, String pkg) {
        Intent i = new Intent(Intent.ACTION_SEND); i.setType("text/plain"); i.putExtra(Intent.EXTRA_TEXT, text);
        if (pkg != null) i.setPackage(pkg);
        try { startActivity(i); }
        catch (Exception e) { i.setPackage(null); startActivity(Intent.createChooser(i, "Raporu paylaş")); }
    }

    private void shareFile(String name, String content) {
        try {
            File dir = getExternalFilesDir(null);
            if (dir == null) dir = getFilesDir();
            File fl = new File(dir, name);
            OutputStreamWriter w = new OutputStreamWriter(new FileOutputStream(fl), "UTF-8"); w.write(content); w.close();
            Intent i = new Intent(Intent.ACTION_SEND); i.setType("text/plain");
            i.putExtra(Intent.EXTRA_STREAM, Uri.fromFile(fl)); i.putExtra(Intent.EXTRA_TEXT, content.length() > 60000 ? content.substring(0, 60000) : content);
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(i, "Dosyayı paylaş"));
            toast("Kaydedildi: " + fl.getAbsolutePath());
        } catch (Exception e) { toast("Paylaşım hatası: " + e.getMessage()); shareText(content, null); }
    }

    // ================================================================== helpers

    private TextView text(String s, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s); t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp); t.setTextColor(color);
        if (bold) t.setTypeface(null, Typeface.BOLD);
        t.setGravity(Gravity.CENTER_HORIZONTAL);
        return t;
    }

    private void setDot(View v, int color) {
        GradientDrawable d = new GradientDrawable(); d.setShape(GradientDrawable.OVAL); d.setColor(color);
        v.setBackground(d);
    }

    private int dp(int v) { return (int) (v * getResources().getDisplayMetrics().density + 0.5f); }
    private void toast(String s) { Toast.makeText(this, s, Toast.LENGTH_SHORT).show(); }
}
