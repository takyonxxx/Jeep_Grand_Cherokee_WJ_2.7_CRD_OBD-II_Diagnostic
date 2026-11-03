package com.elmsniff;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.graphics.Typeface;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.List;
import java.util.Map;

/**
 * ELM Sniff: the ESP32 WiFi sniffer plugged into the head unit's USB port, the head unit
 * writes the pcap. Open the app, press "Başlat" (USB permission once), then switch to
 * WJdiag-Pro; the recording continues in the foreground service.
 */
public class MainActivity extends Activity {
    private static final String ACTION_PERM = "com.elmsniff.USB_PERMISSION";
    private static final int C_BG = Color.rgb(16, 18, 24), C_CARD = Color.rgb(28, 31, 40), C_TEXT = Color.rgb(236, 240, 248),
            C_DIM = Color.rgb(150, 160, 176), C_GREEN = Color.rgb(0, 224, 138), C_ORANGE = Color.rgb(255, 140, 26), C_RED = Color.rgb(255, 77, 77);

    private TextView mStatus, mCounters, mLog;
    private ScrollView mScroll;
    private EditText mCmd;
    private final Handler mH = new Handler();
    private UsbManager mUsb;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        mUsb = (UsbManager) getSystemService(Context.USB_SERVICE);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(C_BG);
        root.setPadding(dp(16), dp(10), dp(16), dp(10));

        TextView title = text("ELM Sniff", 22, C_ORANGE, true);
        root.addView(title);
        root.addView(text("ESP32 WiFi dinleyici → USB → bu teyp; WJdiag-Pro trafiği pcap'e yazılır", 13, C_DIM, false));

        mStatus = text("bekliyor", 18, C_TEXT, true);
        mStatus.setPadding(0, dp(8), 0, dp(4));
        root.addView(mStatus);
        mCounters = text("", 13, C_DIM, false);
        root.addView(mCounters);

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, dp(8), 0, dp(8));
        row.addView(button("▶  Başlat", Color.rgb(0, 110, 70), new View.OnClickListener() { @Override public void onClick(View v) { start(); } }));
        row.addView(button("■  Durdur", Color.rgb(140, 40, 40), new View.OnClickListener() { @Override public void onClick(View v) { stopService(new Intent(MainActivity.this, SniffService.class).setAction(SniffService.ACTION_STOP)); startService(new Intent(MainActivity.this, SniffService.class).setAction(SniffService.ACTION_STOP)); } }));
        row.addView(button("↻  scan", Color.rgb(60, 64, 76), new View.OnClickListener() { @Override public void onClick(View v) { sendCmd("scan"); } }));
        root.addView(row);

        LinearLayout cmdRow = new LinearLayout(this);
        cmdRow.setOrientation(LinearLayout.HORIZONTAL);
        mCmd = new EditText(this);
        mCmd.setHint("ESP32 komutu: chan 6 | ssid WiFi_OBDII | port 35000");
        mCmd.setTextColor(C_TEXT); mCmd.setHintTextColor(C_DIM); mCmd.setSingleLine(true);
        cmdRow.addView(mCmd, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        cmdRow.addView(button("Gönder", Color.rgb(60, 64, 76), new View.OnClickListener() { @Override public void onClick(View v) { sendCmd(mCmd.getText().toString()); mCmd.setText(""); } }));
        root.addView(cmdRow);

        mScroll = new ScrollView(this);
        mLog = new TextView(this);
        mLog.setTypeface(Typeface.MONOSPACE);
        mLog.setTextSize(12);
        mLog.setTextColor(C_TEXT);
        mLog.setBackgroundColor(C_CARD);
        mLog.setPadding(dp(8), dp(6), dp(8), dp(6));
        mScroll.addView(mLog);
        root.addView(mScroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(root);

        registerReceiver(mPermReceiver, new IntentFilter(ACTION_PERM));
        // Launched by the USB attach intent: start straight away
        UsbDevice attached = getIntent() != null ? (UsbDevice) getIntent().getParcelableExtra(UsbManager.EXTRA_DEVICE) : null;
        if (attached != null) startWith(attached);
        mH.post(mTick);
    }

    private final Runnable mTick = new Runnable() {
        @Override public void run() {
            boolean on = SniffService.running;
            mStatus.setText((on ? "● " : "○ ") + SniffService.status + (SniffService.channelInfo.isEmpty() ? "" : "   ·   AP: " + SniffService.channelInfo));
            mStatus.setTextColor(on ? C_GREEN : SniffService.status.startsWith("hata") ? C_RED : C_DIM);
            mCounters.setText("WiFi çerçeve " + SniffService.frames + "   ·   IP " + SniffService.ipFrames + "   ·   ELM paketi " + SniffService.elmFrames
                    + (SniffService.pcapPath.isEmpty() ? "" : "\n" + SniffService.pcapPath)
                    + (SniffService.usbPath.isEmpty() ? "" : "\nUSB bellek: " + SniffService.usbPath));
            List<String> l = SniffService.logSnapshot();
            String joined = TextUtils.join("\n", l);
            if (!joined.equals(mLog.getText().toString())) {
                mLog.setText(joined);
                mScroll.post(new Runnable() { @Override public void run() { mScroll.fullScroll(View.FOCUS_DOWN); } });
            }
            mH.postDelayed(this, 500);
        }
    };

    private void start() {
        if (SniffService.running) { Toast.makeText(this, "Zaten çalışıyor", Toast.LENGTH_SHORT).show(); return; }
        UsbDevice found = null;
        Map<String, UsbDevice> devs = mUsb.getDeviceList();
        for (UsbDevice d : devs.values()) if (UsbSerial.looksLikeSerial(d)) { found = d; break; }
        if (found == null) {
            SniffService.status = "USB seri cihaz yok (ESP32 takılı mı?)";
            StringBuilder sb = new StringBuilder("USB cihazları: ");
            for (UsbDevice d : devs.values()) sb.append(String.format("%04X:%04X ", d.getVendorId(), d.getProductId()));
            SniffService.addLog(sb.toString());
            return;
        }
        startWith(found);
    }

    private void startWith(UsbDevice d) {
        if (mUsb.hasPermission(d)) {
            Intent i = new Intent(this, SniffService.class).putExtra(SniffService.EXTRA_DEVICE, d);
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(i); else startService(i);
        } else {
            PendingIntent pi = PendingIntent.getBroadcast(this, 0, new Intent(ACTION_PERM), Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
            mUsb.requestPermission(d, pi);
            SniffService.status = "USB izni bekleniyor";
        }
    }

    private final BroadcastReceiver mPermReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            UsbDevice d = i.getParcelableExtra(UsbManager.EXTRA_DEVICE);
            if (d != null && i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) startWith(d);
            else SniffService.status = "USB izni verilmedi";
        }
    };

    private void sendCmd(String c) {
        if (c == null || c.trim().isEmpty()) return;
        startService(new Intent(this, SniffService.class).setAction(SniffService.ACTION_CMD).putExtra(SniffService.EXTRA_CMD, c.trim()));
    }

    @Override protected void onDestroy() {
        mH.removeCallbacks(mTick);
        try { unregisterReceiver(mPermReceiver); } catch (Exception e) {}
        super.onDestroy();
    }

    private TextView text(String s, int sp, int color, boolean bold) {
        TextView t = new TextView(this); t.setText(s); t.setTextSize(sp); t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        return t;
    }

    private Button button(String s, int bg, View.OnClickListener l) {
        Button b = new Button(this); b.setText(s); b.setTextColor(C_TEXT); b.setBackgroundColor(bg); b.setOnClickListener(l);
        b.setAllCaps(false); b.setMinHeight(dp(44));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMargins(0, 0, dp(10), 0); b.setLayoutParams(lp);
        return b;
    }

    private int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }
}
