#!/usr/bin/env python3
"""
WJ Diag - ELM327 + NAG1 722.6 Emulator (Real Vehicle Verified)
================================================================
Jeep Grand Cherokee 2.7 CRD diagnostic emulator.
Protocol verified against real vehicle (2025-03-07).

K-Line Modules:
  - Engine ECU (0x15) Bosch EDC15C2 OM612
  - TCM (0x20) NAG1 722.6 EGS52 - Block 0x30 = live data

J1850 VPW Modules:
  - ABS (0x40) - PIDs 0x00-0x06
  - Airbag (0x60) - NRC on most PIDs

Usage:
    python wj_tcm_emulator.py [--host 0.0.0.0] [--port 35000]
"""

import argparse, asyncio, logging, math, random, time
from dataclasses import dataclass, field
from typing import Optional

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("WJ-EMU")


@dataclass
class VehicleState:
    turbine_rpm: float = 0.0
    output_rpm: float = 0.0
    vehicle_speed: float = 0.0
    trans_temp: int = 90
    gear_selector: int = 4
    tcc_slip_actual: int = 0
    tcc_slip_desired: int = 0
    solenoid_state: int = 0x96
    counter_byte7: int = 8
    engine_rpm: float = 750.0
    coolant_temp: float = 50.0
    iat: float = 20.0
    tps: float = 0.0
    map_actual: int = 920
    rail_actual: float = 290.0
    aap: int = 928
    maf_actual: float = 420.0
    maf_spec: float = 360.0
    injection_qty: float = 9.5
    battery_voltage: float = 14.4
    tcm_dtc_list: list = field(default_factory=list)
    ecu_dtc_list: list = field(default_factory=lambda: [(0x03,0x80,0x01)])
    active_target: int = 0x20
    _t0: float = 0.0

    def __post_init__(self):
        self._t0 = time.time()

    def tick(self):
        t = time.time() - self._t0
        self.engine_rpm = 750 + 30*math.sin(t*0.5) + random.uniform(-10,10)
        if self.gear_selector >= 3:
            self.turbine_rpm = self.engine_rpm * 0.05
            self.output_rpm = 0; self.vehicle_speed = 0
        elif self.gear_selector == 1:
            self.turbine_rpm = self.engine_rpm * 0.95
            self.output_rpm = self.turbine_rpm * 0.7
            self.vehicle_speed = self.output_rpm * 0.03
        else:
            self.turbine_rpm = self.engine_rpm * 0.1
            self.output_rpm = 0; self.vehicle_speed = 0
        self.trans_temp = min(130, 90 + int(t*0.02))
        self.coolant_temp = min(95, 50 + t*0.05)
        self.iat = 20 + 2*math.sin(t*0.01)
        self.tcc_slip_actual = int(self.turbine_rpm - self.output_rpm) if self.gear_selector==1 else random.randint(-30,-5)
        self.tcc_slip_desired = self.tcc_slip_actual + random.randint(-5,5)
        self.solenoid_state = 0x96 if self.gear_selector >= 3 else 0x00
        self.counter_byte7 = max(3, 8 - int(t*0.1) % 6)
        self.battery_voltage = 14.4 + random.uniform(-0.3, 0.3)
        self.maf_actual = 420 + 20*math.sin(t*0.3)
        self.rail_actual = 290 + 10*math.sin(t*0.2)
        self.injection_qty = 9.5 + 2*math.sin(t*0.4)


class KWP2000Responder:
    def __init__(self, s: VehicleState):
        self.s = s

    def process(self, sid, data):
        h = {0x14:self._clear_dtc, 0x17:self._read_dtc, 0x18:self._read_dtc,
             0x1A:self._read_ecu_id, 0x21:self._read_local, 0x27:self._security,
             0x30:self._io_ctrl, 0x31:self._routine, 0x3B:self._write_local,
             0x3E:self._tester, 0x81:self._startcomm}.get(sid)
        if h:
            p = h(data)
            if p is not None: return self._wrap(p)
        return self._wrap(bytes([0x7F, sid, 0x11]))

    def _wrap(self, p):
        t = self.s.active_target
        f = 0x80 | (len(p) & 0x3F)
        frame = bytes([f, 0xF1, t]) + p
        return frame + bytes([sum(frame) & 0xFF])

    def _startcomm(self, d): return bytes([0xC1, 0xEF, 0x8F])
    def _tester(self, d): return bytes([0x7E, d[0] if d else 0x01])

    def _security(self, d):
        if not d: return bytes([0x7F,0x27,0x12])
        if d[0]==0x01:
            if self.s.active_target==0x20: return bytes([0x67,0x01,0x68,0x24,0x89])
            seed=random.randint(0,0xFFFFFF)
            return bytes([0x67,0x01,(seed>>16)&0xFF,(seed>>8)&0xFF,seed&0xFF])
        if d[0]==0x02: return bytes([0x7F,0x27,0x35])
        return bytes([0x7F,0x27,0x12])

    def _read_dtc(self, d):
        self.s.tick()
        dtcs = self.s.ecu_dtc_list if self.s.active_target==0x15 else self.s.tcm_dtc_list
        r = bytes([0x58, len(dtcs)])
        for h,l,s in dtcs: r += bytes([h,l,s])
        return r

    def _clear_dtc(self, d):
        if self.s.active_target==0x15: self.s.ecu_dtc_list.clear()
        else: self.s.tcm_dtc_list.clear()
        return bytes([0x54,0x00,0x00])

    def _read_ecu_id(self, d):
        o = d[0] if d else 0x86
        if self.s.active_target==0x20:
            if o==0x86: return bytes([0x5A,0x86,0x56,0x04,0x19,0x06,0xBC,0x03,0x01,0x02,0x03,0x08,0x02,0x00,0x00,0x03,0x03,0x11])
            if o==0x90: return bytes([0x5A,0x90]) + b'00000000000000000'
            return bytes([0x7F,0x1A,0x12])
        if o==0x86: return bytes([0x5A,0x86]) + b'BOSCH EDC15C2'
        if o==0x90: return bytes([0x5A,0x90]) + b'1J4GW58SX4C######'
        if o==0x91: return bytes([0x5A,0x91]) + b'HW03.02 SW04.12'
        return bytes([0x7F,0x1A,0x12])

    def _read_local(self, d):
        if not d: return bytes([0x7F,0x21,0x12])
        b = d[0]; self.s.tick()
        if self.s.active_target==0x15: return self._ecu_block(b)
        return self._tcm_block(b)

    def _tcm_block(self, b):
        t = self.s
        if b == 0x30:
            rpm = int(t.turbine_rpm) & 0xFFFF
            spd = int(t.vehicle_speed) & 0xFFFF
            sa = t.tcc_slip_actual & 0xFFFF
            sd = t.tcc_slip_desired & 0xFFFF
            return bytes([0x61,0x30,
                (rpm>>8)&0xFF, rpm&0xFF, 0x00, 0x1E,
                (spd>>8)&0xFF, spd&0xFF, 0x00, t.counter_byte7&0xFF,
                t.gear_selector&0xFF, 0x00, 0xBB, t.trans_temp&0xFF,
                (sa>>8)&0xFF, sa&0xFF, (sd>>8)&0xFF, sd&0xFF,
                0x00, 0x00, t.solenoid_state&0xFF, 0x18, 0x00, 0x08])
        if b == 0x50: return bytes([0x61,0x50]) + bytes(51)
        if b == 0x60: return bytes([0x61,0x60,0x00,0x01])
        if b == 0x70:
            d = bytes([0x61,0x70,0x00,0x27,0x00,0xF4])
            for i in range(40): d += bytes([0x19+(i%6),0x00,0x2E+i,0xFE,0x0C,0xB3+(i%10)])
            return d
        if b == 0x80: return bytes([0x61,0x80,0x03,0x00,0x00,0x03,0x38,0x02,0x02,0x00,0x0A,0x00,0x00,0x02,0x18,0x08,0x08,0x00,0x0A,0x00,0x00,0x04,0x18,0x08,0x08,0x00,0x0A])
        if b == 0xB0: return bytes([0x61,0xB0,0x6A,0x65,0x30,0x61])
        if b == 0xE0: return bytes([0x61,0xE0]) + b'aafwspsp'
        if b == 0xE1: return bytes([0x61,0xE1,0x01,0x61,0x90,0x46])
        return bytes([0x7F,0x21,0x12])

    def _ecu_block(self, b):
        t = self.s
        if b == 0x12:
            cr = int((t.coolant_temp+273.1)*10); ir = int((t.iat+273.1)*10)
            r = bytes([0x61,0x12])
            r += cr.to_bytes(2,'big') + ir.to_bytes(2,'big')
            r += bytes([0x08,0xB7,0x08,0xB7,0x00,0x00])
            r += int(t.map_actual).to_bytes(2,'big') + bytes([0x00,0x00])
            r += int(t.tps*100).to_bytes(2,'big')
            r += int(t.rail_actual*10).to_bytes(2,'big')
            r += bytes([0x03,0x9F,0x0B,0x84,0x01,0xA9,0x01,0x2A,0x00,0x4C])
            r += int(t.aap).to_bytes(2,'big') + bytes([0x00,0x00])
            return r
        if b == 0x28:
            r = bytes([0x61,0x28])
            r += int(t.engine_rpm).to_bytes(2,'big') + int(t.injection_qty*100).to_bytes(2,'big')
            r += bytes(26); return r
        if b == 0x20:
            r = bytes([0x61,0x20])
            r += int(t.maf_actual).to_bytes(2,'big') + int(t.maf_spec).to_bytes(2,'big')
            r += bytes([0x03,0xFE,0x00,0x00,0x00,0x94,0x00,0x48,0x01,0xBE,0x01,0x67,0x01,0x05,0x02,0xED,0x02,0x59,0x00,0x8D,0x00,0x7C,0x03,0xA0,0x02,0xA4])
            return r
        if b == 0x22:
            r = bytes([0x61,0x22])
            r += int((t.coolant_temp+273.1)*10).to_bytes(2,'big')
            r += int((t.iat+273.1)*10).to_bytes(2,'big')
            r += bytes([0x08,0xB7,0x08,0xB7,0x00,0x00,0x00,0x00])
            r += int(t.rail_actual*10).to_bytes(2,'big') + int(t.map_actual).to_bytes(2,'big')
            r += bytes([0x0B,0x84,0x03,0x9E,0x02,0x59,0x02,0xE4,0x02,0xE4,0x02,0xB1,0x08,0xB7,0x00,0x10])
            return r
        if b in (0x62,0xB0,0xB1,0xB2): return bytes([0x7F,0x21,0x33])
        return bytes([0x7F,0x21,0x12])

    def _io_ctrl(self, d): return bytes([0x7F,0x30,0x22])
    def _routine(self, d): return bytes([0x71, d[0]]) if d else bytes([0x7F,0x31,0x12])
    def _write_local(self, d): return bytes([0x7F,0x3B,0x79])


class ELM327Emulator:
    VER = "ELM327 v1.5"

    def __init__(self):
        self.state = VehicleState()
        self.kwp = KWP2000Responder(self.state)
        self.echo = True; self.headers = True; self.spaces = True; self.protocol = 2
        self.header_bytes = bytes([0x81,0x20,0xF1])

    def process_command(self, raw):
        c = raw.strip().upper().replace(" ","")
        if not c: return ""
        if c.startswith("AT"): return self._at(c[2:])
        return self._obd(c)

    def _at(self, a):
        if a=="Z": self.echo=True; self.headers=True; self.protocol=2; return self.VER
        if a=="I": return self.VER
        if a=="E0": self.echo=False; return "OK"
        if a=="E1": self.echo=True; return "OK"
        if a=="H0": self.headers=False; return "OK"
        if a=="H1": self.headers=True; return "OK"
        if a.startswith("IFR"): return "OK"
        if a=="RV": return "%.1fV" % self.state.battery_voltage
        if a.startswith("SP"):
            p=a[2:]; self.protocol=int(p) if p.isdigit() else 2; return "OK"
        if a.startswith("SH"):
            try:
                self.header_bytes=bytes.fromhex(a[2:])
                if len(self.header_bytes)>=2: self.state.active_target=self.header_bytes[1]
                log.info("Header -> target=0x%02X", self.state.active_target)
            except: pass
            return "OK"
        if a.startswith("WM"): return "OK"
        if a=="FI":
            if self.protocol==5: return "BUS INIT: OK"
            return "BUS INIT: ...ERROR"
        if a.startswith("RA"): return "OK"
        return "OK"

    def _obd(self, h):
        try: cb=bytes.fromhex(h)
        except: return "?"
        if not cb: return "?"
        if self.protocol==2: return self._j1850(cb[0], cb[1:])
        r = self.kwp.process(cb[0], cb[1:])
        return self._fmt(r) if r else "NO DATA"

    def _j1850(self, sid, data):
        t = self.state.active_target; self.state.tick()
        if t==0x40:
            if sid==0x20: return self._abs(data[0] if data else 0)
            if sid==0x24: return "26 40 64 00 00 00 00"
            if sid==0x01 and data and data[0]==0x01: return "26 40 51 01"
            return "NO DATA"
        if t==0x60:
            if sid==0x28:
                p=data[0] if data else 0
                return "26 60 7F 22 22 00 44" if p<=1 else "26 60 7F 22 12 00 85"
            if sid==0x0D: return "26 60 51 0D"
            return "NO DATA"
        return "NO DATA"

    def _abs(self, pid):
        if pid==0x00: return "26 40 62 05 08 00 E2"
        if pid==0x01: return "26 40 62 38 92 00 F0"
        if pid==0x02: return "26 40 62 41 43 00 E0"
        if pid==0x03: return "26 40 62 01 00 00 BE"
        if pid==0x04: return "26 40 62 1A 65 00 D8"
        if pid==0x05: return "26 40 62 41 00 00 DE"
        if pid==0x06: return "26 40 62 02 00 00 32"
        return "26 40 7F 22 12 00 44"

    def _fmt(self, raw):
        if self.headers:
            return " ".join(f"{b:02X}" for b in raw)
        p = raw[3:-1] if len(raw)>4 else raw
        return " ".join(f"{b:02X}" for b in p)


class ELM327Server:
    def __init__(self, host="0.0.0.0", port=35000):
        self.host=host; self.port=port

    async def handle_client(self, reader, writer):
        addr=writer.get_extra_info("peername"); log.info("Connected: %s", addr)
        elm=ELM327Emulator()
        try:
            buf=""
            while True:
                data=await reader.read(4096)
                if not data: break
                buf+=data.decode("latin-1")
                while "\r" in buf:
                    line,buf=buf.split("\r",1); line=line.strip()
                    if not line: continue
                    log.info("  <- %s", line)
                    resp=elm.process_command(line)
                    log.info("  -> %s", resp)
                    writer.write((resp+"\r\r>").encode("latin-1"))
                    await writer.drain()
        except: pass
        finally:
            log.info("Disconnected: %s", addr); writer.close()

    async def run(self):
        srv=await asyncio.start_server(self.handle_client, self.host, self.port)
        log.info("="*55)
        log.info("  WJ Diag ELM327 Emulator (Vehicle Verified)")
        log.info("  K-Line: ECU(0x15) + TCM(0x20) block 0x30")
        log.info("  J1850:  ABS(0x40) + Airbag(0x60)")
        log.info("  Port: %d", self.port)
        log.info("="*55)
        async with srv: await srv.serve_forever()


def main():
    p=argparse.ArgumentParser(); p.add_argument("--host",default="0.0.0.0"); p.add_argument("--port",type=int,default=35000)
    a=p.parse_args()
    try: asyncio.run(ELM327Server(a.host,a.port).run())
    except KeyboardInterrupt: log.info("Bye")

if __name__=="__main__": main()
