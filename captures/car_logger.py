#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Jeep WJ 2.7 CRD - gercek arac ham veri kaydedici.
WiFi ELM327'ye (varsayilan 192.168.0.10:35000) baglanir, tum modullerin
DTC + canli verisini okur, HER TX/RX'i zaman damgasiyla dosyaya yazar.

Kullanim (laptop ELM'in WiFi AP'sine bagliyken):
    python car_logger.py                    # varsayilan 192.168.0.10:35000
    python car_logger.py --host 192.168.0.10 --port 35000
    python car_logger.py --secs 40          # ECU/TCM canli veriyi 40 sn topla

NOT: Canli veri icin motor calisir olsun. Cikti: car_log_YYYYMMDD_HHMMSS.txt
"""
import socket, time, sys, argparse, datetime

def now_ms():
    return int(time.time() * 1000)

class Elm:
    def __init__(self, host, port, log):
        self.log = log
        self.s = socket.create_connection((host, port), timeout=6)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.t0 = now_ms()

    def cmd(self, c, wait=0.0, timeout=4.0):
        """Komutu gonder, '>' prompt'una kadar oku, logla, yaniti dondur."""
        self.s.sendall((c + "\r").encode("latin-1"))
        self._w(">>> " + c)
        if wait:
            time.sleep(wait)
        self.s.settimeout(timeout)
        buf = b""
        try:
            while True:
                d = self.s.recv(1024)
                if not d:
                    break
                buf += d
                if b">" in buf:
                    break
        except socket.timeout:
            pass
        r = buf.decode("latin-1", "replace").replace("\r", " ").replace(">", "").strip()
        self._w("<<< " + (r if r else "(bos)"))
        return r

    def _w(self, line):
        ts = now_ms() - self.t0
        self.log.write("%8d  %s\n" % (ts, line))
        self.log.flush()
        print("%8d  %s" % (ts, line))

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def section(elm, title):
    elm._w("")
    elm._w("==================== " + title + " ====================")


def read_kline(elm, module, header_cmds, security, dtc_cmd, blocks, secs):
    """K-Line modul: init -> (security) -> DTC -> canli blok dongusu."""
    section(elm, module)
    for c in header_cmds:
        elm.cmd(c)
    elm.cmd("81", timeout=6)          # bus init / StartComm
    if security:
        elm.cmd("27 01")
        elm.cmd(security)             # ornek: "27 02 CC 21" (TCM) - ECU'da seed'e gore
    elm.cmd("1A 90")                  # ECU ID / VIN
    elm.cmd("1A 86")
    elm.cmd(dtc_cmd, timeout=8)       # DTC oku
    # canli veri: butun bloklari secs boyunca tekrar tekrar oku (yakit degisimini gormek icin)
    t_end = time.time() + secs
    rounds = 0
    while time.time() < t_end:
        rounds += 1
        for b in blocks:
            elm.cmd("21 %02X" % b)
        elm.cmd("81")                 # keepalive
    elm._w("(%s: %d tur canli veri)" % (module, rounds))


def read_j1850(elm, name, addr, pids):
    """J1850 modul: ATSH24<addr>22 + ATRA<addr> + 2E/2F PID taramasi."""
    section(elm, name + " (0x%02X)" % addr)
    elm.cmd("ATSH24%02X22" % addr)
    elm.cmd("ATRA%02X" % addr)
    # kimlik/durum on-bloklari (airbag/ABS icin)
    for pre in ["20 00 00", "20 01 00", "20 02 00", "24 00 00", "28 00 00", "20 07 00"]:
        elm.cmd(pre)
    for p in pids:
        r = elm.cmd(p + " 00")
        # J1850 modul mesgulse (7F .. 21 busyRepeat) bir kez tekrarla
        if "7F" in r and " 21" in r and "NO DATA" not in r:
            elm.cmd(p + " 00")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.0.10")
    ap.add_argument("--port", type=int, default=35000)
    ap.add_argument("--secs", type=int, default=30, help="ECU/TCM canli veri sureleri (sn)")
    args = ap.parse_args()

    fn = "car_log_%s.txt" % datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log = open(fn, "w", encoding="utf-8")
    print("Kaydediliyor -> %s   (Ctrl+C ile durdur)\n" % fn)

    try:
        elm = Elm(args.host, args.port, log)
    except Exception as e:
        print("BAGLANTI HATASI: %s" % e)
        print("ELM'in WiFi'ina bagli misin? IP/port dogru mu?")
        return

    try:
        # --- ELM reset ---
        section(elm, "ELM INIT")
        elm.cmd("ATZ", wait=1.0)
        elm.cmd("ATZ", wait=1.0)
        elm.cmd("ATE1"); elm.cmd("ATH1"); elm.cmd("ATL0"); elm.cmd("ATS1")

        # --- ECU (0x15, K-Line EDC15C2): yakit icin en onemli ---
        read_kline(
            elm, "ENGINE ECU 0x15",
            ["ATSP5", "ATWM8115F13E", "ATSH8115F1", "ATFI"],
            security=None,  # ECU seed'i 00 00 gelirse anahtar yok; degilse manuel bak
            dtc_cmd="18 02 00 00",
            blocks=[0x12, 0x20, 0x21, 0x22, 0x23, 0x26, 0x28, 0x32, 0x34, 0x36, 0x37, 0x16, 0x13, 0x30],
            secs=args.secs,
        )

        # --- TCM (0x20, K-Line NAG1) ---
        read_kline(
            elm, "TRANSMISSION TCM 0x20",
            ["ATSP2" if False else "ATSP5", "ATWM8120F13E", "ATSH8120F1", "ATFI"],
            security="27 02 CC 21",   # TCM sabit seed 68 24 89 -> anahtar CC 21
            dtc_cmd="18 02 FF 00",
            blocks=[0x30, 0x31, 0x32, 0x33, 0x34],
            secs=max(10, args.secs // 2),
        )

        # --- J1850 moduller: ATSP2 ---
        section(elm, "J1850 INIT")
        elm.cmd("ATZ", wait=1.0)
        elm.cmd("ATSP2"); elm.cmd("ATIFR0"); elm.cmd("ATH1")

        airbag_pids = (["2E %02X" % x for x in
                        [0x10,0x13,0x16,0x19,0x1C,0x1F,0x22,0x25,0x28,0x2B,0x2E,0x37,0x3A,0x3D,0x43,0x49,
                         0x4C,0x4F,0x52,0x70,0x73,0x76,0x79,0x7C,0x7F,0x82,0x85,0x88,0x8B,0x8E,0x91,0x94,
                         0x97,0xDC,0xDF,0xE2,0xE5,0xFA,0xFD]] +
                       ["2F %02X" % x for x in
                        [0x00,0x03,0x06,0x18,0x1B,0x1E,0x21,0x24,0x27,0x2A,0x2D,0x30,0x33,0x36,0x39,0x3C]])
        abs_pids = ["2E %02X" % x for x in [0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x30]]
        bcm_pids = ["2E %02X" % x for x in [0x00,0x01,0x02,0x03,0x05,0x12]]

        read_j1850(elm, "AIRBAG", 0x58, airbag_pids)
        read_j1850(elm, "ABS", 0x28, abs_pids)
        read_j1850(elm, "BODY/BCM", 0x40, bcm_pids)

        section(elm, "BITTI")
    except KeyboardInterrupt:
        elm._w("(kullanici durdurdu)")
    finally:
        elm.close()
        log.close()
        print("\nKaydedildi: %s  --> bu dosyayi bana gonder." % fn)


if __name__ == "__main__":
    main()
