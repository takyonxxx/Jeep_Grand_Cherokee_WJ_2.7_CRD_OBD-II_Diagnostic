#!/usr/bin/env python3
"""
WJ 2.7 CRD ELM327 simulator - PC port of the ESP32-S3 emulator
(Jeep_Grand_Cherokee_WJ_2.7_CRD_OBD-II_Diagnostic/esp32-emulator).

Listens on TCP (default 0.0.0.0:35000) and answers exactly like the
WiFi ELM327 clone + the real vehicle:
  * J1850 VPW modules (ABS, BCM, ESP, cluster, doors, HVAC, ...) from the
    real-vehicle response database (275 captured frames) + generic fallback
  * K-Line ECU 0x15 (EDC15C2) and TCM 0x20 (NAG1) with KWP2000 framing,
    ArvutaKoodi security, DTC read/clear, SID 0x30 actuators, SID 0x1A IDs
  * 40 s scripted engine transient model (pedal -> rpm -> boost -> MAF ->
    smoke limiter -> fuel -> rail / IAT) with 4 smoke-test fault scenarios
    (ATSMOKE0..3), real-car response timing (ATSIMDELAY0/1)

Android emulator: connect the app to 10.0.2.2:35000.
Phone on the same LAN: use this PC's IP.

    python wjdiag_sim.py [--port 35000] [--fast] [--smoke 1] [--quiet]
"""
import argparse
import json
import math
import os
import random
import re
import socket
import sys
import threading
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "j1850_db.json"), "r", encoding="utf-8") as _f:
    J1850_DB = json.load(_f)

AK_T1 = [0xC0,0xD0,0xE0,0xF0,0x00,0x10,0x20,0x30,0x40,0x50,0x60,0x70,0x80,0x90,0xA0,0xB0]
AK_T2 = [0x02,0x03,0x00,0x01,0x06,0x07,0x04,0x05,0x0A,0x0B,0x08,0x09,0x0E,0x0F,0x0C,0x0D]
AK_T3 = [0x90,0x80,0xF0,0xE0,0xD0,0xC0,0x30,0x20,0x10,0x00,0x70,0x60,0x50,0x40,0xB0,0xA0]
AK_T4 = [0x0D,0x0C,0x0F,0x0E,0x09,0x08,0x0B,0x0A,0x05,0x04,0x07,0x06,0x01,0x00,0x03,0x02]


def millis():
    return int(time.monotonic() * 1000)


def arand(a, b):
    """Arduino random(a, b): a <= r < b"""
    return random.randint(a, b - 1)


def hex8(v):
    return "%02X" % (v & 0xFF)


def hi8(v):
    return (int(v) >> 8) & 0xFF


def lo8(v):
    return int(v) & 0xFF


def u16clamp(v):
    if v < 0:
        return 0
    if v > 65535.0:
        return 65535
    return int(v + 0.5)


def s16raw(v):
    return int(v) & 0xFFFF


class SmokeSim:
    def __init__(self, mode=1):
        self.mode = mode
        self.lastMs = 0
        self.t = 0.0
        self.phase = 0
        self.loaded = False
        self.pedal = 0.0
        self.pedalStepAt = -10.0
        self.boostSet = 0.93
        self.boostAct = 0.93
        self.mafTrue = 480.0
        self.mafRep = 480.0
        self.driver = 0.0
        self.limiter = 30.0
        self.fuel = 8.8
        self.rail = 291.0
        self.iat = 30.0
        self.speed = 0.0
        self.gear = 0
        self.torque = 0.0
        self.corr = [0.22, 0.17, -1.42, 0.54, 0.47]   # 5 cyl smooth-running corrections, sum ~0 (real car)

    def afTrue(self):
        return self.mafTrue / self.fuel if self.fuel > 0.5 else 0.0


class Elm327Emu:
    def __init__(self, real_timing=True, smoke_mode=1):
        self.realTiming = real_timing
        self.sim = SmokeSim(smoke_mode)
        self.engineRpm = 750.0
        self.coolantTemp = 82.0
        self.transTemp = 77.0
        self.reset()

    # ------------------------------------------------------------ state
    def reset(self):
        keep = self.sim.mode
        self.targetModule = 0x20
        self.headerMode = 0x22
        self.protocol = 0
        self.headers = False
        self.echo = True
        self.ecuUnlocked = False
        self.tcmUnlocked = False
        self.ecuDtcCleared = False
        self.j1850DtcCleared = {}
        self.lastHeader = ""
        self.cmdCount = 0
        self._t0 = millis()
        self.klBusInitDone = False
        self.j1850NoiseCounter = 0
        self.sim = SmokeSim(keep)
        self.sim.lastMs = millis()
        self.stMs = 200
        self.atMode = 1
        self.klTarget = 0x20
        self.ecuSeed = 0
        self.ecuSeedZeroCount = 0
        self.espClearAttempts = 0
        self.tcmReadCount = 0
        self._simSpeed = 0
        self._speedUp = True
        self.corrRoutine = False   # ECU routine 0x25 active (31 25 00 / 32 25)

    # ------------------------------------------------------------ timing
    def response_delay_ms(self, cmd, resp):
        if not self.realTiming:
            return 0
        c = cmd.upper().strip()
        if c.startswith("ATZ"):
            return 900
        if c.startswith("ATFI"):
            return 0
        if c.startswith("AT"):
            return 50
        eff = self.stMs
        if self.atMode == 2 and eff > 80:
            eff = 80
        if resp.startswith("NO DATA"):
            return eff + 150
        nbytes = 0
        i = 0
        while i + 1 < len(resp):
            if resp[i] in "0123456789ABCDEFabcdef" and resp[i + 1] in "0123456789ABCDEFabcdef":
                nbytes += 1
                i += 2
            else:
                i += 1
        d = 40 + int(2.5 * nbytes) + eff
        if c.startswith("27"):
            d += 120
        elif c == "81":
            d += 80
        elif c.startswith("1A"):
            d += 30
        return d

    # ------------------------------------------------------------ engine model
    def tick(self):
        now = millis()
        dt = (now - self.sim.lastMs) / 1000.0
        if dt <= 0:
            return
        if dt > 0.5:
            dt = 0.5
        self.sim.lastMs = now
        self.sim_update(dt)
        t = (now - self._t0) / 1000.0
        self.coolantTemp = min(95.0, 82.0 + t * 0.02)
        self.transTemp = min(130.0, 57.0 + t * 0.02)

    def sim_update(self, dt):
        sim = self.sim
        sim.t += dt
        if sim.t >= 40.0:
            sim.t -= 40.0
        tc = sim.t
        if tc < 2.0:    phase, pedalTarget, loaded = 0, 0, False
        elif tc < 4.0:  phase, pedalTarget, loaded = 1, 15, True
        elif tc < 10.0: phase, pedalTarget, loaded = 2, 100, True
        elif tc < 14.0: phase, pedalTarget, loaded = 3, 0, True
        elif tc < 16.0: phase, pedalTarget, loaded = 4, 0, False
        elif tc < 18.0: phase, pedalTarget, loaded = 5, 15, True
        elif tc < 24.0: phase, pedalTarget, loaded = 6, 100, True
        elif tc < 28.0: phase, pedalTarget, loaded = 7, 0, True
        elif tc < 30.0: phase, pedalTarget, loaded = 8, 0, False
        elif tc < 30.6: phase, pedalTarget, loaded = 9, 100, False
        elif tc < 33.0: phase, pedalTarget, loaded = 10, 0, False
        elif tc < 33.6: phase, pedalTarget, loaded = 11, 100, False
        else:           phase, pedalTarget, loaded = 12, 0, False
        sim.phase = phase
        sim.loaded = loaded

        pedalRate = 350.0 * dt
        prevPedal = sim.pedal
        if sim.pedal < pedalTarget:
            sim.pedal = min(pedalTarget, sim.pedal + pedalRate)
        else:
            sim.pedal = max(pedalTarget, sim.pedal - pedalRate)
        if prevPedal < 50.0 <= sim.pedal:
            sim.pedalStepAt = tc
        sinceStep = tc - sim.pedalStepAt

        rpm = self.engineRpm
        if sim.pedal > 5.0:
            target = 750.0 + sim.pedal * (33.0 if loaded else 32.0)
            rate = 550.0 * (sim.pedal / 100.0) if loaded else 2500.0
            if rpm < target:
                rpm = min(target, rpm + rate * dt)
        else:
            rate = 800.0 if loaded else 1200.0
            if rpm > 750.0:
                rpm = max(750.0, rpm - rate * dt)
        if rpm > 4200.0:
            rpm = 4200.0
        if sim.pedal < 5.0 and rpm < 800.0:
            rpm = 750.0 + 8.0 * math.sin(millis() / 400.0) + arand(-3, 3)
        self.engineRpm = rpm

        if rpm < 1200.0:   gaugeMax = 0.15
        elif rpm < 1500.0: gaugeMax = 0.15 + (rpm - 1200.0) / 300.0 * 0.35
        elif rpm < 2000.0: gaugeMax = 0.50 + (rpm - 1500.0) / 500.0 * 0.45
        elif rpm < 2500.0: gaugeMax = 0.95 + (rpm - 2000.0) / 500.0 * 0.20
        elif rpm < 3500.0: gaugeMax = 1.15
        else:              gaugeMax = 1.15 - (rpm - 3500.0) / 700.0 * 0.15
        sim.boostSet = 0.93 + gaugeMax * (sim.pedal / 100.0)

        if sim.mode == 1:
            tau = 4.0 if rpm < 1800.0 else 2.5
        else:
            tau = 1.8 if rpm < 1400.0 else 0.8
        if not loaded:
            tau *= 2.0
        setEff = sim.boostSet
        if sim.mode == 1:
            setEff = min(setEff, sim.boostSet - 0.5 * (sim.pedal / 100.0))
        if setEff < 0.93:
            setEff = 0.93
        tauEff = 0.5 if sim.boostAct > setEff else tau
        sim.boostAct += (setEff - sim.boostAct) * (dt / tauEff)

        gauge = sim.boostAct - 0.93
        iatTarget = 30.0 + gauge * (35.0 if sim.mode == 1 else 20.0)
        sim.iat += (iatTarget - sim.iat) * (dt / 3.0)

        tK = sim.iat + 273.15
        sim.mafTrue = sim.boostAct * 100000.0 * 0.000537 / (287.0 * tK) * 1e6 * 0.85
        sim.mafRep = sim.mafTrue * 1.30 if sim.mode == 2 else sim.mafTrue
        sim.mafRep += arand(-30, 30) / 10.0

        sim.driver = 8.8 + (sim.pedal / 100.0) * 52.0
        limAF = 18.5
        if sim.mode == 1 and 0 <= sinceStep < 1.5:
            limAF = 13.5
        sim.limiter = sim.mafRep / limAF
        fuel = min(sim.driver, sim.limiter)
        if sim.mode == 3:
            fuel = min(sim.driver, sim.limiter * 1.35)
        if rpm > 4000.0:
            fuel = min(fuel, 20.0)
        if sim.pedal < 5.0:
            fuel = 0.0 if rpm > 900.0 else 8.8
        if (not loaded) and sim.pedal >= 5.0 and rpm > 3000.0:
            fuel = min(fuel, 15.0)
        sim.fuel += (fuel - sim.fuel) * min(1.0, dt / 0.08)
        if sim.fuel < 0:
            sim.fuel = 0.0

        railTarget = 291.0 + (rpm - 750.0) / 3250.0 * 500.0 + sim.fuel * 12.0
        if railTarget > 1350.0:
            railTarget = 1350.0
        sim.rail += (railTarget - sim.rail) * min(1.0, dt / 0.3)

        speedTarget = rpm / 60.0 if loaded else 0.0
        sim.speed += (speedTarget - sim.speed) * min(1.0, dt / 1.0)
        if not loaded:
            sim.gear = 0
        else:
            s = sim.speed
            sim.gear = 1 if s < 12 else 2 if s < 25 else 3 if s < 45 else 4 if s < 70 else 5
        sim.torque = -560.0 if (fuel < 0.5 and rpm > 900.0) else fuel * 90.0

        if sim.mode == 3:
            base = [-4.2, 3.8, 0.9, -1.1, 0.6]
            sim.corr = [b + arand(-30, 30) / 100.0 for b in base]
        else:
            base = [0.22, 0.17, -1.42, 0.54, 0.47]
            sim.corr = [b + arand(-6, 6) / 100.0 for b in base]

    # ------------------------------------------------------------ AT
    def handle_at(self, cmd):
        c = cmd.upper().strip()
        if c.startswith("ATZ"):
            self.echo = True
            self.reset()
            return "OBDII  v1.5"
        if c == "ATI":
            return "OBDII  v1.5"
        if c == "AT@1":
            return "OBDII to RS232 Interpreter"
        if c == "AT@2":
            return "?"
        if c == "ATRV":
            return "%.1fV" % (14.2 + arand(-20, 20) / 100.0)
        if c.startswith("ATE"):
            self.echo = "1" in c
            return "OK"
        if c.startswith("ATSP"):
            try:
                self.protocol = int(c[4])
            except (ValueError, IndexError):
                self.protocol = 0
            return "OK"
        if c.startswith("ATSH"):
            hdr = c[4:].strip()
            self.lastHeader = hdr
            try:
                if len(hdr) >= 6 and hdr.startswith("24"):
                    self.targetModule = int(hdr[2:4], 16)
                    self.headerMode = int(hdr[4:6], 16)
                elif len(hdr) >= 6 and hdr.startswith("81"):
                    self.klTarget = int(hdr[2:4], 16)
                    self.targetModule = self.klTarget
                elif len(hdr) >= 4:
                    self.targetModule = int(hdr[2:4], 16)
            except ValueError:
                pass
            return "OK"
        if c.startswith("ATH"):
            self.headers = "1" in c
            return "OK"
        if c.startswith("ATRA") or c.startswith("ATAR"):
            return "OK"
        if c.startswith("ATWM"):
            return "OK"
        if c.startswith("ATFI"):
            self.klBusInitDone = True
            return "OK"
        if c.startswith("ATSIMDELAY"):
            if len(c) > 10:
                self.realTiming = c[10] != "0"
            return "SIM DELAY " + ("ON (real-car timing)" if self.realTiming else "OFF (instant)")
        if c.startswith("ATST"):
            v = c[4:].strip()
            try:
                self.stMs = int(v[:2], 16) * 4
            except ValueError:
                pass
            return "OK"
        if c.startswith("ATAT"):
            if len(c) > 4 and c[4] in "012":
                self.atMode = int(c[4])
            return "OK"
        if c.startswith("ATSMOKE"):
            if len(c) > 7 and c[7] in "0123":
                self.sim.mode = int(c[7])
            names = ["HEALTHY", "VNT LAG + OVERFUEL", "MAF OVER-READING", "INJECTOR EXCESS"]
            return "SMOKE MODE %d %s" % (self.sim.mode, names[self.sim.mode])
        if c.startswith(("ATIFR", "ATL", "ATM", "ATS")):
            return "OK"
        if c.startswith("ATDP"):
            return "SAE J1850 VPW" if self.protocol == 2 else "ISO 14230-4"
        if c.startswith("AT"):
            return "OK"
        return "?"

    # ------------------------------------------------------------ main
    def process_command(self, raw):
        cmd = raw.strip()
        if not cmd:
            return ""
        self.cmdCount += 1
        if cmd.upper().startswith("AT"):
            return self.handle_at(cmd)
        clean = cmd.replace(" ", "").upper()
        try:
            data = bytes.fromhex(clean[: len(clean) & ~1])
        except ValueError:
            return "?"
        if not data:
            return "?"
        data = data[:32]
        self.tick()
        if self.protocol == 2:
            cmdUpper = cmd.upper().strip()
            resp = self.j1850_vehicle_lookup(self.targetModule, self.headerMode, cmdUpper)
            if not resp:
                resp = self.j1850_generic(self.targetModule, self.headerMode, data[0], data[1:])
            self.j1850NoiseCounter += 1
            if self.j1850NoiseCounter % 7 == 0 and resp and not resp.startswith("NO"):
                noise = "2D 28 0A B9" if self.j1850NoiseCounter % 14 == 0 else "2D 28 02 51"
                resp = noise + "\r" + resp
            if self.headerMode == 0x22 and self.j1850NoiseCounter % 20 == 3 and resp.find("62") > 0:
                resp = "26 " + hex8(self.targetModule) + " 7F 22 21 00 78"
            return resp
        return self.kwp_process(data[0], data[1:])

    # ------------------------------------------------------------ J1850
    def j1850_generic(self, t, m, sid, data):
        pid = data[0] if len(data) > 0 else 0
        val = data[1] if len(data) > 1 else 0
        if m == 0x14:
            if t == 0x58:
                self.espClearAttempts += 1
                if self.espClearAttempts >= 7:
                    self.j1850DtcCleared[t] = True
                    self.espClearAttempts = 0
                    return "26 58 54 01 00 00 21"
                return "NO DATA"
            self.j1850DtcCleared[t] = True
            return "26 " + hex8(t) + " 54 FF 00 00 DD"
        if m == 0x18:
            if self.j1850DtcCleared.get(t):
                return "26 " + hex8(t) + " 58 00"
            if t == 0x40: return "26 40 7F 18 11 00 B7"
            if t == 0x28: return "26 28 7F 18 22 00 8B"
            if t == 0xA7: return "26 A7 58 01 05 11 20 DD"
            if t == 0x58: return "26 58 7F 18 11 00 2E"
            if t == 0x60: return "26 60 58 02 60 10 20 60 15 20 DD"
            if t == 0x61: return "26 61 58 01 61 30 20 DD"
            if t == 0xA0: return "26 A0 58 01 A0 11 20 DD"
            if t == 0xA1: return "26 A1 58 01 A1 11 20 DD"
            if t == 0xC0: return "26 C0 58 01 C0 10 20 DD"
            return "26 " + hex8(t) + " 58 00"
        if m == 0x10:
            return "26 " + hex8(t) + " 50 " + hex8(sid)
        if m == 0x11:
            if sid == 0x01:
                return "26 " + hex8(t) + " 51 01"
            return "26 " + hex8(t) + " 7F 11 12 00 DD"
        if m == 0x2F:
            if sid == 0x38:
                return "26 " + hex8(t) + " 6F 38 " + hex8(pid) + " " + hex8(val) + " DD"
            if sid == 0x3A:
                return "26 " + hex8(t) + " 6F 3A " + hex8(pid) + " " + hex8(val) + " DD"
            return "26 " + hex8(t) + " 7F 2F 12 00 DD"
        if m == 0xB4:
            if sid == 0x28:
                return "26 " + hex8(t) + " E8 " + hex8(pid) + " 00 00 DD"
            if sid == 0x38:
                return "26 " + hex8(t) + " 6F 38 " + hex8(pid) + " " + hex8(val) + " DD"
            return "26 " + hex8(t) + " 7F B4 12 00 DD"
        if t in (0x80, 0x2A):
            return "NO DATA"
        if t == 0x60:
            return "26 60 7F 22 22 00 44"
        return "26 " + hex8(t) + " 62 " + hex8(pid) + " 00 00 DD"

    def j1850_vehicle_lookup(self, t, m, cmdStr):
        # dynamic entries (order as in the C++ source)
        if t == 0x28:
            if m == 0x30:
                return "26 28 70 " + cmdStr + " DD"
            if m == 0xA3:
                return "26 28 E3 02 EE 00 0A DD"
            if m == 0xA0:
                return "26 28 E0 " + cmdStr + " DD"
        if t == 0x40 and m == 0xB4:
            if cmdStr == "28 3F 00":
                return "26 40 F4 28 3F 00 16"
            return "26 40 F4 " + cmdStr + " DD"
        if t == 0x58 and m == 0x22 and cmdStr == "2E E5 00":
            return "26 58 62 00 00 00 A8" if self.j1850DtcCleared.get(0x58) else "26 58 62 10 00 00 B0"
        key = "%02X:%02X:%s" % (t, m, cmdStr)
        hit = J1850_DB.get(key)
        if hit is not None:
            return hit
        if t == 0x60:
            # Capture mode: answer anything to the airbag module with a generic positive
            # reply (SID|0x40) so WJdiag-Pro keeps going and we log its whole sequence.
            if getattr(self, "airbagEcho", False):
                toks = cmdStr.split()
                try:
                    sid = int(toks[0], 16)
                except Exception:
                    sid = 0
                rest = " ".join(toks[1:])
                if sid == 0x27 and rest.startswith("01"):
                    return "26 60 67 01 12 34 DD"          # security seed -> WJdiag-Pro sends the key next
                pos = "%02X" % ((sid | 0x40) & 0xFF)
                return ("26 60 %s %s DD" % (pos, rest)).replace("  ", " ").strip()
            # Airbag / ORC. Real WJdiag-Pro method (confirmed from APK v28, libnative-lib.so):
            # header ATSH246022, DTC read = service "18 02 FF 00" -> 58 frame,
            # clear = "14 00 00" -> 54. Two stored faults (B1010=90 10, B1051=90 51)
            # until cleared. Legacy 2E/mode-0x14 branches kept for the old app build.
            cs = cmdStr.strip()
            if cs.startswith("18 02"):
                if self.j1850DtcCleared.get(0x60):
                    return "26 60 58 00"
                return "26 60 58 02 90 10 20 90 51 20 DD"
            if cs.startswith("14 00"):
                self.j1850DtcCleared[0x60] = True
                return "26 60 54 00 00 DD"
            if m == 0x22:
                mm = re.match(r"2E ([0-9A-F]{2}) 00$", cmdStr)
                if mm:
                    pid = int(mm.group(1), 16)
                    if pid in (0x10, 0x51) and not self.j1850DtcCleared.get(0x60):
                        return "26 60 62 01 00 02 EB"
                    return "26 60 62 00 00 00 E8"
            if m == 0x14:
                self.j1850DtcCleared[0x60] = True
                return "26 60 54 FF 00 00 D9"
            return "26 60 7F 22 22 00 44"
        if t in (0x81, 0x62, 0x6D, 0x87, 0x90):
            return "NO DATA"
        if t == 0x68:
            if m == 0x31 and cmdStr == "01 00 00":
                return "26 68 71 01 00 E1 38"
            if m == 0x33 and cmdStr == "01 00 00":
                return "26 68 73 01 00 E4 76"
            if m == 0x14:
                return "NO DATA"
            if m == 0x11:
                return "NO DATA"
        return ""

    # ------------------------------------------------------------ KWP2000
    def kwp_wrap(self, payload):
        p = bytes(payload)
        plen = len(p)
        if plen <= 63:
            frame = bytes([0x80 | (plen & 0x3F), 0xF1, self.klTarget]) + p
        else:
            frame = bytes([0x80, 0xF1, self.klTarget, plen & 0xFF]) + p
        cs = sum(frame) & 0xFF
        frame += bytes([cs])
        if self.headers:
            return " ".join(hex8(b) for b in frame)
        start = 4 if frame[0] == 0x80 else 3
        return " ".join(hex8(b) for b in frame[start:-1])

    def kwp_process(self, sid, data):
        dlen = len(data)
        W = self.kwp_wrap
        if sid == 0x81:
            resp = W([0xC1, 0xEF, 0x8F])
            if not self.klBusInitDone:
                self.klBusInitDone = True
                return "BUS INIT: OK\r" + resp
            return resp
        if sid == 0x82:
            return W([0xC2])
        if sid == 0x3E:
            return W([0x7E, data[0] if dlen > 0 else 0x01])
        if sid == 0x27:
            if dlen > 0 and data[0] == 0x01:
                if self.klTarget == 0x20:
                    return W([0x67, 0x01, 0x68, 0x24, 0x89])
                self.ecuSeedZeroCount += 1
                if self.ecuUnlocked or self.ecuSeedZeroCount <= 3:
                    self.ecuUnlocked = True
                    self.ecuSeed = 0
                    return W([0x67, 0x01, 0x00, 0x00])
                self.ecuSeed = arand(0x0100, 0xFFFE)
                return W([0x67, 0x01, (self.ecuSeed >> 8) & 0xFF, self.ecuSeed & 0xFF])
            if dlen >= 1 and data[0] == 0x02:
                if dlen == 1:
                    return W([0x7F, 0x27, 0x12])
                if self.klTarget == 0x20:
                    if dlen >= 3 and data[1] == 0xCC and data[2] == 0x21:
                        self.tcmUnlocked = True
                        return W([0x67, 0x02, 0x34])
                else:
                    if self.ecuSeed == 0:
                        return W([0x7F, 0x27, 0x12])
                    s0 = (self.ecuSeed >> 8) & 0xFF
                    s1 = self.ecuSeed & 0xFF
                    v1 = (s1 + 0x0B) & 0xFF
                    keyLo = AK_T1[(v1 >> 4) & 0xF] | AK_T2[v1 & 0xF]
                    cond = 1 if s1 > 0x34 else 0
                    v2 = (s0 + cond + 1) & 0xFF
                    keyHi = AK_T3[(v2 >> 4) & 0xF] | AK_T4[v2 & 0xF]
                    if dlen >= 3 and data[1] == keyHi and data[2] == keyLo:
                        self.ecuUnlocked = True
                        return W([0x67, 0x02, 0x34])
                return W([0x7F, 0x27, 0x35])
            return W([0x7F, 0x27, 0x12])
        if sid == 0x21:
            return self.kwp_read_block(data[0] if dlen > 0 else 0)
        if sid == 0x1A:
            return self.kwp_ecu_id(data[0] if dlen > 0 else 0x86)
        if sid in (0x17, 0x18):
            if self.klTarget == 0x20:
                if self.ecuDtcCleared:
                    return W([0x58, 0x00])
                return W([0x58, 0x01, 0x22, 0x10, 0x20])
            if self.ecuDtcCleared:
                return W([0x58, 0x00])
            return W([0x58, 0x01, 0x07, 0x02, 0xE0])
        if sid == 0x14:
            self.ecuDtcCleared = True
            return W([0x54, 0x00, 0x00])
        if sid == 0x30:
            if self.klTarget == 0x20:
                return W([0x7F, 0x30, 0x22])
            plen = min(dlen, 5)
            pos = W([0x70] + list(data[:plen]))
            if dlen >= 3 and data[0] == 0x3A and data[1] >= 0x08:
                return W([0x7F, 0x30, 0x78]) + "\r" + pos
            return pos
        if sid == 0x31:
            # real car: "31 25 00" -> "71 25 00" (fuel-correction routine); TCM 31 31/32 adaptives
            if dlen >= 1 and data[0] == 0x25 and self.klTarget != 0x20:
                self.corrRoutine = True
                return W([0x71, 0x25, 0x00])
            return W([0x71, data[0] if dlen >= 1 else 0x00])
        if sid == 0x32:
            if dlen >= 1 and data[0] == 0x25:
                self.corrRoutine = False
            return W([0x72, data[0] if dlen >= 1 else 0x00])
        return W([0x7F, sid, 0x11])

    def kwp_ecu_id(self, opt):
        W = self.kwp_wrap
        if self.klTarget == 0x20:
            if opt == 0x90:
                return W([0x5A, 0x90] + [ord("0")] * 17)
            if opt == 0x86:
                return W([0x5A,0x86,0x56,0x04,0x19,0x06,0xBC,0x03,0x01,0x02,0x03,0x08,0x02,0x00,0x00,0x03,0x03,0x11])
            if opt == 0x87:
                return W([0x5A,0x87,0x02,0x08,0x02,0x00,0x00,0x03,0x01])
            if opt == 0x91:
                return W([0x5A,0x91,0x56,0x04,0x19,0x06])
        else:
            if opt == 0x86:
                return W([0x5A,0x86,0xCA,0x65,0x34,0x40,0x65,0x30,0x99,0x05,0xF2,0x03,0x14,0x14,0x14,0xFF,0xFF,0xFF])
            if opt == 0x90:
                if self.ecuUnlocked:
                    return W([0x5A, 0x90] + list(b"1J8GWE82X2Y122006"))
                return W([0x7F, 0x1A, 0x33])
            if opt == 0x91:
                return W([0x5A,0x91,0x05,0x10,0x06,0x05,0x02,0x0C,0x1F,0x0C,0x0A,0x10,0x16,0x06,0x20,0x20,0x57,0x43,0x41,0x41,0x41,0x20])
        return W([0x7F, 0x1A, 0x12])

    def kwp_read_block(self, blk):
        W = self.kwp_wrap
        sim = self.sim
        if self.klTarget == 0x20:
            if blk == 0x30:
                self.tick()
                self.tcmReadCount += 1
                phase = (self.tcmReadCount // 8) % 7
                tbl = [(8,0,0x00,0,0),(5,1,0x11,1800,500),(5,2,0x22,1650,750),(5,3,0x33,1550,1100),
                       (5,4,0x44,1500,1500),(5,5,0x55,1400,1700),(8,0,0x00,0,0)]
                selector, gearNum, gearX11, turbRpm, outputRpm = tbl[phase]
                tccA = 20 if selector == 5 else 0
                tccD = 30 if selector == 5 else 0
                traw = int(self.transTemp + 50) & 0xFF
                r = [0x61,0x30, hi8(tccA),lo8(tccA), hi8(tccD),lo8(tccD), hi8(outputRpm),lo8(outputRpm),
                     0x00, selector, 0x04, gearNum, gearX11, traw, 0xFF,0xF6, 0xFF,0xF6, 0x00,0x00, 0x96,0x18, 0x00,0x08]
                return W(r)
            if blk == 0x31:
                self.tick()
                n2 = int(self.engineRpm * 0.59); n3 = 0
                turbine = int(self.engineRpm * 0.97); eng = int(self.engineRpm)
                r = [0x61,0x31, hi8(n2),lo8(n2), hi8(n3),lo8(n3), hi8(turbine),lo8(turbine), hi8(eng),lo8(eng)] + [0]*12
                return W(r)
            if blk == 0x34:
                return W([0x61,0x34, 0x02,0x0C, 0x03,0xFF, 0x03,0x32, 0x02,0x0A, 0x08,0x07, 0x00,0x01, 0x00,0x28])
            if blk == 0x33:
                return W([0x61,0x33, 0x00,0x24, 0x07,0x71, 0x05,0xDC, 0x02,0xAE, 0x02,0xA7, 0x02,0xD7, 0x02,0xD1, 0x00,0x00])
            if blk == 0x32:
                if self._speedUp:
                    self._simSpeed += 3
                    if self._simSpeed >= 30: self._speedUp = False
                else:
                    self._simSpeed -= 3
                    if self._simSpeed <= 0: self._simSpeed = 0; self._speedUp = True
                return W([0x61,0x32, self._simSpeed & 0xFF] + [0]*12)
            return W([0x61, blk] + [0]*16)

        # ECU blocks
        if blk == 0x12:
            self.tick()
            cr = int((self.coolantTemp + 273.1) * 10)
            iatR = u16clamp((sim.iat + 273.1) * 10)
            rpm = int(self.engineRpm)
            iq = u16clamp(sim.fuel * 100)
            mapR = u16clamp(sim.boostAct * 1000)
            railR = u16clamp(sim.rail / 0.101)
            ped = u16clamp(sim.pedal * 100)
            r = [0x61,0x12, hi8(cr),lo8(cr), hi8(iatR),lo8(iatR), 0x08,0xB7, 0x08,0xB7, 0x00,0x00,
                 hi8(rpm),lo8(rpm), hi8(ped),lo8(ped), hi8(iq),lo8(iq), hi8(mapR),lo8(mapR), hi8(railR),lo8(railR),
                 0x02,0xA6, 0x01,0x2A, 0x00,0x42, 0x09,0x7F, 0x03,0xA0, 0x00,0x00]
            return W(r)
        if blk == 0x22:
            self.tick()
            cr = int((self.coolantTemp + 273.1) * 10)
            iatR = u16clamp((sim.iat + 273.1) * 10)
            mapR = u16clamp(sim.boostAct * 1000)
            r = [0x61,0x22, hi8(cr),lo8(cr), hi8(iatR),lo8(iatR), 0x08,0xB7, 0x08,0xB7, 0x00,0x00, 0x00,0x00,
                 0x02,0x11, hi8(mapR),lo8(mapR), 0x0B,0x97, 0x03,0x94, 0x02,0x4E, 0x02,0xE4, 0x02,0xE4,
                 0x02,0xBF, 0x08,0xB7, 0x00,0x0F]
            return W(r)
        if blk == 0x28:
            self.tick()
            rpm = int(self.engineRpm)
            iq = u16clamp(sim.fuel * 100)
            idle = self.engineRpm < 1000.0
            cyl = rpm if idle else 0
            # [16-25] = five signed per-cylinder corrections (real car: 0016 0011 FF72 0036 002F, sum ~0)
            c = [s16raw(int(sim.corr[i] * 100)) if (idle and self.corrRoutine) else 0 for i in range(5)]  # only while routine 0x25 runs (pcap)
            r = [0x61,0x28, hi8(rpm),lo8(rpm), hi8(iq),lo8(iq)]
            for _ in range(5):
                r += [hi8(cyl), lo8(cyl)]
            r += [0x00,0x00]
            for v in c:
                r += [hi8(v), lo8(v)]
            r += [0x00,0x00]
            return W(r)
        if blk in (0x62, 0xB0, 0xB1, 0xB2):
            if not self.ecuUnlocked:
                return W([0x7F, 0x21, 0x33])
            return W({0x62: [0x61,0x62,0x33,0x4A,0x94,0x84], 0xB0: [0x61,0xB0,0x37,0x0F],
                      0xB1: [0x61,0xB1,0xD2,0x15], 0xB2: [0x61,0xB2,0xE0,0x4B]}[blk])
        if blk == 0x30:
            return W([0x61,0x30, 0x02,0xEE, 0x00,0x00, 0x00,0x00, 0x0C,0x91, 0x0C,0x92, 0x03,0xE5,
                      0x00,0x00, 0x00,0x00, 0x00,0x00, 0x0B,0x77, 0x00,0x00, 0x00,0x00])
        if blk == 0x23:
            self.tick()
            bs = u16clamp(sim.boostAct * 2600.0)
            bg = u16clamp(3031.0 + (sim.boostAct - 0.93) * 1000.0)
            return W([0x61,0x23, hi8(bs),lo8(bs), 0x02,0x4D, 0xFF,0xF9, hi8(bg),lo8(bg), 0x03,0x9F, 0x02,0x7A,
                      0x00,0x7E, 0x00,0x30, 0x03,0xFD, 0x01,0x2A])
        if blk == 0x21:
            self.tick()
            wish = u16clamp(sim.driver * 100); lim = u16clamp(sim.limiter * 100)
            dem = u16clamp(sim.fuel * 100); drv = u16clamp((sim.pedal / 100.0) * 52.0 * 100)
            return W([0x61,0x21, hi8(wish),lo8(wish), hi8(lim),lo8(lim), hi8(dem),lo8(dem), hi8(drv),lo8(drv),
                      0x01,0x2A, 0x01,0x2A, hi8(lim),lo8(lim), 0x01,0xEF, 0x00,0xB4, 0x01,0x5D])
        if blk == 0x16:
            return W([0x61,0x16, 0x01,0x2C, 0x21,0x40] + [0]*18 + [0x27,0x10, 0x07,0xDA] + [0]*6 + [0,0, 0x01,0xF4, 0,0, 0,0])
        if blk == 0x32:
            self.tick()
            fa = u16clamp(sim.fuel * 100); spd = u16clamp(sim.speed)
            return W([0x61,0x32, hi8(fa),lo8(fa), 0x0A,0xD8, hi8(spd),lo8(spd), hi8(spd),lo8(spd), 0x0C,0xE4,
                      hi8(fa),lo8(fa), hi8(fa),lo8(fa), 0x01,0x89, 0x01,0xA2, 0x00,0xFA, 0x00,0x30, 0x02,0x6E, 0x02,0xC9,
                      0,0, 0,0, 0,0])
        if blk == 0x37:
            self.tick()
            wg = u16clamp(3144.0 + (sim.boostSet - 0.93) / 1.2 * 1440.0)
            return W([0x61,0x37, 0x0C,0x97, hi8(wg),lo8(wg), 0x00,0x79, 0,0, 0x00,0x08, 0,0, 0,0, 0,0, 0x00,0x4E,
                      0,0, 0,0, 0x01,0x05, 0x00,0x40, 0,0, 0,0, 0x00,0x01, 0,0])
        if blk == 0x13:
            return W([0x61,0x13, 0x03,0x93, 0x02,0x4A, 0x02,0xE4, 0x02,0xE4, 0,0, 0x08,0xB7, 0,0,
                      0x02,0x50, 0xFF,0xFC, 0x0B,0xD7, 0x00,0x85, 0x03,0xFD, 0x0B,0xCC])
        if blk == 0x36:
            self.tick()
            w0 = s16raw(int(sim.torque / 520.0))
            w45 = u16clamp(950.0 + sim.pedal * 28.0)
            maf = u16clamp(sim.mafRep * 10)
            bset = u16clamp(sim.boostSet * 1000)
            ped = u16clamp(sim.pedal * 100)
            railR = u16clamp(sim.rail / 0.101)
            w20 = u16clamp(700.0 + sim.mafRep * 1.2)
            trq = s16raw(int(sim.torque))
            return W([0x61,0x36, hi8(w0),lo8(w0), sim.gear & 0xFF, 0x00, hi8(w45),lo8(w45),
                      hi8(maf),lo8(maf), hi8(bset),lo8(bset), 0x03,0x92, hi8(ped),lo8(ped), 0,0, 0x03,0x98,
                      0,0, hi8(w20),lo8(w20), hi8(railR),lo8(railR), 0xFF,0xFF, hi8(maf),lo8(maf), 0x00,0xA2,
                      hi8(trq),lo8(trq), 0x00,0x04, 0x87,0xF0, 0x00,0x01])
        if blk == 0x26:
            self.tick()
            sp = u16clamp(sim.speed * 100.0)
            return W([0x61,0x26, 0,0, hi8(sp),lo8(sp), 0,0, 0x5C,0xB1, 0x7F,0xFF, 0,0, 0x2F,0xA0, 0x00,0x29, 0x00,0x29,
                      0x00,0x29, 0x00,0x29, 0x00,0x48, 0x00,0x23, 0,0, 0x0C,0x77])
        if blk == 0x34:
            return W([0x61,0x34, 0x00,0x48, 0x10,0x00, 0,0, 0x00,0x04, 0,0, 0,0, 0,0, 0,0, 0x03,0xFF,
                      0x00,0x03, 0,0, 0,0, 0x00,0x03, 0,0, 0,0, 0x00,0x04, 0,0])
        if blk == 0x20:
            self.tick()
            m0 = u16clamp(sim.mafRep * 0.72); m1 = u16clamp(600.0 + sim.mafRep * 2.0)
            return W([0x61,0x20, hi8(m0),lo8(m0), hi8(m1),lo8(m1), 0x03,0xFE, 0,0, 0x00,0x94, 0x00,0x48,
                      0x01,0xA8, 0x01,0x63, 0x01,0x08, 0x02,0xE5, 0x02,0x4D, 0x00,0x90, 0x00,0xBF, 0x03,0xA0, 0x01,0xFA])
        return W([0x61, blk] + [0]*16)


# ================================================================ server
class ClientHandler(threading.Thread):
    def __init__(self, sock, addr, args):
        super().__init__(daemon=True)
        self.sock = sock
        self.addr = addr
        self.args = args
        self.emu = Elm327Emu(real_timing=not args.fast, smoke_mode=args.smoke)
        self.emu.airbagEcho = getattr(args, "airbag_echo", False)
        self.t0 = time.monotonic()

    def log(self, direction, text):
        el = int((time.monotonic() - self.t0) * 1000)
        line = "%6d %s %s" % (el, direction, text.replace("\r", " | "))
        if not self.args.quiet:
            print(line, flush=True)
        lf = getattr(self.args, "logf", None)
        if lf:
            lf.write(line + "\n")
            lf.flush()

    def run(self):
        print("*** Client connected: %s:%d ***" % self.addr, flush=True)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        rx = b""
        try:
            while True:
                chunk = self.sock.recv(1024)
                if not chunk:
                    break
                for b in chunk:
                    if b == 0:
                        continue
                    if b in (0x0D, 0x0A):
                        line = "".join(chr(c) for c in rx if c >= 0x20 or c == 0x09).strip()
                        rx = b""
                        if line:
                            self.handle_line(line)
                    else:
                        rx += bytes([b])
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                self.sock.close()
            except OSError:
                pass
            print("*** Client disconnected: %s:%d ***" % self.addr, flush=True)

    def handle_line(self, line):
        emu = self.emu
        self.log("TX >>>", line)
        resp = emu.process_command(line)
        dly = emu.response_delay_ms(line, resp)
        if dly > 0:
            time.sleep(dly / 1000.0)
        self.log("RX <<<", resp)
        up = line.upper()
        if up.startswith("ATZ"):
            frame = b"ATZ\r\xfc\r\r" + resp.encode("latin-1") + b"\r\r>"
        elif up.startswith("ATFI"):
            part1 = (line + "\r") if emu.echo else ""
            part1 += "BUS INIT:\r"
            self.sock.sendall(part1.encode("latin-1"))
            time.sleep(0.55 if emu.realTiming else 0.3)
            frame = b"OK\r\r>"
        elif emu.echo:
            frame = (line + "\r" + resp + "\r\r>").encode("latin-1")
        else:
            frame = (resp + "\r\r>").encode("latin-1")
        self.sock.sendall(frame)


def status_loop(handlers, interval):
    while True:
        time.sleep(interval)
        alive = [h for h in handlers if h.is_alive()]
        handlers[:] = alive
        if not alive:
            continue
        h = alive[-1]
        e = h.emu
        e.tick()
        s = e.sim
        print("[sim] mode=%d t=%4.1fs ph=%-2d %s pedal=%3d%% rpm=%4d boost=%.2f/%.2f maf=%4d fuel=%4.1f A/F=%4.1f rail=%4d spd=%3d gear=%d | proto=%s tgt=0x%02X cmds=%d"
              % (s.mode, s.t, s.phase, "LOAD" if s.loaded else "STAT", s.pedal, e.engineRpm, s.boostAct, s.boostSet,
                 s.mafRep, s.fuel, s.afTrue(), s.rail, s.speed, s.gear,
                 {2: "J1850", 5: "KLINE"}.get(e.protocol, str(e.protocol)), e.targetModule, e.cmdCount), flush=True)


def main():
    ap = argparse.ArgumentParser(description="WJ 2.7 CRD ELM327 simulator (PC port of the ESP32 emulator)")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=35000)
    ap.add_argument("--fast", action="store_true", help="instant responses (no real-car timing)")
    ap.add_argument("--smoke", type=int, default=1, choices=[0, 1, 2, 3], help="smoke fault scenario (default 1)")
    ap.add_argument("--quiet", action="store_true", help="do not print every TX/RX line")
    ap.add_argument("--status", type=float, default=5.0, help="engine status line interval in s (0 = off)")
    ap.add_argument("--logfile", default=None, help="append every TX/RX line to this file (for capturing WJdiag-Pro)")
    ap.add_argument("--airbag-echo", action="store_true", help="answer the airbag module (0x60) with generic positive replies so WJdiag-Pro sends its full sequence")
    args = ap.parse_args()
    args.logf = open(args.logfile, "a", encoding="latin-1") if args.logfile else None

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, args.port))
    srv.listen(4)
    print("============================================")
    print("  WJ 2.7 CRD ELM327 simulator  (ESP32 emulator port)")
    print("  TCP %s:%d   timing=%s   smoke mode=%d" % (args.host, args.port, "instant" if args.fast else "real-car", args.smoke))
    print("  Android emulator -> 10.0.2.2:%d   |   phone -> <this PC IP>:%d" % (args.port, args.port))
    print("  Extra AT: ATSMOKE0-3 (fault scenario), ATSIMDELAY0/1 (timing)")
    print("============================================", flush=True)
    handlers = []
    if args.status > 0:
        threading.Thread(target=status_loop, args=(handlers, args.status), daemon=True).start()
    try:
        while True:
            s, a = srv.accept()
            h = ClientHandler(s, a, args)
            handlers.append(h)
            h.start()
    except KeyboardInterrupt:
        print("bye")


if __name__ == "__main__":
    main()
