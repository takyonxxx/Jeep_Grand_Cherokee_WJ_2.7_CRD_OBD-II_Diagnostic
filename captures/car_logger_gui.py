#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WJ 2.7 CRD - WJdiag-Pro komut akisi kaydedici (GUI).

WJdiag-Pro'nun gercek pcap kayitlarindan cikarilan TAM komut dizisini
(wjpro_cmdseq.json, menu sirasina gore: ECU -> TCM -> ABS -> Airbag -> ...)
ELM327'ye gonderir ve her TX/RX'i zaman damgasiyla dosyaya + ekrana yazar.

GUVENLIK: Aktuator testleri (role/solenoid tetikler) ve DTC silme komutlari
VARSAYILAN KAPALI. Ihtiyacin varsa onay kutusundan ac.

Dosyalar ayni klasorde olmali: car_logger_gui.py + wjpro_cmdseq.json
Baslatmak icin: baslat.bat  (veya: python car_logger_gui.py)
"""
import os, sys, json, socket, time, threading, datetime
try:
    import tkinter as tk
    from tkinter import ttk, scrolledtext, messagebox
except Exception:
    print("tkinter yok. Python'u 'tcl/tk' ile kur.")
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))

# ECU guvenlik anahtar tablolari (arvutaKoodi - Kwp2000.java ile ayni)
T1 = [0xC0,0xD0,0xE0,0xF0,0x00,0x10,0x20,0x30,0x40,0x50,0x60,0x70,0x80,0x90,0xA0,0xB0]
T2 = [0x02,0x03,0x00,0x01,0x06,0x07,0x04,0x05,0x0A,0x0B,0x08,0x09,0x0E,0x0F,0x0C,0x0D]
T3 = [0x90,0x80,0xF0,0xE0,0xD0,0xC0,0x30,0x20,0x10,0x00,0x70,0x60,0x50,0x40,0xB0,0xA0]
T4 = [0x0D,0x0C,0x0F,0x0E,0x09,0x08,0x0B,0x0A,0x05,0x04,0x07,0x06,0x01,0x00,0x03,0x02]

def ecu_key(seed_hi, seed_lo):
    v1 = (seed_lo + 0x0B) & 0xFF
    key_lo = T1[(v1 >> 4) & 0xF] | T2[v1 & 0xF]
    cond = 1 if seed_lo > 0x34 else 0
    v2 = (seed_hi + cond + 1) & 0xFF
    key_hi = T3[(v2 >> 4) & 0xF] | T4[v2 & 0xF]
    return key_hi, key_lo


def load_cmds():
    p = os.path.join(HERE, "wjpro_cmdseq.json")
    if not os.path.exists(p):
        return None
    return json.load(open(p, "r", encoding="utf-8"))


class Logger:
    def __init__(self, host, port, do_act, do_clear, ui):
        self.host, self.port = host, port
        self.do_act, self.do_clear = do_act, do_clear
        self.ui = ui
        self.stop = False
        self.sock = None
        self.t0 = 0
        self.fh = None
        self.cur_kline = None      # 0x15 ECU / 0x20 TCM (ATSH81xx)
        self.cur_j1850 = None      # (addr, mode) ATSH24xxYY
        self.last_seed = None

    def log(self, line):
        ts = int((time.time()*1000) - self.t0)
        s = "%8d  %s" % (ts, line)
        if self.fh:
            self.fh.write(s + "\n"); self.fh.flush()
        self.ui.append(s)

    def xchg(self, cmd, timeout=5.0):
        self.sock.sendall((cmd + "\r").encode("latin-1"))
        self.log(">>> " + cmd)
        self.sock.settimeout(timeout)
        buf = b""
        try:
            while True:
                d = self.sock.recv(1024)
                if not d: break
                buf += d
                if b">" in buf: break
        except socket.timeout:
            pass
        r = buf.decode("latin-1", "replace").replace("\r", " ").replace(">", "").strip()
        self.log("<<< " + (r if r else "(bos)"))
        return r

    def classify(self, cmd):
        u = cmd.upper()
        if u.startswith("AT"):
            return "at"
        if u.startswith("14 "):
            return "clear"
        if u.startswith("30 ") or u.startswith("38 "):
            return "actuator"
        if u.startswith("31 ") and not u.startswith("31 25"):
            return "actuator"  # TCM adaptive store/reset vb.
        # J1850 veri komutlari: aktif header moduna gore
        if self.cur_j1850:
            mode = self.cur_j1850[1]
            if mode == 0x14:
                return "clear"
            if mode in (0x2F, 0x30, 0xB4, 0x11, 0xA0, 0xA3):
                return "actuator"
        return "read"

    def track_header(self, cmd):
        u = cmd.upper().replace(" ", "")
        if u.startswith("ATSH81") and len(u) >= 10:
            try: self.cur_kline = int(u[6:8], 16)
            except: pass
            self.cur_j1850 = None
        elif u.startswith("ATSH24") and len(u) >= 10:
            try: self.cur_j1850 = (int(u[6:8], 16), int(u[8:10], 16))
            except: pass
        elif u.startswith("ATSP"):
            # protokol degisimi; K-line baglami sifirla
            if "5" in u: self.cur_j1850 = None
            if "2" in u: self.cur_kline = None

    def security(self, cmd):
        """27 01 / 27 02 dinamik isle. 27 02'yi seed'den yeniden hesapla."""
        u = cmd.upper()
        if u.startswith("27 01"):
            r = self.xchg(cmd)
            # seed: 67 01 hi lo  (K-line cercevesinde de olabilir)
            toks = [t for t in r.split() if len(t) == 2]
            for i in range(len(toks) - 3):
                if toks[i] == "67" and toks[i+1] == "01":
                    try:
                        self.last_seed = (int(toks[i+2], 16), int(toks[i+3], 16))
                    except: pass
                    break
            return True
        if u.startswith("27 02"):
            if self.cur_kline == 0x20:
                self.xchg("27 02 CC 21")        # TCM sabit anahtar
            elif self.last_seed:
                hi, lo = self.last_seed
                if hi == 0 and lo == 0:
                    self.log("[GUVENLIK] seed 00 00 -> zaten acik, anahtar gonderilmedi")
                else:
                    kh, kl = ecu_key(hi, lo)
                    self.xchg("27 02 %02X %02X" % (kh, kl))
            else:
                self.xchg(cmd)                  # seed yoksa oldugu gibi
            return True
        return False

    def run(self, cmds):
        fn = os.path.join(HERE, "car_log_%s.txt" % datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))
        self.fh = open(fn, "w", encoding="utf-8")
        try:
            self.ui.set_status("Baglaniyor %s:%d ..." % (self.host, self.port))
            self.sock = socket.create_connection((self.host, self.port), timeout=6)
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except Exception as e:
            self.ui.set_status("BAGLANTI HATASI")
            self.ui.done(False, "Baglanamadi: %s\nELM'in WiFi'ina bagli misin? IP/port dogru mu?" % e)
            if self.fh: self.fh.close()
            return

        self.t0 = int(time.time()*1000)
        total = len(cmds)
        skipped_act = skipped_clr = 0
        for i, cmd in enumerate(cmds):
            if self.stop:
                self.log("(kullanici durdurdu)")
                break
            cmd = cmd.strip()
            if not cmd:
                continue
            self.track_header(cmd)
            # guvenlik komutlari ozel
            if cmd.upper().startswith("27 0"):
                self.security(cmd)
                self.ui.set_progress(i + 1, total)
                continue
            kind = self.classify(cmd)
            if kind == "actuator" and not self.do_act:
                skipped_act += 1
                self.ui.set_progress(i + 1, total); continue
            if kind == "clear" and not self.do_clear:
                skipped_clr += 1
                self.ui.set_progress(i + 1, total); continue
            to = 8.0 if (cmd.upper().startswith("18 02") or cmd.upper() == "81") else 5.0
            self.xchg(cmd, timeout=to)
            self.ui.set_progress(i + 1, total)

        try: self.sock.close()
        except: pass
        note = "Atlanan: %d aktuator, %d silme komutu (kapali oldugu icin)." % (skipped_act, skipped_clr)
        self.log(""); self.log("===== BITTI =====  " + note)
        if self.fh: self.fh.close()
        self.ui.set_status("BITTI")
        self.ui.done(True, "Kayit tamamlandi.\n\nDosya:\n%s\n\n%s\n\nBu dosyayi bana gonder." % (fn, note))


class App:
    def __init__(self, root):
        self.root = root
        root.title("WJ Diag - Arac Veri Kaydedici (WJdiag-Pro akisi)")
        root.geometry("820x600")
        self.logger = None
        self.thread = None

        top = ttk.Frame(root, padding=8); top.pack(fill="x")
        ttk.Label(top, text="ELM IP:").pack(side="left")
        self.host = tk.StringVar(value="192.168.0.10")
        ttk.Entry(top, textvariable=self.host, width=15).pack(side="left", padx=(2, 10))
        ttk.Label(top, text="Port:").pack(side="left")
        self.port = tk.StringVar(value="35000")
        ttk.Entry(top, textvariable=self.port, width=7).pack(side="left", padx=2)

        self.act = tk.BooleanVar(value=False)
        self.clr = tk.BooleanVar(value=False)
        opt = ttk.Frame(root, padding=(8, 0)); opt.pack(fill="x")
        ttk.Checkbutton(opt, text="Aktuator testlerini de gonder  (DIKKAT: role/solenoid tetikler)",
                        variable=self.act).pack(anchor="w")
        ttk.Checkbutton(opt, text="DTC SILME komutlarini da gonder  (DIKKAT: arac arizalarini siler)",
                        variable=self.clr).pack(anchor="w")

        btns = ttk.Frame(root, padding=8); btns.pack(fill="x")
        self.start_btn = ttk.Button(btns, text="BASLAT", command=self.start)
        self.start_btn.pack(side="left")
        self.stop_btn = ttk.Button(btns, text="DURDUR", command=self.stop, state="disabled")
        self.stop_btn.pack(side="left", padx=6)
        self.status = tk.StringVar(value="Hazir. ELM'in WiFi'ina bagli oldugundan emin ol, BASLAT'a bas.")
        ttk.Label(btns, textvariable=self.status).pack(side="left", padx=10)

        self.prog = ttk.Progressbar(root, mode="determinate")
        self.prog.pack(fill="x", padx=8, pady=(0, 6))

        self.text = scrolledtext.ScrolledText(root, font=("Consolas", 9), wrap="none")
        self.text.pack(fill="both", expand=True, padx=8, pady=(0, 8))

        self.cmds = load_cmds()
        if self.cmds is None:
            self.status.set("HATA: wjpro_cmdseq.json bulunamadi (ayni klasorde olmali).")
            self.start_btn.config(state="disabled")
        else:
            self.append("WJdiag-Pro komut akisi yuklendi: %d komut (menu sirasina gore)." % len(self.cmds))
            self.append("Motoru calistir, ELM WiFi'ina bagli laptop'ta BASLAT'a bas.\n")

    def append(self, s):
        self.text.insert("end", s + "\n"); self.text.see("end")

    def set_status(self, s):
        self.root.after(0, lambda: self.status.set(s))

    def set_progress(self, i, total):
        def upd():
            self.prog["maximum"] = total; self.prog["value"] = i
        self.root.after(0, upd)

    def done(self, ok, msg):
        def fin():
            self.start_btn.config(state="normal"); self.stop_btn.config(state="disabled")
            try:
                import winsound; winsound.MessageBeep()
            except Exception:
                pass
            (messagebox.showinfo if ok else messagebox.showerror)("Bitti" if ok else "Hata", msg)
        self.root.after(0, fin)

    def start(self):
        try:
            port = int(self.port.get())
        except Exception:
            messagebox.showerror("Hata", "Port sayi olmali."); return
        self.text.delete("1.0", "end")
        self.start_btn.config(state="disabled"); self.stop_btn.config(state="normal")
        self.logger = Logger(self.host.get().strip(), port, self.act.get(), self.clr.get(), self)
        self.thread = threading.Thread(target=self.logger.run, args=(self.cmds,), daemon=True)
        self.thread.start()

    def stop(self):
        if self.logger:
            self.logger.stop = True
            self.set_status("Durduruluyor...")


if __name__ == "__main__":
    root = tk.Tk()
    App(root)
    root.mainloop()
