package com.wjdiag.pro;

import android.os.Handler;
import android.os.Looper;

import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.TimeUnit;

/**
 * ELM327 link: one transport (WiFi TCP / Bluetooth SPP / BLE), a strictly serial
 * command queue, response framing on '>' and the J1850 noise filtering that the
 * real WJ bus needs (port of the iOS ELM327Connection).
 * All callbacks are delivered on the main thread.
 */
public final class Elm327 {

    public enum State { DISCONNECTED, CONNECTING, READY, ERROR }

    public interface Transport {
        void open() throws IOException;
        void write(byte[] data) throws IOException;
        /** Blocking read with timeout: >0 bytes, 0 on timeout, -1 on EOF. */
        int read(byte[] buf, int timeoutMs) throws IOException;
        void close();
        String describe();
    }

    public interface Callback { void onResponse(String response); }
    public interface Listener { void onState(State s); void onLog(String line); }

    private static final class Cmd {
        final String command; final int timeoutMs; final Callback cb; int retry;
        Cmd(String c, int t, Callback cb, int retry) { command = c; timeoutMs = t; this.cb = cb; this.retry = retry; }
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final LinkedBlockingDeque<Cmd> queue = new LinkedBlockingDeque<>();
    private final List<String> logLines = new ArrayList<>();
    private static final SimpleDateFormat TSF = new SimpleDateFormat("HH:mm:ss.SSS", Locale.US);

    private volatile State state = State.DISCONNECTED;
    private volatile Transport transport;
    private volatile Thread worker;
    private volatile boolean running;
    private volatile boolean inFlight;
    private volatile boolean isJ1850;
    private Listener listener;
    private volatile String currentCommand = "";

    public void setListener(Listener l) { listener = l; }
    public State getState() { return state; }
    public boolean isReady() { return state == State.READY; }
    public List<String> getLog() { synchronized (logLines) { return new ArrayList<>(logLines); } }
    public void clearLog() { synchronized (logLines) { logLines.clear(); } }

    // ------------------------------------------------------------------ connect

    public void connect(final Transport t) {
        disconnect();
        transport = t;
        setState(State.CONNECTING);
        log("Bağlanıyor: " + t.describe());
        running = true;
        worker = new Thread(new Runnable() {
            @Override public void run() {
                try {
                    t.open();
                } catch (Exception e) {
                    log("Bağlantı hatası: " + e.getMessage());
                    running = false;
                    t.close();
                    setState(State.ERROR);
                    return;
                }
                log("Bağlandı: " + t.describe());
                setState(State.READY);
                loop(t);
            }
        }, "elm-worker");
        worker.start();
    }

    public void disconnect() {
        running = false;
        Transport t = transport;
        transport = null;
        if (t != null) t.close();
        drainQueue("CANCELLED");
        Thread w = worker;
        if (w != null && w != Thread.currentThread()) {
            try { w.join(1500); } catch (InterruptedException ignored) {}
        }
        worker = null;
        inFlight = false;
        if (state != State.DISCONNECTED) setState(State.DISCONNECTED);
    }

    // ------------------------------------------------------------------ queue

    public void sendCommand(String cmd, Callback cb) { sendCommand(cmd, 5000, cb); }

    public void sendCommand(String cmd, int timeoutMs, Callback cb) {
        if (state != State.READY) {
            if (cb != null) postCb(cb, "DISCONNECTED");
            return;
        }
        queue.offer(new Cmd(cmd, timeoutMs, cb, 0));
    }

    /** Commands waiting or in flight. Pollers must not enqueue while this is non-zero. */
    public int pendingCommands() { return queue.size() + (inFlight ? 1 : 0); }

    /** Drop everything that has not been sent yet (the in-flight command keeps its response). */
    public void cancelQueuedCommands() {
        int n = queue.size();
        if (n == 0) return;
        log("[QUEUE] " + n + " bekleyen komut iptal edildi");
        drainQueue("CANCELLED");
    }

    private void drainQueue(String reply) {
        Cmd c;
        while ((c = queue.poll()) != null) if (c.cb != null) postCb(c.cb, reply);
    }

    public void sendRaw(String data) {
        Transport t = transport;
        if (t == null) return;
        try { t.write((data + "\r").getBytes("ISO-8859-1")); log("[TX] " + data); }
        catch (IOException e) { log("TX hata: " + e.getMessage()); }
    }

    // ------------------------------------------------------------------ worker

    private void loop(Transport t) {
        byte[] buf = new byte[4096];
        while (running && transport == t) {
            Cmd c;
            try { c = queue.poll(300, TimeUnit.MILLISECONDS); } catch (InterruptedException e) { break; }
            if (c == null) continue;
            inFlight = true;
            try {
                execute(t, c, buf);
            } catch (IOException e) {
                inFlight = false;
                if (running && transport == t) {
                    log("Bağlantı koptu: " + e.getMessage());
                    if (c.cb != null) postCb(c.cb, "DISCONNECTED");
                    running = false;
                    t.close();
                    drainQueue("DISCONNECTED");
                    setState(State.DISCONNECTED);
                }
                return;
            }
            inFlight = false;
        }
    }

    private void execute(Transport t, Cmd c, byte[] buf) throws IOException {
        String up = c.command.toUpperCase(Locale.US).replace(" ", "");
        if (up.startsWith("ATSP")) isJ1850 = up.equals("ATSP2");
        else if (up.startsWith("ATZ")) isJ1850 = false;
        currentCommand = c.command;
        t.write((c.command + "\r").getBytes("ISO-8859-1"));
        log("[TX] " + c.command);

        StringBuilder sb = new StringBuilder();
        long deadline = System.currentTimeMillis() + c.timeoutMs;
        boolean complete = false;
        while (System.currentTimeMillis() < deadline) {
            int wait = (int) Math.max(10, Math.min(500, deadline - System.currentTimeMillis()));
            int n = t.read(buf, wait);
            if (n < 0) throw new IOException("EOF");
            if (n == 0) continue;
            sb.append(new String(buf, 0, n, "ISO-8859-1"));
            if (sb.indexOf(">") >= 0) { complete = true; break; }
        }
        String parsed;
        if (!complete) {
            parsed = "TIMEOUT";
            log("[TIMEOUT] " + c.command);
        } else {
            parsed = parseResponse(sb.toString(), c.command);
            log("[RX] " + parsed.replace("\r", " | "));
            // NRC 0x21 busyRepeatRequest: retry up to 3 times
            if (Models.hasNRC(parsed, 0x21) && c.retry < 3) {
                c.retry++;
                log("[RETRY] NRC 0x21, deneme " + c.retry);
                try { Thread.sleep(100); } catch (InterruptedException ignored) {}
                queue.offerFirst(c);
                return;
            }
        }
        if (c.cb != null) postCb(c.cb, parsed);
    }

    private String parseResponse(String raw, String command) {
        String[] parts = raw.replace(">", "").replace("\r\n", "\r").replace("\n", "\r").split("\r");
        List<String> lines = new ArrayList<>();
        for (String p : parts) {
            String s = p.replace("ü", "").trim();
            if (!s.isEmpty()) lines.add(s);
        }
        // strip echo
        if (!lines.isEmpty()) {
            String cmd = command.toUpperCase(Locale.US);
            String first = lines.get(0).toUpperCase(Locale.US);
            String pre = cmd.substring(0, Math.min(4, cmd.length()));
            if (first.equals(cmd) || first.startsWith(pre)) lines.remove(0);
        }
        // filter unsolicited bus traffic
        List<String> kept = new ArrayList<>();
        for (String line : lines) {
            String u = line.toUpperCase(Locale.US);
            if (u.startsWith("2D ") || u.startsWith("2D28")) continue;
            if (isJ1850) {
                boolean hexLine = u.length() >= 2 && Models.isHex(u.charAt(0)) && Models.isHex(u.charAt(1))
                        && (u.length() == 2 || u.charAt(2) == ' ');
                if (hexLine && !u.startsWith("26 ")) continue;
            }
            kept.add(line);
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < kept.size(); i++) { if (i > 0) sb.append('\r'); sb.append(kept.get(i)); }
        return sb.toString();
    }

    // ------------------------------------------------------------------ helpers

    private void postCb(final Callback cb, final String r) {
        main.post(new Runnable() { @Override public void run() { cb.onResponse(r); } });
    }

    private void setState(final State s) {
        state = s;
        log("[STATE] " + s.name());
        main.post(new Runnable() { @Override public void run() { if (listener != null) listener.onState(s); } });
    }

    public void log(String msg) {
        final String line = "[" + TSF.format(new Date()) + "] " + msg;
        synchronized (logLines) {
            logLines.add(line);
            if (logLines.size() > 600) logLines.subList(0, logLines.size() - 600).clear();
        }
        main.post(new Runnable() { @Override public void run() { if (listener != null) listener.onLog(line); } });
    }
}
