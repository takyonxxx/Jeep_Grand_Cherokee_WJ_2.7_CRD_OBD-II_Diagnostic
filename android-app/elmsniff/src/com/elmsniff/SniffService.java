package com.elmsniff;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Foreground service: reads the ESP32 sniffer's text lines over USB-serial and writes
 *   elmsniff_<date>.pcap  (raw IPv4 + TCP, same layout as the ElmCap captures)
 *   elmsniff_<date>.txt   (timestamped TX/RX text, TX = towards the ELM)
 * into the app folder (temporary). "USB'ye gönder" in the activity copies the last session
 * to a USB stick afterwards (the stick usually shares the port with the ESP32).
 * Runs on while WJdiag-Pro is in front (the head unit would otherwise kill a background activity).
 */
public class SniffService extends Service {
    static final String EXTRA_DEVICE = "dev";
    static final String ACTION_STOP = "com.elmsniff.STOP";
    static final String ACTION_CMD = "com.elmsniff.CMD";
    static final String EXTRA_CMD = "cmd";

    // ---- shared state the activity polls
    static volatile boolean running = false;
    static volatile String status = "bekliyor";
    static volatile long frames = 0, ipFrames = 0, elmFrames = 0, lines = 0;
    static volatile long bytes = 0;              // ELM payload bytes captured this session
    static volatile long lastPacketMs = 0;       // wall clock of the last ELM packet
    static volatile String channelInfo = "";
    static volatile String pcapPath = "", txtPath = "";
    static final String PREFS = "elmsniff", P_PCAP = "lastPcap", P_TXT = "lastTxt";
    static final ArrayDeque<String> log = new ArrayDeque<>();
    private static final int LOG_MAX = 300;

    static void addLog(String s) {
        synchronized (log) { log.addLast(s); while (log.size() > LOG_MAX) log.removeFirst(); }
    }
    static List<String> logSnapshot() { synchronized (log) { return new ArrayList<>(log); } }

    private Thread mThread;
    private UsbSerial mSerial;
    private volatile boolean mStop = false;
    private PowerManager.WakeLock mWake;

    private FileOutputStream mPcap, mTxt;
    private final Map<String, Integer> mSeq = new HashMap<>();
    private int mElmPort = 35000;

    @Override public IBinder onBind(Intent i) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) { stopSelf(); return START_NOT_STICKY; }
        if (intent != null && ACTION_CMD.equals(intent.getAction())) {
            String c = intent.getStringExtra(EXTRA_CMD);
            if (c != null && mSerial != null) { mSerial.write((c + "\n").getBytes()); addLog("> " + c); }
            return START_STICKY;
        }
        UsbDevice dev = intent != null ? (UsbDevice) intent.getParcelableExtra(EXTRA_DEVICE) : null;
        if (dev == null) { stopSelf(); return START_NOT_STICKY; }
        startForeground(1, buildNotification());
        if (mThread != null && mThread.isAlive()) return START_STICKY;
        try {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            mWake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "elmsniff:usb");
            mWake.acquire();
        } catch (Exception e) {}
        final UsbDevice d = dev;
        mStop = false;
        mThread = new Thread(new Runnable() { @Override public void run() { readerLoop(d); } }, "elmsniff-usb");
        mThread.start();
        return START_STICKY;
    }

    private Notification buildNotification() {
        String ch = "elmsniff";
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            nm.createNotificationChannel(new NotificationChannel(ch, "ELM Sniff", NotificationManager.IMPORTANCE_LOW));
        }
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0);
        Notification.Builder b = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(this, ch) : new Notification.Builder(this);
        return b.setContentTitle("ELM Sniff kaydediyor").setContentText("ESP32 USB dinleyici aktif")
                .setSmallIcon(android.R.drawable.stat_sys_download).setContentIntent(pi).setOngoing(true).build();
    }

    // ------------------------------------------------------------------ files

    private void openFiles() throws IOException {
        String stamp = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(new Date());
        File dir = getExternalFilesDir(null);
        if (dir == null) dir = getFilesDir();
        File pc = new File(dir, "elmsniff_" + stamp + ".pcap"), tx = new File(dir, "elmsniff_" + stamp + ".txt");
        mPcap = new FileOutputStream(pc); mTxt = new FileOutputStream(tx);
        mPcap.write(pcapHeader());
        pcapPath = pc.getAbsolutePath(); txtPath = tx.getAbsolutePath();
        bytes = 0; elmFrames = 0; frames = 0; ipFrames = 0; lastPacketMs = 0;
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(P_PCAP, pcapPath).putString(P_TXT, txtPath).apply();
    }

    static File findUsbStick() {
        try {
            File[] vols = new File("/storage").listFiles();
            if (vols != null) for (File v : vols) {
                String n = v.getName();
                if (n.equals("emulated") || n.equals("self")) continue;
                if (v.canWrite()) return v;
            }
        } catch (Exception e) {}
        return null;
    }

    private static byte[] pcapHeader() {
        ByteBuffer b = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN);
        b.putInt(0xA1B2C3D4).putShort((short) 2).putShort((short) 4).putInt(0).putInt(0).putInt(65535).putInt(101);   // LINKTYPE_RAW
        return b.array();
    }

    private void writePcap(byte[] src, int sport, byte[] dst, int dport, byte[] payload) throws IOException {
        String key = sport + ">" + dport;
        Integer seq = mSeq.get(key); if (seq == null) seq = 1;
        int tcpLen = 20 + payload.length, ipLen = 20 + tcpLen;
        ByteBuffer b = ByteBuffer.allocate(16 + ipLen).order(ByteOrder.LITTLE_ENDIAN);
        long now = System.currentTimeMillis();
        b.putInt((int) (now / 1000)).putInt((int) ((now % 1000) * 1000)).putInt(ipLen).putInt(ipLen);
        b.order(ByteOrder.BIG_ENDIAN);
        b.put((byte) 0x45).put((byte) 0).putShort((short) ipLen).putShort((short) 0).putShort((short) 0x4000)
         .put((byte) 64).put((byte) 6).putShort((short) 0).put(src).put(dst);
        b.putShort((short) sport).putShort((short) dport).putInt(seq).putInt(0).put((byte) (5 << 4)).put((byte) 0x18)
         .putShort((short) 65535).putShort((short) 0).putShort((short) 0).put(payload);
        mSeq.put(key, seq + payload.length);
        byte[] rec = b.array();
        mPcap.write(rec); mPcap.flush();
    }

    private void writeTxt(String line) {
        byte[] d = (line + "\n").getBytes();
        try { mTxt.write(d); mTxt.flush(); } catch (IOException e) {}
    }

    private static byte[] ip4(String s) {
        String[] p = s.split("\\."); byte[] b = new byte[4];
        for (int i = 0; i < 4; i++) b[i] = (byte) Integer.parseInt(p[i]);
        return b;
    }

    private static byte[] unhex(String h) {
        byte[] b = new byte[h.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(h.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    // ------------------------------------------------------------------ reader

    private void readerLoop(UsbDevice dev) {
        running = true;
        try {
            status = "USB açılıyor";
            UsbManager mgr = (UsbManager) getSystemService(Context.USB_SERVICE);
            mSerial = new UsbSerial(mgr, dev);
            openFiles();
            status = "dinliyor";
            addLog("USB açıldı: " + dev.getDeviceName() + "  " + String.format("%04X:%04X", dev.getVendorId(), dev.getProductId()));
            addLog("kayıt: " + pcapPath);
            mSerial.write("scan\n".getBytes());
            byte[] buf = new byte[512];
            StringBuilder sb = new StringBuilder();
            while (!mStop) {
                int n = mSerial.read(buf, 300);
                for (int i = 0; i < n; i++) {
                    char c = (char) (buf[i] & 0xFF);
                    if (c == '\n' || c == '\r') { if (sb.length() > 0) { handleLine(sb.toString()); sb.setLength(0); } }
                    else if (sb.length() < 8192) sb.append(c);
                }
            }
        } catch (Exception e) {
            status = "hata: " + e.getMessage();
            addLog("hata: " + e);
        } finally {
            if (mSerial != null) mSerial.close();
            for (FileOutputStream f : new FileOutputStream[]{ mPcap, mTxt }) { try { if (f != null) f.close(); } catch (IOException e) {} }
            running = false;
            if (!status.startsWith("hata")) status = "durdu";
            try { if (mWake != null && mWake.isHeld()) mWake.release(); } catch (Exception e) {}
            stopForeground(true);
            stopSelf();
        }
    }

    private final SimpleDateFormat mTs = new SimpleDateFormat("HH:mm:ss.SSS", Locale.US);

    private void handleLine(String line) {
        lines++;
        if (line.startsWith("P ")) {
            try {
                String[] p = line.split(" ", 5);
                int c1 = p[2].lastIndexOf(':'), c2 = p[3].lastIndexOf(':');
                byte[] src = ip4(p[2].substring(0, c1)), dst = ip4(p[3].substring(0, c2));
                int sport = Integer.parseInt(p[2].substring(c1 + 1)), dport = Integer.parseInt(p[3].substring(c2 + 1));
                byte[] payload = unhex(p[4]);
                elmFrames++; bytes += payload.length; lastPacketMs = System.currentTimeMillis();
                writePcap(src, sport, dst, dport, payload);
                String text = new String(payload, "ISO-8859-1").replace("\r", "\\r").replace("\n", "\\n");
                String msg = mTs.format(new Date()) + " " + (dport == mElmPort ? "TX" : "RX") + " " + text;
                writeTxt(msg); addLog(msg);
            } catch (Exception e) { addLog("? " + line); }
        } else if (line.startsWith("S ")) {
            String[] p = line.split(" ");
            if (p.length >= 4) { try { frames = Long.parseLong(p[1]); ipFrames = Long.parseLong(p[2]); } catch (Exception e) {} }
            writeTxt("# " + mTs.format(new Date()) + " " + line);          // proves the serial link even with no ELM around
        } else if (line.startsWith("I ")) {
            channelInfo = line.substring(2); addLog("[esp32] " + line); writeTxt("# " + mTs.format(new Date()) + " " + line);
        } else {
            addLog("[esp32] " + line); writeTxt("# " + mTs.format(new Date()) + " " + line);   // scan results, errors
        }
    }

    @Override public void onDestroy() {
        mStop = true;
        super.onDestroy();
    }
}
