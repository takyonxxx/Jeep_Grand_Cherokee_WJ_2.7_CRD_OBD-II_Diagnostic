package com.elmsniff;

import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;

/**
 * Minimal USB-serial driver for the ESP32 sniffer board: FTDI FT232 (the board's
 * USB bridge, 0403:6001) and CDC-ACM (Espressif native USB, CP210x is treated as
 * CDC-like only for bulk I/O). 115200 8N1, no flow control.
 */
final class UsbSerial {
    static final int VID_FTDI = 0x0403, VID_ESPRESSIF = 0x303A;

    private final UsbDeviceConnection mConn;
    private final UsbEndpoint mIn, mOut;
    private final boolean mFtdi;
    private final int mPacket;

    static boolean looksLikeSerial(UsbDevice d) {
        if (d.getVendorId() == VID_FTDI) return true;
        for (int i = 0; i < d.getInterfaceCount(); i++) {
            int c = d.getInterface(i).getInterfaceClass();
            if (c == UsbConstants.USB_CLASS_CDC_DATA || c == UsbConstants.USB_CLASS_COMM) return true;
        }
        return d.getVendorId() == 0x10C4 || d.getVendorId() == 0x1A86;   // CP210x / CH340 (bulk only)
    }

    UsbSerial(UsbManager mgr, UsbDevice dev) throws Exception {
        mConn = mgr.openDevice(dev);
        if (mConn == null) throw new Exception("USB cihazı açılamadı (izin?)");
        mFtdi = dev.getVendorId() == VID_FTDI;
        UsbInterface data = null, ctrl = null;
        UsbEndpoint in = null, out = null;
        for (int i = 0; i < dev.getInterfaceCount(); i++) {
            UsbInterface f = dev.getInterface(i);
            if (f.getInterfaceClass() == UsbConstants.USB_CLASS_COMM) ctrl = f;
            for (int e = 0; e < f.getEndpointCount(); e++) {
                UsbEndpoint ep = f.getEndpoint(e);
                if (ep.getType() != UsbConstants.USB_ENDPOINT_XFER_BULK) continue;
                if (ep.getDirection() == UsbConstants.USB_DIR_IN && in == null) { in = ep; data = f; }
                if (ep.getDirection() == UsbConstants.USB_DIR_OUT && out == null) out = ep;
            }
        }
        if (data == null || in == null) throw new Exception("bulk endpoint yok");
        if (ctrl != null && ctrl != data) mConn.claimInterface(ctrl, true);
        mConn.claimInterface(data, true);
        mIn = in; mOut = out; mPacket = Math.max(64, in.getMaxPacketSize());

        if (mFtdi) {
            // FTDI vendor requests: reset, baud 115200 (divisor 26 -> 0x001A), 8N1, no flow, latency 2 ms
            mConn.controlTransfer(0x40, 0x00, 0x0000, 1, null, 0, 500);
            mConn.controlTransfer(0x40, 0x03, 0x001A, 0x0000, null, 0, 500);
            mConn.controlTransfer(0x40, 0x04, 0x0008, 1, null, 0, 500);
            mConn.controlTransfer(0x40, 0x02, 0x0000, 1, null, 0, 500);
            mConn.controlTransfer(0x40, 0x09, 0x0002, 1, null, 0, 500);
        } else if (ctrl != null) {
            // CDC-ACM: SET_LINE_CODING 115200 8N1, then DTR+RTS
            byte[] lc = { (byte) 0x00, (byte) 0xC2, (byte) 0x01, 0, 0, 0, 8 };
            mConn.controlTransfer(0x21, 0x20, 0, ctrl.getId(), lc, lc.length, 500);
            mConn.controlTransfer(0x21, 0x22, 0x0003, ctrl.getId(), null, 0, 500);
        }
    }

    /** Reads one bulk packet into dst; returns payload length (FTDI status bytes stripped) or 0 on timeout. */
    int read(byte[] dst, int timeoutMs) {
        byte[] buf = new byte[mPacket];
        int n = mConn.bulkTransfer(mIn, buf, buf.length, timeoutMs);
        if (n <= 0) return 0;
        int off = 0;
        if (mFtdi) { if (n <= 2) return 0; off = 2; }
        int len = Math.min(n - off, dst.length);
        System.arraycopy(buf, off, dst, 0, len);
        return len;
    }

    void write(byte[] data) {
        if (mOut != null) mConn.bulkTransfer(mOut, data, data.length, 500);
    }

    void close() {
        try { mConn.close(); } catch (Exception e) {}
    }
}
