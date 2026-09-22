#pragma once
#include <Arduino.h>

// ELM327 Emulator for WJ 2.7 CRD — verified real vehicle responses
// WiFi AP: 192.168.0.10:35000
// Response database: 252 real vehicle captures (2026-03-12)

// Engine transient model used by the ECU live-data blocks so the iOS
// "Smoke Test" (black smoke on sudden throttle) has coherent, dynamic
// data to record: pedal -> RPM -> boost setpoint -> (lagging) boost ->
// MAF -> smoke limiter -> fuel -> rail / IAT.
// A scripted 40 s drive cycle repeats forever:
//   idle, light cruise, full-throttle pull to 4000 rpm, lift, idle,
//   second pull, two stationary throttle blips.
// Fault scenario selected with AT command "ATSMOKEn" (n = 0..3):
//   0 = healthy: boost reaches target quickly, A/F stays > 18
//   1 = VNT sticking / long turbo lag + transient over-fuelling (A/F < 15)  [default]
//   2 = MAF over-reading 30%: limiter allows too much fuel, MAF > theoretical air
//   3 = injector excess: fuel above limiter, large cylinder corrections
struct SmokeSim {
    int      mode      = 1;
    uint32_t lastMs    = 0;
    float    t         = 0;      // seconds into the current 40 s cycle
    int      phase     = 0;      // scripted phase index (for HTTP page)
    bool     loaded    = false;  // true = in gear on the road, false = stationary
    float    pedal     = 0;      // %
    float    pedalStepAt = -10;  // cycle time of last pedal step > 50%
    float    rpmTarget = 750;
    float    boostSet  = 0.93f;  // bar abs
    float    boostAct  = 0.93f;  // bar abs
    float    mafTrue   = 480;    // mg/str actually entering the engine
    float    mafRep    = 480;    // mg/str reported by the MAF sensor
    float    driver    = 0;      // driver-wish fuel mg/str
    float    limiter   = 30;     // smoke limiter fuel cap mg/str
    float    fuel      = 8.8f;   // injected mg/str
    float    rail      = 291;    // bar
    float    iat       = 30;     // C
    float    speed     = 0;      // km/h
    float    corr[3]   = {-1.42f, 0.54f, 0.47f};
    float    afTrue() const { return fuel > 0.5f ? mafTrue / fuel : 0; }
};

class ELM327Emu {
public:
    void reset();
    String processCommand(const String &cmd);

    uint8_t targetModule = 0x20;
    uint8_t headerMode   = 0x22;
    uint8_t protocol     = 0;
    bool    headers      = false;
    bool    echo         = true;
    String  lastHeader;
    uint32_t cmdCount    = 0;

    SmokeSim sim;                // public so main.cpp can show it on the HTTP page
    float  engineRpm    = 750.0f;
    float  coolantTemp  = 82.0f;
    void tick();                 // advances the engine model (safe to call often)

private:
    String handleAT(const String &cmd);

    // J1850 — vehicle data lookup + generic fallback
    String j1850_vehicle_lookup(uint8_t t, uint8_t m, const String &cmdStr);
    String j1850_generic(uint8_t t, uint8_t m, uint8_t sid, const uint8_t *data, int dlen);

    // KWP2000 (K-Line)
    String kwpProcess(uint8_t sid, const uint8_t *data, int dlen);
    String kwpWrap(const uint8_t *payload, int plen);

    void simUpdate(float dt);

    uint8_t  klTarget     = 0x20;
    bool     ecuUnlocked  = false;
    bool     ecuDtcCleared = false;
    bool     tcmUnlocked  = false;
    uint16_t ecuSeed      = 0;
    int      ecuSeedZeroCount = 0;  // track seed=0 requests
    bool     klBusInitDone = false; // first 81 includes BUS INIT

    // Per-module J1850 DTC cleared flags
    bool j1850DtcCleared[256] = {};
    int espClearAttempts = 0;
    int j1850NoiseCounter = 0;  // bus noise injection counter

    float  transTemp    = 77.0f;
    uint8_t gearSel     = 8;
    int tcmReadCount    = 0;
    uint32_t _t0 = 0;
};
