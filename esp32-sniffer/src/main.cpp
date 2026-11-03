/*
 * ESP32-S3 WiFi sniffer for the WiFi ELM327 (open network "WiFi_OBDII").
 *
 * WJdiag-Pro only talks to 192.168.0.10:35000 and offers no address setting, so a
 * man-in-the-middle is impossible. The ELM's network is open (no encryption), so a
 * third radio on the same channel sees every frame in the clear. This firmware
 * puts the ESP32 in promiscuous mode on the ELM's channel and streams the TCP
 * payloads of port 35000 over the serial port as text lines:
 *
 *   I <channel> <bssid>                 found the AP, listening
 *   P <ms> <src ip>:<port> <dst ip>:<port> <hex payload>
 *   S <frames seen> <ip frames> <elm frames>     (every 5 s)
 *
 * tools/esp32_sniff.py turns the P lines into a pcap + text log on the PC.
 * Serial commands: "ssid <name>" (default WiFi_OBDII), "port <n>", "chan <n>"
 * (fixed channel when the AP scan does not find the SSID).
 *
 * Flash:  pio run -d esp32-sniffer -t upload     (re-flash esp32-emulator afterwards
 *         to turn the board back into the ELM emulator).
 */
#include <Arduino.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include "soc/rtc_cntl_reg.h"
#include "soc/soc.h"

static String   g_ssid = "WiFi_OBDII";
static uint16_t g_port = 35000;
static int      g_chan = 0;            // 0 = find via scan
static uint8_t  g_bssid[6] = {0};
static bool     g_haveBssid = false;

static volatile uint32_t g_frames = 0, g_ipFrames = 0, g_elmFrames = 0;

// Ring of text lines produced in the promiscuous callback (runs in the WiFi task) and
// printed from loop(); keeps Serial writes out of the callback.
static const int   RING = 64;
static String      g_ring[RING];
static volatile int g_head = 0, g_tail = 0;
static portMUX_TYPE g_mux = portMUX_INITIALIZER_UNLOCKED;

static void out(const String& s)
{
    Serial.println(s);
#if ARDUINO_USB_CDC_ON_BOOT
    Serial0.println(s);
#endif
}

static void push(const String& s)
{
    portENTER_CRITICAL(&g_mux);
    int n = (g_head + 1) % RING;
    if (n != g_tail) { g_ring[g_head] = s; g_head = n; }
    portEXIT_CRITICAL(&g_mux);
}

static String ip4(const uint8_t* p)
{
    return String(p[0]) + "." + String(p[1]) + "." + String(p[2]) + "." + String(p[3]);
}

static void sniff(void* buf, wifi_promiscuous_pkt_type_t type)
{
    if (type != WIFI_PKT_DATA) return;
    g_frames++;
    const wifi_promiscuous_pkt_t* pkt = (const wifi_promiscuous_pkt_t*)buf;
    const uint8_t* f = pkt->payload;
    int len = pkt->rx_ctrl.sig_len;
    if (len < 28) return;

    const uint16_t fc = f[0] | (f[1] << 8);
    if (((fc >> 2) & 3) != 2) return;             // not a data frame
    if (fc & 0x4000) return;                      // protected (encrypted) -> cannot read
    const uint8_t subtype = (fc >> 4) & 0xF;
    if (subtype & 0x4) return;                    // null / no-data subtypes
    const bool toDs = fc & 0x0100, fromDs = fc & 0x0200;
    const uint8_t* bssid = toDs ? f + 4 : (fromDs ? f + 10 : f + 16);
    if (g_haveBssid && memcmp(bssid, g_bssid, 6) != 0) return;

    int hdr = 24;
    if (subtype & 0x8) hdr += 2;                  // QoS data
    if (fc & 0x8000) hdr += 4;                    // HT control (order bit)
    if (len < hdr + 8 + 20 + 20) return;
    const uint8_t* llc = f + hdr;
    if (!(llc[0] == 0xAA && llc[1] == 0xAA && llc[2] == 0x03)) return;
    if (!(llc[6] == 0x08 && llc[7] == 0x00)) return;   // IPv4 only
    const uint8_t* ip = llc + 8;
    if ((ip[0] >> 4) != 4) return;
    g_ipFrames++;
    if (ip[9] != 6) return;                       // TCP
    const int ihl = (ip[0] & 0xF) * 4;
    const int ipLen = (ip[2] << 8) | ip[3];
    const uint8_t* tcp = ip + ihl;
    const int thl = (tcp[12] >> 4) * 4;
    const uint16_t sport = (tcp[0] << 8) | tcp[1], dport = (tcp[2] << 8) | tcp[3];
    if (sport != g_port && dport != g_port) return;
    int plen = ipLen - ihl - thl;
    const uint8_t* pay = tcp + thl;
    const int avail = len - (int)(pay - f) - 4;   // minus FCS
    if (plen > avail) plen = avail;
    if (plen <= 0) return;
    g_elmFrames++;

    String s; s.reserve(64 + plen * 3);
    s += "P "; s += String(millis()); s += ' ';
    s += ip4(ip + 12); s += ':'; s += String(sport); s += ' ';
    s += ip4(ip + 16); s += ':'; s += String(dport); s += ' ';
    static const char* hx = "0123456789ABCDEF";
    for (int i = 0; i < plen; i++) { s += hx[pay[i] >> 4]; s += hx[pay[i] & 0xF]; }
    push(s);
}

static bool findAp()
{
    out("scanning for \"" + g_ssid + "\" (passive)...");
    // Passive scan: listen for beacons only, no probe requests -> no TX current spikes.
    int n = WiFi.scanNetworks(false, true, true, 400);
    for (int i = 0; i < n; i++) {
        if (WiFi.SSID(i) == g_ssid) {
            g_chan = WiFi.channel(i);
            memcpy(g_bssid, WiFi.BSSID(i), 6);
            g_haveBssid = true;
            char b[24];
            snprintf(b, sizeof b, "%02X:%02X:%02X:%02X:%02X:%02X", g_bssid[0], g_bssid[1], g_bssid[2], g_bssid[3], g_bssid[4], g_bssid[5]);
            out("I " + String(g_chan) + " " + String(b) + " rssi=" + String(WiFi.RSSI(i)) + " enc=" + String((int)WiFi.encryptionType(i)));
            WiFi.scanDelete();
            return true;
        }
    }
    out("AP not found (" + String(n) + " networks seen); use 'chan <n>' to listen on a fixed channel");
    for (int i = 0; i < n && i < 15; i++)
        out("  " + WiFi.SSID(i) + " ch" + String(WiFi.channel(i)) + " " + String(WiFi.RSSI(i)) + " dBm enc=" + String((int)WiFi.encryptionType(i)));
    WiFi.scanDelete();
    return false;
}

static void startSniff()
{
    esp_wifi_set_promiscuous(false);
    wifi_promiscuous_filter_t filt = { .filter_mask = WIFI_PROMIS_FILTER_MASK_DATA };
    esp_wifi_set_promiscuous_filter(&filt);
    esp_wifi_set_promiscuous_rx_cb(&sniff);
    esp_wifi_set_channel(g_chan, WIFI_SECOND_CHAN_NONE);
    esp_wifi_set_promiscuous(true);
    out("listening on channel " + String(g_chan) + (g_haveBssid ? " (AP only)" : " (all APs)") + ", port " + String(g_port));
}

void setup()
{
    Serial.begin(115200);
#if ARDUINO_USB_CDC_ON_BOOT
    Serial0.begin(115200);
#endif
    delay(1500);
    out("ESP32 ELM327 WiFi sniffer (low-power build)");
    // Head-unit USB ports sag when the radio starts (BROWNOUT_RST loop seen on the T527):
    // run the CPU slower, keep the radio at minimum TX power (we only listen) and bring
    // the WiFi stack up step by step. The brownout detector is switched off last so a
    // short dip does not restart the board mid-capture.
    setCpuFrequencyMhz(80);
    WiFi.persistent(false);
    WiFi.mode(WIFI_STA);
    delay(300);
    WiFi.setTxPower(WIFI_POWER_2dBm);
    esp_wifi_set_ps(WIFI_PS_NONE);
    WiFi.disconnect();
    delay(500);
    WRITE_PERI_REG(RTC_CNTL_BROWN_OUT_REG, 0);
    out("cpu 80 MHz, tx 2 dBm, brownout detector off");
    if (!findAp()) g_chan = 1;
    startSniff();
}

static void handleCmd(String c)
{
    c.trim();
    if (c.startsWith("ssid ")) { g_ssid = c.substring(5); g_haveBssid = false; esp_wifi_set_promiscuous(false); if (findAp()) startSniff(); }
    else if (c.startsWith("port ")) { g_port = c.substring(5).toInt(); out("port " + String(g_port)); }
    else if (c.startsWith("chan ")) { g_chan = c.substring(5).toInt(); g_haveBssid = false; startSniff(); }
    else if (c == "scan") { esp_wifi_set_promiscuous(false); if (findAp()) startSniff(); else startSniff(); }
    else if (c.length()) out("commands: ssid <name> | port <n> | chan <n> | scan");
}

void loop()
{
    static String cmd;
    while (Serial.available()) { char ch = Serial.read(); if (ch == '\n' || ch == '\r') { handleCmd(cmd); cmd = ""; } else cmd += ch; }
#if ARDUINO_USB_CDC_ON_BOOT
    while (Serial0.available()) { char ch = Serial0.read(); if (ch == '\n' || ch == '\r') { handleCmd(cmd); cmd = ""; } else cmd += ch; }
#endif
    while (g_tail != g_head) {
        String s;
        portENTER_CRITICAL(&g_mux);
        s = g_ring[g_tail]; g_tail = (g_tail + 1) % RING;
        portEXIT_CRITICAL(&g_mux);
        out(s);
    }
    static uint32_t last = 0;
    if (millis() - last > 5000) {
        last = millis();
        out("S " + String(g_frames) + " " + String(g_ipFrames) + " " + String(g_elmFrames));
    }
    delay(2);
}
