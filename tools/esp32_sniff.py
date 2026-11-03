"""Reads the ESP32 WiFi sniffer (esp32-sniffer firmware) over serial and writes
captures/pcap/sniff_<date>.pcap (raw IPv4, same format as the ElmCap captures) and
sniff_<date>.txt (timestamped TX/RX text, TX = towards the ELM).

    python tools/esp32_sniff.py [--com COM4] [--baud 115200] [--port 35000]

Everything else the board prints (scan results, "S" counters) is echoed to the console.
"""
import argparse, os, struct, sys, time

try:
    import serial
except ImportError:
    sys.exit("pyserial gerekli:  pip install pyserial")


def ip_bytes(s):
    return bytes(int(x) for x in s.split('.'))


class Pcap:
    def __init__(self, path):
        self.f = open(path, 'wb')
        self.f.write(struct.pack('<IHHiIII', 0xA1B2C3D4, 2, 4, 0, 0, 65535, 101))   # LINKTYPE_RAW
        self.seq = {}

    def write(self, src, sport, dst, dport, payload):
        key = (src, sport, dst, dport)
        seq = self.seq.get(key, 1)
        tcp = struct.pack('>HHIIBBHHH', sport, dport, seq, 0, 5 << 4, 0x18, 65535, 0, 0) + payload
        self.seq[key] = seq + len(payload)
        ip = struct.pack('>BBHHHBBH', 0x45, 0, 20 + len(tcp), 0, 0x4000, 64, 6, 0) + ip_bytes(src) + ip_bytes(dst)
        frame = ip + tcp
        ts = time.time()
        self.f.write(struct.pack('<IIII', int(ts), int((ts % 1) * 1e6), len(frame), len(frame)) + frame)
        self.f.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--com', default='COM4')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--port', type=int, default=35000)
    a = ap.parse_args()

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'captures', 'pcap')
    os.makedirs(out_dir, exist_ok=True)
    stamp = time.strftime('%Y%m%d_%H%M%S')
    pcap = Pcap(os.path.join(out_dir, f'sniff_{stamp}.pcap'))
    txt = open(os.path.join(out_dir, f'sniff_{stamp}.txt'), 'w', encoding='utf-8')
    print(f'sniff: {a.com} @ {a.baud}  ->  captures/pcap/sniff_{stamp}.*   (Ctrl+C to stop)')

    ser = serial.Serial(a.com, a.baud, timeout=1)
    n = 0
    while True:
        line = ser.readline().decode('latin-1', 'replace').strip()
        if not line:
            continue
        if line.startswith('P '):
            try:
                _, ms, src, dst, hexs = line.split(' ', 4)
                sip, sport = src.rsplit(':', 1); dip, dport = dst.rsplit(':', 1)
                payload = bytes.fromhex(hexs)
            except ValueError:
                print('?', line[:80]); continue
            pcap.write(sip, int(sport), dip, int(dport), payload)
            tag = 'TX' if int(dport) == a.port else 'RX'
            text = payload.decode('latin-1').replace('\r', '\\r').replace('\n', '\\n')
            msg = f'{time.strftime("%H:%M:%S")} {tag} {text}'
            txt.write(msg + '\n'); txt.flush()
            n += 1
            print(msg)
        else:
            print('[esp32]', line)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
