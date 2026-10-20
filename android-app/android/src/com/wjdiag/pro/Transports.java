package com.wjdiag.pro;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.BluetoothSocket;
import android.content.Context;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/** WiFi (TCP), Bluetooth Classic (SPP) and BLE (FFF0/FFF1/FFF2) transports for {@link Elm327}. */
public final class Transports {
    private Transports() {}

    // ------------------------------------------------------------------ WiFi
    public static final class Tcp implements Elm327.Transport {
        private final String host; private final int port;
        private Socket sock; private InputStream in; private OutputStream out;
        public Tcp(String host, int port) { this.host = host; this.port = port; }
        @Override public void open() throws IOException {
            sock = new Socket();
            sock.connect(new InetSocketAddress(host, port), 6000);
            sock.setTcpNoDelay(true);
            in = sock.getInputStream(); out = sock.getOutputStream();
        }
        @Override public void write(byte[] d) throws IOException { out.write(d); out.flush(); }
        @Override public int read(byte[] buf, int timeoutMs) throws IOException {
            sock.setSoTimeout(timeoutMs);
            try { return in.read(buf); } catch (SocketTimeoutException e) { return 0; }
        }
        @Override public void close() { try { if (sock != null) sock.close(); } catch (IOException ignored) {} }
        @Override public String describe() { return "WiFi " + host + ":" + port; }
    }

    // ------------------------------------------------------------------ Bluetooth SPP
    public static final class Spp implements Elm327.Transport {
        private static final UUID SPP = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB");
        private final BluetoothDevice dev;
        private BluetoothSocket sock; private InputStream in; private OutputStream out;
        public Spp(BluetoothDevice d) { dev = d; }
        @Override public void open() throws IOException {
            BluetoothAdapter.getDefaultAdapter().cancelDiscovery();
            sock = dev.createRfcommSocketToServiceRecord(SPP);
            try { sock.connect(); }
            catch (IOException e) {
                // clone adapters: fall back to channel 1
                try {
                    sock = (BluetoothSocket) dev.getClass().getMethod("createRfcommSocket", int.class).invoke(dev, 1);
                    sock.connect();
                } catch (Exception e2) { throw new IOException("SPP bağlantısı kurulamadı: " + e.getMessage()); }
            }
            in = sock.getInputStream(); out = sock.getOutputStream();
        }
        @Override public void write(byte[] d) throws IOException { out.write(d); out.flush(); }
        @Override public int read(byte[] buf, int timeoutMs) throws IOException {
            long end = System.currentTimeMillis() + timeoutMs;
            while (System.currentTimeMillis() < end) {
                int av = in.available();
                if (av > 0) return in.read(buf, 0, Math.min(av, buf.length));
                try { Thread.sleep(15); } catch (InterruptedException e) { return 0; }
            }
            return 0;
        }
        @Override public void close() { try { if (sock != null) sock.close(); } catch (IOException ignored) {} }
        @Override public String describe() { String n = dev.getName(); return "Bluetooth " + (n != null ? n : dev.getAddress()); }
    }

    // ------------------------------------------------------------------ BLE
    public static final class Ble implements Elm327.Transport {
        private static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB");
        private final Context ctx; private final BluetoothDevice dev;
        private BluetoothGatt gatt;
        private BluetoothGattCharacteristic writeChar, notifyChar;
        private final LinkedBlockingQueue<byte[]> rx = new LinkedBlockingQueue<>();
        private final CountDownLatch ready = new CountDownLatch(1);
        private volatile CountDownLatch writeDone;
        private volatile String error;
        private byte[] pending = new byte[0];

        public Ble(Context c, BluetoothDevice d) { ctx = c; dev = d; }

        @Override public void open() throws IOException {
            gatt = dev.connectGatt(ctx, false, cb);
            try {
                if (!ready.await(15, TimeUnit.SECONDS)) throw new IOException("BLE zaman aşımı");
            } catch (InterruptedException e) { throw new IOException("kesildi"); }
            if (error != null) throw new IOException(error);
        }

        private final BluetoothGattCallback cb = new BluetoothGattCallback() {
            @Override public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
                if (newState == BluetoothProfile.STATE_CONNECTED) g.discoverServices();
                else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    error = "BLE bağlantısı kesildi";
                    rx.offer(new byte[0]);   // EOF marker
                    ready.countDown();
                }
            }
            @Override public void onServicesDiscovered(BluetoothGatt g, int status) {
                for (BluetoothGattService s : g.getServices()) {
                    for (BluetoothGattCharacteristic c : s.getCharacteristics()) {
                        int p = c.getProperties();
                        String u = c.getUuid().toString().toUpperCase();
                        boolean pref = u.startsWith("0000FFF") || u.contains("FFE1");
                        if ((p & (BluetoothGattCharacteristic.PROPERTY_WRITE | BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE)) != 0
                                && (writeChar == null || pref)) writeChar = c;
                        if ((p & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0 && (notifyChar == null || pref)) notifyChar = c;
                    }
                }
                if (writeChar == null || notifyChar == null) { error = "ELM BLE karakteristikleri bulunamadı"; ready.countDown(); return; }
                g.setCharacteristicNotification(notifyChar, true);
                BluetoothGattDescriptor d = notifyChar.getDescriptor(CCCD);
                if (d != null) { d.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE); g.writeDescriptor(d); }
                else ready.countDown();
            }
            @Override public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) { ready.countDown(); }
            @Override public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
                byte[] v = c.getValue();
                if (v != null && v.length > 0) rx.offer(v.clone());
            }
            @Override public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
                CountDownLatch l = writeDone; if (l != null) l.countDown();
            }
        };

        @Override public void write(byte[] data) throws IOException {
            if (gatt == null || writeChar == null) throw new IOException("BLE hazır değil");
            int off = 0;
            while (off < data.length) {
                int n = Math.min(20, data.length - off);
                byte[] chunk = new byte[n];
                System.arraycopy(data, off, chunk, 0, n);
                writeDone = new CountDownLatch(1);
                writeChar.setValue(chunk);
                writeChar.setWriteType((writeChar.getProperties() & BluetoothGattCharacteristic.PROPERTY_WRITE) != 0
                        ? BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT : BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE);
                if (!gatt.writeCharacteristic(writeChar)) throw new IOException("BLE yazma başarısız");
                try { writeDone.await(1500, TimeUnit.MILLISECONDS); } catch (InterruptedException ignored) {}
                off += n;
            }
        }

        @Override public int read(byte[] buf, int timeoutMs) throws IOException {
            if (pending.length == 0) {
                byte[] v;
                try { v = rx.poll(timeoutMs, TimeUnit.MILLISECONDS); } catch (InterruptedException e) { return 0; }
                if (v == null) return 0;
                if (v.length == 0) return -1;
                pending = v;
            }
            int n = Math.min(buf.length, pending.length);
            System.arraycopy(pending, 0, buf, 0, n);
            byte[] rest = new byte[pending.length - n];
            System.arraycopy(pending, n, rest, 0, rest.length);
            pending = rest;
            return n;
        }

        @Override public void close() {
            BluetoothGatt g = gatt; gatt = null;
            if (g != null) { try { g.disconnect(); g.close(); } catch (Exception ignored) {} }
            rx.offer(new byte[0]);
        }
        @Override public String describe() { String n = dev.getName(); return "BLE " + (n != null ? n : dev.getAddress()); }
    }
}
