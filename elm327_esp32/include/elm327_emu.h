#pragma once
#include <Arduino.h>

// ELM327 Emulator for WJ 2.7 CRD — PCAP-verified responses
// WiFi AP: 192.168.0.10:35000
// Response database: 252 real vehicle captures (2026-03-12)

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

private:
    String handleAT(const String &cmd);

    // J1850 — PCAP lookup + generic fallback
    String j1850_pcap_lookup(uint8_t t, uint8_t m, const String &cmdStr);
    String j1850_generic(uint8_t t, uint8_t m, uint8_t sid, const uint8_t *data, int dlen);

    // KWP2000 (K-Line)
    String kwpProcess(uint8_t sid, const uint8_t *data, int dlen);
    String kwpWrap(const uint8_t *payload, int plen);

    uint8_t  klTarget     = 0x20;
    bool     ecuUnlocked  = false;
    bool     ecuDtcCleared = false;
    bool     tcmUnlocked  = false;
    uint16_t ecuSeed      = 0;

    // Per-module J1850 DTC cleared flags
    bool j1850DtcCleared[256] = {};

    float  engineRpm    = 750.0f;
    float  coolantTemp  = 82.0f;
    float  transTemp    = 77.0f;
    uint8_t gearSel     = 8;
    void tick();
    uint32_t _t0 = 0;
};
