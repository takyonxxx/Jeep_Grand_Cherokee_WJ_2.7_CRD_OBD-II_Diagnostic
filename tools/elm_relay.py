"""ELM327 WiFi relay + pcap recorder (man-in-the-middle on the PC).

Use when the head unit cannot capture itself (ElmCap / VpnService blocked):

    head unit (WJdiag-Pro)  --WiFi-->  PC hotspot :35000  --WiFi-->  ELM327 AP 192.168.0.10:35000

The PC joins the ELM's "WiFi_OBDII" network with its Wi-Fi adapter and at the same time
shares it as a Mobile Hotspot (Windows: Settings > Network > Mobile hotspot, share "Wi-Fi").
The head unit joins the hotspot, and WJdiag-Pro's WiFi address is set to the PC's hotspot
IP (usually 192.168.137.1) port 35000. Everything that passes is written to

    captures/pcap/relay_YYYYMMDD_HHMMSS.pcap   (plain TCP, readable by Wireshark and by the
                                                existing pcap_*.py tools: ELM = port 35000)
    captures/pcap/relay_YYYYMMDD_HHMMSS.txt    (timestamped TX/RX text)

    python tools/elm_relay.py [--elm 192.168.0.10] [--port 35000] [--listen 0.0.0.0] [--listen-port 35000]
"""
import argparse, os, socket, struct, sys, threading, time

CLIENT_IP = (10, 0, 0, 2)      # synthetic addresses in the pcap (head unit side)
ELM_IP = (10, 0, 0, 1)         # ELM side


class Pcap:
    def __init__(self, path):
        self.f = open(path, 'wb')
        self.f.write(struct.pack('<IHHiIII', 0xA1B2C3D4, 2, 4, 0, 0, 65535, 101))   # LINKTYPE_RAW (IPv4), same as the ElmCap captures
        self.seq = {True: 1, False: 1}
        self.lock = threading.Lock()

    def write(self, payload: bytes, to_elm: bool, port: int):
        src, dst = (CLIENT_IP, ELM_IP) if to_elm else (ELM_IP, CLIENT_IP)
        sport, dport = (40000, port) if to_elm else (port, 40000)
        tcp = struct.pack('>HHIIBBHHH', sport, dport, self.seq[to_elm], 0, 5 << 4, 0x18, 65535, 0, 0) + payload
        self.seq[to_elm] += len(payload)
        ip = struct.pack('>BBHHHBBH4B4B', 0x45, 0, 20 + len(tcp), 0, 0x4000, 64, 6, 0, *src, *dst)
        frame = ip + tcp
        ts = time.time()
        with self.lock:
            self.f.write(struct.pack('<IIII', int(ts), int((ts % 1) * 1e6), len(frame), len(frame)) + frame)
            self.f.flush()


def pump(src, dst, to_elm, pcap, txt, port, stop):
    tag = 'TX' if to_elm else 'RX'
    try:
        while not stop.is_set():
            data = src.recv(4096)
            if not data:
                break
            dst.sendall(data)
            pcap.write(data, to_elm, port)
            line = data.decode('latin-1').replace('\r', '\\r').replace('\n', '\\n')
            msg = f'{time.strftime("%H:%M:%S")}.{int((time.time() % 1) * 1000):03d} {tag} {line}'
            txt.write(msg + '\n'); txt.flush()
            print(msg)
    except OSError:
        pass
    finally:
        stop.set()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--elm', default='192.168.0.10')
    ap.add_argument('--port', type=int, default=35000)
    ap.add_argument('--listen', default='0.0.0.0')
    ap.add_argument('--listen-port', type=int, default=0, help='local port (default: same as --port)')
    a = ap.parse_args()

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'captures', 'pcap')
    os.makedirs(out_dir, exist_ok=True)
    stamp = time.strftime('%Y%m%d_%H%M%S')
    pcap = Pcap(os.path.join(out_dir, f'relay_{stamp}.pcap'))
    txt = open(os.path.join(out_dir, f'relay_{stamp}.txt'), 'w', encoding='utf-8')
    lport = a.listen_port or a.port
    print(f'relay: listening on {a.listen}:{lport}  ->  ELM {a.elm}:{a.port}')
    print(f'       pcap/text: captures/pcap/relay_{stamp}.*   (Ctrl+C to stop)')

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.listen, lport)); srv.listen(1)
    while True:
        cli, addr = srv.accept()
        cli.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f'*** client {addr[0]} connected, dialing ELM...')
        try:
            elm = socket.create_connection((a.elm, a.port), timeout=5)
            elm.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            elm.settimeout(None)
        except OSError as e:
            print(f'*** ELM unreachable: {e}'); cli.close(); continue
        txt.write(f'--- session {time.strftime("%H:%M:%S")} client {addr[0]}\n')
        stop = threading.Event()
        t1 = threading.Thread(target=pump, args=(cli, elm, True, pcap, txt, a.port, stop), daemon=True)
        t2 = threading.Thread(target=pump, args=(elm, cli, False, pcap, txt, a.port, stop), daemon=True)
        t1.start(); t2.start(); stop.wait()
        for s in (cli, elm):
            try: s.close()
            except OSError: pass
        print('*** session closed')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
