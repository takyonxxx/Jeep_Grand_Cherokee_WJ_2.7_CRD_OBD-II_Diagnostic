#!/usr/bin/env python3
"""
WJ Diag - ELM327 + Multi-Module Emulator (Real Vehicle Verified 2025-03-10)
===========================================================================
Jeep Grand Cherokee WJ 2.7 CRD diagnostic emulator.
Protocol verified against real vehicle logs.

K-Line Modules:
  - Engine ECU (0x15) Bosch EDC15C2 OM612
    Blocks: 0x10,0x12,0x14,0x16,0x18,0x20,0x22,0x24,0x26,0x28,0x30,0x40
    Security: Level 01, 2-byte key, NRC 0x35 (constants unknown)
    DTCs: P0520, P0579, P0340, P1242
  - TCM (0x20) NAG1 722.6 EGS52
    Blocks: 0x30(live),0x31,0x32,0x50,0x60,0x70,0x80,0xB0,0xC0,0xD0,0xE0,0xE1
    Security: EGS52, seed=6824(static), key=CC21
    1A: 86,87,90 supported; 91,92 NRC 0x12

J1850 VPW Modules:
  - ABS (0x40)  - PIDs 0x00-0x06+0x10, DTC via 24 00 00
  - Airbag (0x60) - NRC 0x12 on most
  - HVAC (0x68) - PIDs 0x00-0x03 respond
  - SKIM (0x62) - 1A 87 partial response
  - BCM (0x80), Cluster (0x90), Radio (0x87), EVIC (0x2A) - NO DATA

Usage:
    python wj_tcm_emulator.py [--host 0.0.0.0] [--port 35000]
"""

import argparse, asyncio, logging, math, random, time
from dataclasses import dataclass, field

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("WJ-EMU")


@dataclass
class VehicleState:
    # TCM
    turbine_rpm: float = 49.0
    output_rpm: float = 0.0
    vehicle_speed: float = 0.0
    trans_temp: int = 77        # raw value (raw-40=C, so 77 -> 37C)
    gear_selector: int = 8      # P=8,R=7,N=6,D=5
    engage_status: int = 0x1E   # P/N=0x1E(30), D=0x37(55)
    tcc_slip_actual: int = -31  # signed
    tcc_slip_desired: int = -31
    line_pressure: int = 221
    solenoid_mode: int = 0x96   # P/N=0x96, D=0x08
    # Engine
    engine_rpm: float = 750.0
    coolant_temp: float = 20.0
    iat: float = 18.0
    tps: float = 0.0
    map_actual: int = 920
    rail_actual: float = 290.0
    aap: int = 928
    maf_actual: float = 420.0
    maf_spec: float = 360.0
    injection_qty: float = 9.5
    battery_voltage: float = 14.5
    # DTCs
    tcm_dtc_list: list = field(default_factory=lambda: [
        (0x07, 0x10, 0x20),  # P0710 - Trans Fluid Temp Sensor
        (0x26, 0x02, 0x01),  # P2602 - Solenoid Supply Voltage
    ])
    ecu_dtc_list: list = field(default_factory=lambda: [
        (0x05, 0x20, 0x20),  # P0520
        (0x05, 0x79, 0x20),  # P0579
        (0x03, 0x40, 0x20),  # P0340
        (0x12, 0x42, 0xA0),  # P1242
    ])
    # J1850 DTC lists (raw bytes for J1850 response)
    abs_dtc_count: int = 2
    abs_dtcs_cleared: bool = False
    airbag_dtc_count: int = 1
    airbag_dtcs_cleared: bool = False
    # State
    active_target: int = 0x20
    tcm_security_unlocked: bool = False
    ecu_security_unlocked: bool = False
    _t0: float = 0.0

    def __post_init__(self):
        self._t0 = time.time()

    def tick(self):
        t = time.time() - self._t0
        self.engine_rpm = 750 + 30 * math.sin(t * 0.5) + random.uniform(-10, 10)

        # Gear shift simulation: every 15s cycle through gears
        # 0-15s: Park, 15-20s: Reverse, 20-25s: Neutral, 25+: Drive with shifts
        cycle_t = t % 90  # 90s full cycle
        if cycle_t < 15:
            # Park
            self.gear_selector = 8
            self.turbine_rpm = 20 + random.uniform(-5, 15)
            self.output_rpm = 0; self.vehicle_speed = 0
            self.engage_status = 0x1E; self.line_pressure = 221
            self.solenoid_mode = 0x96
            self.tcc_slip_actual = random.randint(-35, -25)
            self.tcc_slip_desired = self.tcc_slip_actual + random.randint(-3, 3)
        elif cycle_t < 20:
            # Reverse
            self.gear_selector = 7
            self.turbine_rpm = 700 + random.uniform(-30, 30)
            self.output_rpm = 200 + random.uniform(-20, 20)
            self.vehicle_speed = self.output_rpm * 0.0385
            self.engage_status = 0x3C; self.line_pressure = 400
            self.solenoid_mode = 0x00
            self.tcc_slip_actual = int(self.turbine_rpm - self.output_rpm)
            self.tcc_slip_desired = self.tcc_slip_actual + random.randint(-5, 5)
        elif cycle_t < 25:
            # Neutral
            self.gear_selector = 6
            self.turbine_rpm = 15 + random.uniform(-3, 10)
            self.output_rpm = 0; self.vehicle_speed = 0
            self.engage_status = 0x1E; self.line_pressure = 0
            self.solenoid_mode = 0x96
            self.tcc_slip_actual = random.randint(-15, -5)
            self.tcc_slip_desired = self.tcc_slip_actual
        else:
            # Drive with gear shifts
            self.gear_selector = 5
            drive_t = cycle_t - 25  # 0-65s of driving

            # NAG1 722.6 ratios: 1st=3.59, 2nd=2.19, 3rd=1.41, 4th=1.00, 5th=0.83
            gear_ratios = [3.59, 2.19, 1.41, 1.00, 0.83]

            # Determine current gear from drive_t
            if drive_t < 8:
                gear_idx = 0  # 1st gear
                self.engine_rpm = 1200 + 800 * (drive_t / 8.0) + random.uniform(-20, 20)
            elif drive_t < 16:
                gear_idx = 1  # 2nd gear
                self.engine_rpm = 1400 + 600 * ((drive_t - 8) / 8.0) + random.uniform(-20, 20)
            elif drive_t < 24:
                gear_idx = 2  # 3rd gear
                self.engine_rpm = 1600 + 400 * ((drive_t - 16) / 8.0) + random.uniform(-15, 15)
            elif drive_t < 35:
                gear_idx = 3  # 4th gear
                self.engine_rpm = 1800 + 200 * math.sin((drive_t - 24) * 0.3) + random.uniform(-15, 15)
            elif drive_t < 50:
                gear_idx = 4  # 5th gear cruise
                self.engine_rpm = 2000 + 100 * math.sin((drive_t - 35) * 0.2) + random.uniform(-10, 10)
            else:
                # Decelerating: downshift 5->3->1
                decel_phase = (drive_t - 50) / 15.0
                if decel_phase < 0.3:
                    gear_idx = 3  # 4th
                elif decel_phase < 0.6:
                    gear_idx = 2  # 3rd
                elif decel_phase < 0.85:
                    gear_idx = 1  # 2nd
                else:
                    gear_idx = 0  # 1st
                self.engine_rpm = max(750, 2000 - 1200 * decel_phase + random.uniform(-10, 10))

            ratio = gear_ratios[gear_idx]
            # Output RPM = engine RPM / (gear_ratio * final_drive)
            # But for block 0x30: turbine RPM / output RPM = gear_ratio
            # So: output = turbine / ratio
            self.turbine_rpm = self.engine_rpm * 0.97 + random.uniform(-15, 15)  # ~torque converter
            self.output_rpm = max(0, self.turbine_rpm / ratio + random.uniform(-10, 10))
            self.vehicle_speed = self.output_rpm * 0.0385

            self.engage_status = 0x34 + random.randint(-2, 2)
            self.line_pressure = 600 + int(200 * (gear_idx / 4.0)) + random.randint(-30, 30)
            self.solenoid_mode = 0x08
            self.tcc_slip_actual = int(self.turbine_rpm - self.output_rpm * ratio)
            self.tcc_slip_desired = self.tcc_slip_actual + random.randint(-5, 10)

        self.trans_temp = min(130, 77 + int(t * 0.02))
        self.coolant_temp = min(95, 20 + t * 0.05)
        self.iat = 18 + 2 * math.sin(t * 0.01)
        self.battery_voltage = 14.5 + random.uniform(-0.2, 0.2)
        self.maf_actual = 420 + 20 * math.sin(t * 0.3)
        self.maf_spec = 360 + 10 * math.sin(t * 0.2)
        self.rail_actual = 290 + 10 * math.sin(t * 0.2)
        self.injection_qty = 9.5 + 2 * math.sin(t * 0.4)


class KWP2000Responder:
    def __init__(self, s: VehicleState):
        self.s = s

    def process(self, sid, data):
        h = {
            0x14: self._clear_dtc, 0x17: self._read_dtc, 0x18: self._read_dtc,
            0x1A: self._read_ecu_id, 0x21: self._read_local, 0x27: self._security,
            0x30: self._io_ctrl, 0x31: self._routine, 0x3B: self._write_local,
            0x3E: self._tester, 0x81: self._startcomm,
        }.get(sid)
        if h:
            p = h(data)
            if p is not None:
                return self._wrap(p)
        return self._wrap(bytes([0x7F, sid, 0x11]))

    def _wrap(self, p):
        t = self.s.active_target
        if len(p) <= 63:
            f = 0x80 | (len(p) & 0x3F)
            frame = bytes([f, 0xF1, t]) + p
        else:
            frame = bytes([0x80, 0xF1, t, len(p) & 0xFF]) + p
        return frame + bytes([sum(frame) & 0xFF])

    def _startcomm(self, d):
        return bytes([0xC1, 0xEF, 0x8F])

    def _tester(self, d):
        return bytes([0x7E, d[0] if d else 0x01])

    def _security(self, d):
        if not d:
            return bytes([0x7F, 0x27, 0x12])
        if d[0] == 0x01:
            if self.s.active_target == 0x20:
                return bytes([0x67, 0x01, 0x68, 0x24, 0x89])
            else:
                seed = random.randint(0x0100, 0xFFFE)
                return bytes([0x67, 0x01, (seed >> 8) & 0xFF, seed & 0xFF])
        if d[0] == 0x02:
            if self.s.active_target == 0x20:
                if len(d) >= 3 and d[1] == 0xCC and d[2] == 0x21:
                    self.s.tcm_security_unlocked = True
                    return bytes([0x67, 0x02, 0x34])
                return bytes([0x7F, 0x27, 0x35])
            else:
                if len(d) == 3:
                    return bytes([0x7F, 0x27, 0x35])
                else:
                    return bytes([0x7F, 0x27, 0x12])
        if d[0] in (0x03, 0x41):
            return bytes([0x7F, 0x27, 0x12])
        return bytes([0x7F, 0x27, 0x12])

    def _read_dtc(self, d):
        self.s.tick()
        dtcs = self.s.ecu_dtc_list if self.s.active_target == 0x15 else self.s.tcm_dtc_list
        r = bytes([0x58, len(dtcs)])
        for h, l, s in dtcs:
            r += bytes([h, l, s])
        return r

    def _clear_dtc(self, d):
        if self.s.active_target == 0x15:
            self.s.ecu_dtc_list.clear()
        else:
            self.s.tcm_dtc_list.clear()
        return bytes([0x54, 0x00, 0x00])

    def _read_ecu_id(self, d):
        o = d[0] if d else 0x86
        if self.s.active_target == 0x20:
            if o == 0x86:
                return bytes([0x5A, 0x86, 0x56, 0x04, 0x19, 0x06, 0xBC, 0x03,
                              0x01, 0x02, 0x03, 0x08, 0x02, 0x00, 0x00, 0x03, 0x03, 0x11])
            if o == 0x87:
                return bytes([0x5A, 0x87, 0x02, 0x08, 0x02, 0x00, 0x00, 0x03, 0x01]) + b'56041906BC'
            if o == 0x90:
                return bytes([0x5A, 0x90]) + b'00000000000000000'
            return bytes([0x7F, 0x1A, 0x12])
        else:
            if o == 0x86:
                return bytes([0x5A, 0x86, 0xCA, 0x65, 0x34, 0x40, 0x65, 0x30,
                              0x99, 0x05, 0xF2, 0x03, 0x14, 0x14, 0x14, 0xFF, 0xFF, 0xFF])
            if o == 0x87:
                return bytes([0x7F, 0x1A, 0x12])
            if o == 0x90:
                return bytes([0x7F, 0x1A, 0x33])
            if o == 0x91:
                return bytes([0x5A, 0x91, 0x05, 0x10, 0x06, 0x05, 0x02, 0x0C,
                              0x1F, 0x0C, 0x0A, 0x10, 0x16, 0x06]) + b'  WCAAA '
            return bytes([0x7F, 0x1A, 0x12])

    def _read_local(self, d):
        if not d:
            return bytes([0x7F, 0x21, 0x12])
        b = d[0]
        self.s.tick()
        if self.s.active_target == 0x15:
            return self._ecu_block(b)
        return self._tcm_block(b)

    def _tcm_block(self, b):
        t = self.s
        if b == 0x30:
            rpm = max(0, int(t.turbine_rpm)) & 0xFFFF
            eng = t.engage_status & 0xFFFF
            out = max(0, int(t.output_rpm)) & 0xFFFF
            lp = t.line_pressure & 0xFFFF
            sa = t.tcc_slip_actual & 0xFFFF
            sd = t.tcc_slip_desired & 0xFFFF
            return bytes([0x61, 0x30,
                (rpm >> 8), rpm & 0xFF,
                (eng >> 8), eng & 0xFF,
                (out >> 8), out & 0xFF,
                0x00, t.gear_selector & 0xFF,
                0x04, (lp >> 8) & 0xFF, lp & 0xFF,
                t.trans_temp & 0xFF,
                (sa >> 8) & 0xFF, sa & 0xFF,
                (sd >> 8) & 0xFF, sd & 0xFF,
                0x05, 0xBF, t.solenoid_mode & 0xFF,
                0x08, 0x10, 0x00, 0x08])
        if b == 0x31:
            return bytes([0x61, 0x31, 0x01, 0xA8, 0x00, 0x00, 0x02, 0xB9,
                          0x02, 0xEC] + [0x00] * 14)
        if b == 0x32:
            return bytes([0x61, 0x32]) + bytes(16)
        if b == 0x50:
            return bytes([0x61, 0x50]) + bytes(51)
        if b == 0x60:
            return bytes([0x61, 0x60, 0x00, 0x01])
        if b == 0x70:
            d = bytes([0x61, 0x70, 0x00, 0x27, 0x00, 0xF4])
            for i in range(40):
                d += bytes([0x19 + (i % 6), 0x00, 0x2E + i, 0xFE, 0x0C, 0xB3 + (i % 10)])
            return d
        if b == 0x80:
            return bytes([0x61, 0x80, 0x03, 0x00, 0x00, 0x03, 0x38, 0x02, 0x02,
                          0x00, 0x0A, 0x00, 0x00, 0x02, 0x18, 0x08, 0x08, 0x00,
                          0x0A, 0x00, 0x00, 0x04, 0x18, 0x08, 0x08, 0x00, 0x0A])
        if b == 0xB0:
            return bytes([0x61, 0xB0]) + b'je0a'
        if b == 0xC0:
            return bytes([0x61, 0xC0, 0x00, 0x00, 0x64, 0x00, 0x19, 0x1E,
                          0x23, 0x28, 0x23, 0x28, 0x2D, 0x32, 0x2D, 0x32,
                          0x37, 0x3C, 0x37, 0x3C, 0x41, 0x46, 0x55, 0x5A,
                          0x5F, 0x64, 0x87, 0x8C, 0x91, 0x96, 0xB9, 0xBE, 0xC3, 0xC8])
        if b == 0xD0:
            return bytes([0x61, 0xD0]) + bytes(16)
        if b == 0xE0:
            return bytes([0x61, 0xE0]) + b'aafwspsp'
        if b == 0xE1:
            return bytes([0x61, 0xE1, 0x01, 0x61, 0x90, 0x46])
        return bytes([0x7F, 0x21, 0x12])

    def _ecu_block(self, b):
        t = self.s
        if b == 0x12:
            cr = int((t.coolant_temp + 273.1) * 10)
            ir = int((t.iat + 273.1) * 10)
            r = bytes([0x61, 0x12])
            r += cr.to_bytes(2, 'big') + ir.to_bytes(2, 'big')
            r += bytes([0x08, 0xB7, 0x08, 0xB7, 0x00, 0x00])
            r += int(t.tps * 100).to_bytes(2, 'big') + bytes([0x00, 0x00])
            r += int(t.map_actual).to_bytes(2, 'big') + bytes([0x03, 0x8E])
            r += int(t.rail_actual * 10).to_bytes(2, 'big')
            r += bytes([0x01, 0xDD, 0x01, 0x2A, 0x00, 0xAD])
            r += int(t.aap).to_bytes(2, 'big') + bytes([0x03, 0xA0, 0x00, 0x00])
            return r
        if b == 0x28:
            r = bytes([0x61, 0x28])
            r += int(t.engine_rpm).to_bytes(2, 'big')
            r += int(t.injection_qty * 100).to_bytes(2, 'big')
            r += bytes(26)
            return r
        if b == 0x20:
            r = bytes([0x61, 0x20])
            r += int(t.maf_actual).to_bytes(2, 'big') + int(t.maf_spec).to_bytes(2, 'big')
            r += bytes([0x03, 0xFE, 0x00, 0x00, 0x00, 0x93, 0x00, 0x48,
                        0x01, 0xAC, 0x01, 0x63, 0x01, 0x08, 0x02, 0xE8,
                        0x02, 0x58, 0x00, 0x8F, 0x00, 0x8A, 0x03, 0xA0, 0x02, 0x8B])
            return r
        if b == 0x22:
            cr = int((t.coolant_temp + 273.1) * 10)
            ir = int((t.iat + 273.1) * 10)
            r = bytes([0x61, 0x22])
            r += cr.to_bytes(2, 'big') + ir.to_bytes(2, 'big')
            r += bytes([0x08, 0xB7, 0x08, 0xB7, 0x00, 0x00, 0x00, 0x00,
                        0x02, 0x2E]) + int(t.map_actual).to_bytes(2, 'big')
            r += int(t.rail_actual * 10).to_bytes(2, 'big')
            r += bytes([0x03, 0x98, 0x02, 0x5A, 0x02, 0xE4, 0x02, 0xE4,
                        0x02, 0xBF, 0x08, 0xB7, 0x00, 0x00])
            return r
        if b == 0x10:
            return bytes([0x61, 0x10, 0x00, 0x5B, 0x00, 0x45, 0x00, 0x5A,
                          0x0B, 0xB8, 0x00, 0x00, 0x00, 0x37, 0x06, 0x18, 0x00, 0x00])
        if b == 0x14:
            return bytes([0x61, 0x14, 0x7D, 0xFE, 0x82, 0x41, 0x82, 0x41,
                          0xFF, 0x82, 0xE6, 0x07, 0xFF, 0xE6])
        if b == 0x16:
            return bytes([0x61, 0x16, 0x01, 0x2C, 0x21, 0x34, 0x01, 0x2C,
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                          0x00, 0x00, 0x01, 0xF4, 0x27, 0x10, 0x27, 0x10,
                          0x07, 0x94, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                          0x00, 0x00, 0x01, 0xF4, 0x00, 0x00, 0x00, 0x00])
        if b == 0x18:
            return bytes([0x61, 0x18]) + bytes(30)
        if b == 0x24:
            return bytes([0x61, 0x24, 0x06, 0x03, 0x00, 0x06, 0x00, 0x00,
                          0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                          0x00, 0x00, 0x07, 0x46, 0x07, 0xB9, 0x09, 0x4E,
                          0x07, 0x46, 0x00, 0x00])
        if b == 0x26:
            return bytes([0x61, 0x26, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                          0x5C, 0x6C, 0x7F, 0xFF, 0x00, 0x00, 0x2F, 0xA0,
                          0x00, 0x29, 0x00, 0x29, 0x00, 0x29, 0x00, 0x29,
                          0x00, 0x48, 0x00, 0x23, 0x00, 0x00, 0x0B, 0xCD])
        if b == 0x30:
            rpm = int(t.engine_rpm)
            return bytes([0x61, 0x30]) + rpm.to_bytes(2, 'big') + bytes([
                0x00, 0x00, 0x00, 0x00, 0x0A, 0xD9, 0x0A, 0xD9,
                0x03, 0xEA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x0B, 0x91, 0x00, 0x00, 0x00, 0x00])
        if b == 0x40:
            return bytes([0x61, 0x40]) + bytes(50)
        if b in (0x60, 0x62, 0xB0, 0xB1, 0xB2):
            return bytes([0x7F, 0x21, 0x33])
        return bytes([0x7F, 0x21, 0x12])

    def _io_ctrl(self, d):
        return bytes([0x7F, 0x30, 0x22])

    def _routine(self, d):
        return bytes([0x71, d[0]]) if d else bytes([0x7F, 0x31, 0x12])

    def _write_local(self, d):
        return bytes([0x7F, 0x3B, 0x79])


class ELM327Emulator:
    VER = "ELM327 v1.5"

    def __init__(self):
        self.state = VehicleState()
        self.kwp = KWP2000Responder(self.state)
        self.echo = True
        self.headers = True
        self.protocol = 2
        self.header_bytes = bytes([0x81, 0x20, 0xF1])
        self.header_mode = 0x22  # default data-read mode

    def process_command(self, raw):
        c = raw.strip().upper().replace(" ", "")
        if not c:
            return ""
        if c.startswith("AT"):
            return self._at(c[2:])
        return self._obd(c)

    def _at(self, a):
        if a == "Z":
            self.echo = True; self.headers = True; self.protocol = 2
            self.header_mode = 0x22
            return self.VER
        if a == "I":
            return self.VER
        if a in ("E0", "E1"):
            self.echo = (a == "E1"); return "OK"
        if a in ("H0", "H1"):
            self.headers = (a == "H1"); return "OK"
        if a.startswith("IFR"):
            return "OK"
        if a == "RV":
            return "%.1fV" % self.state.battery_voltage
        if a.startswith("SP"):
            p = a[2:]; self.protocol = int(p) if p.isdigit() else 2; return "OK"
        if a.startswith("SH"):
            try:
                self.header_bytes = bytes.fromhex(a[2:])
                if len(self.header_bytes) >= 2:
                    self.state.active_target = self.header_bytes[1]
                self.header_mode = self.header_bytes[2] if len(self.header_bytes) >= 3 else 0x22
                log.info("Header -> target=0x%02X mode=0x%02X", self.state.active_target, self.header_mode)
            except Exception:
                pass
            return "OK"
        if a.startswith("WM"):
            return "OK"
        if a == "FI":
            return "BUS INIT: OK" if self.protocol == 5 else "BUS INIT: ...ERROR"
        if a.startswith("RA"):
            return "OK"
        return "OK"

    def _obd(self, h):
        try:
            cb = bytes.fromhex(h)
        except Exception:
            return "?"
        if not cb:
            return "?"
        if self.protocol == 2:
            return self._j1850(cb[0], cb[1:])
        r = self.kwp.process(cb[0], cb[1:])
        return self._fmt(r) if r else "NO DATA"

    def _j1850(self, sid, data):
        t = self.state.active_target
        mode = self.header_mode
        self.state.tick()

        # === ECUReset mode (header mode=0x11) — used for DTC clear ===
        if mode == 0x11:
            # ABS clear: ATSH244011 -> 01 01 00 -> positive 0x51
            if t == 0x40 and sid == 0x01:
                self.state.abs_dtcs_cleared = True
                self.state.abs_dtc_count = 0
                log.info("  ** ABS DTCs cleared **")
                return "26 40 51 01"
            # Airbag clear: ATSH246011 -> 0D -> positive 0x51
            if t == 0x60 and sid == 0x0D:
                self.state.airbag_dtcs_cleared = True
                self.state.airbag_dtc_count = 0
                log.info("  ** Airbag DTCs cleared **")
                return "26 60 51 0D"
            return "NO DATA"

        # === ABS (0x40) — header mode 0x22 ===
        if t == 0x40:
            if sid == 0x24:
                # DTC read: 62 <count> <DTC_HI DTC_LO STATUS>...
                # C0031 = chassis,0,0,3,1 -> hi=0x40(01_00_0000) lo=0x31(0011_0001)
                # C0045 = chassis,0,0,4,5 -> hi=0x40(01_00_0000) lo=0x45(0100_0101)
                if self.state.abs_dtcs_cleared:
                    return "26 40 62 00 DD"  # 0 DTCs
                return "26 40 62 02 40 31 01 40 45 20 DD"
            if sid == 0x20:
                return self._abs_pid(data[0] if data else 0)
            if sid == 0x1A:
                return "26 40 7F 22 12 00 44"
            return "NO DATA"

        # === Airbag (0x60) ===
        if t == 0x60:
            if sid == 0x28:
                p = data[0] if data else 0
                if p == 0x37:
                    # DTC read: 68 <count> <DTC_HI DTC_LO STATUS>...
                    # B1000 = body,1,0,0,0 -> hi=0x90(10_01_0000) lo=0x00(0000_0000)
                    # B1010 = body,1,0,1,0 -> hi=0x90(10_01_0000) lo=0x10(0001_0000)
                    if self.state.airbag_dtcs_cleared:
                        return "26 60 68 00 DD"  # 0 DTCs
                    return "26 60 68 02 90 00 01 90 10 20 DD"
                return "26 60 7F 22 12 00 85"
            if sid == 0x1A:
                return "26 60 7F 22 12 00 85"
            return "NO DATA"

        # === HVAC (0x68) ===
        if t == 0x68:
            if sid == 0x28:
                p = data[0] if data else 0xFF
                m = {0x00: "26 68 62 47 00 00 6D", 0x01: "26 68 62 FF 00 00 89",
                     0x02: "26 68 62 7F 00 00 49", 0x03: "26 68 62 01 00 00 08",
                     0x37: "26 68 7F 22 52 00 18"}
                return m.get(p, "26 68 7F 22 12 00 F2")
            if sid in (0x1A, 0x22):
                return "26 68 7F 22 12 00 F2" if sid == 0x22 else "26 68 7F 22 52 00 18"
            return "NO DATA"

        # === SKIM (0x62) ===
        if t == 0x62:
            if sid == 0x1A:
                return "A4 62 81"
            return "NO DATA"

        # === BCM(0x80), Cluster(0x90), Radio(0x87), EVIC(0x2A), etc ===
        return "NO DATA"

    def _abs_pid(self, pid):
        v = {0x00: "26 40 62 43 00 00 DD", 0x01: "26 40 62 38 92 00 F0",
             0x02: "26 40 62 41 43 00 E0", 0x03: "26 40 62 01 00 00 BE",
             0x04: "26 40 62 1A 65 00 D8", 0x05: "26 40 62 41 00 00 DE",
             0x06: "26 40 62 02 00 00 32", 0x10: "26 40 62 08 00 00 3D"}
        return v.get(pid, "26 40 7F 22 12 00 44")

    def _fmt(self, raw):
        if self.headers:
            return " ".join(f"{b:02X}" for b in raw)
        p = raw[3:-1] if len(raw) > 4 else raw
        return " ".join(f"{b:02X}" for b in p)


class ELM327Server:
    def __init__(self, host="0.0.0.0", port=35000):
        self.host = host; self.port = port

    async def handle_client(self, reader, writer):
        addr = writer.get_extra_info("peername")
        log.info("Connected: %s", addr)
        elm = ELM327Emulator()
        try:
            buf = ""
            while True:
                data = await reader.read(4096)
                if not data:
                    break
                buf += data.decode("latin-1")
                while "\r" in buf:
                    line, buf = buf.split("\r", 1)
                    line = line.strip()
                    if not line:
                        continue
                    log.info("  <- %s", line)
                    resp = elm.process_command(line)

                    # Realistic response delay matching real ELM327 BLE timing
                    # Real vehicle pattern: K-Line reads alternate ~300ms and ~900ms
                    cmd = line.strip().upper()
                    if cmd.startswith("AT"):
                        if cmd.startswith("ATZ"):
                            delay = random.uniform(0.5, 0.8)   # ATZ reset: 500-800ms
                        else:
                            delay = random.uniform(0.15, 0.35)  # other AT: 150-350ms
                    elif cmd == "81":
                        delay = random.uniform(0.5, 0.7)        # StartComm: 500-700ms
                    elif cmd.startswith("27"):
                        delay = random.uniform(0.5, 0.7)        # Security: 500-700ms
                    elif cmd.startswith("21") or cmd.startswith("18") or cmd.startswith("14"):
                        # K-Line block reads: alternate 300ms and 900ms (real pattern)
                        if not hasattr(elm, '_read_toggle'):
                            elm._read_toggle = False
                        elm._read_toggle = not elm._read_toggle
                        if elm._read_toggle:
                            delay = random.uniform(0.25, 0.35)  # fast cycle
                        else:
                            delay = random.uniform(0.60, 0.95)  # slow cycle
                    elif cmd.startswith("1A"):
                        delay = random.uniform(0.4, 0.6)        # ECU ID: 400-600ms
                    else:
                        delay = random.uniform(0.2, 0.5)        # J1850/other: 200-500ms

                    await asyncio.sleep(delay)
                    log.info("  -> %s (%.0fms)", resp, delay * 1000)
                    writer.write((resp + "\r\r>").encode("latin-1"))
                    await writer.drain()
        except Exception:
            pass
        finally:
            log.info("Disconnected: %s", addr)
            writer.close()

    async def run(self):
        srv = await asyncio.start_server(self.handle_client, self.host, self.port)
        log.info("=" * 60)
        log.info("  WJ Diag ELM327 Emulator v9 (Vehicle Verified 2025-03-10)")
        log.info("  K-Line: ECU(0x15) 14 blocks + TCM(0x20) 12 blocks")
        log.info("  J1850:  ABS(0x40) HVAC(0x68) Airbag(0x60) SKIM(0x62)")
        log.info("  Port: %d", self.port)
        log.info("=" * 60)
        async with srv:
            await srv.serve_forever()


def main():
    p = argparse.ArgumentParser(description="WJ Diag ELM327 Emulator")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=35000)
    a = p.parse_args()
    try:
        asyncio.run(ELM327Server(a.host, a.port).run())
    except KeyboardInterrupt:
        log.info("Bye")


if __name__ == "__main__":
    main()
