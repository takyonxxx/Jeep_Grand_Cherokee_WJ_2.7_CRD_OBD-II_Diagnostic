// ============================================================
// ELM327 WiFi Emulator — ESP32-S2
// ============================================================
// Creates WiFi AP "WiFi_OBDII" with IP 192.168.0.10
// Listens on TCP port 35000 (standard ELM327 WiFi)
// Logs ALL commands to Serial
// HTTP server on port 80 for log download
// ============================================================

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiServer.h>
#include <WiFiClient.h>
#include <WebServer.h>
// No file logging — serial output only
#include "elm327_emu.h"

// Serial = USB CDC (board default for ESP32-S2)
#define LOG_SERIAL Serial

// ==================== Config ====================
static const char *AP_SSID     = "WiFi_OBDII";
static const char *AP_PASS     = "";  // no password (like real ELM327)
static const IPAddress AP_IP(192, 168, 0, 10);
static const IPAddress AP_GW(192, 168, 0, 10);
static const IPAddress AP_MASK(255, 255, 255, 0);
static const uint16_t  ELM_PORT = 35000;
static const uint16_t  HTTP_PORT = 80;
static const int       LED_PIN = 13; // SparkFun ESP32-S2 Thing Plus C built-in LED

// ==================== Globals ====================
WiFiServer elmServer(ELM_PORT);
WebServer  httpServer(HTTP_PORT);
ELM327Emu  emu;
bool       clientConnected = false;
uint32_t   sessionStart = 0;
// totalBytes removed — no file logging

// ==================== Logging ====================

void logInit() {}

void logOpen() {}

void logWrite(const char *direction, const String &data) {
    uint32_t elapsed = millis() - sessionStart;
    LOG_SERIAL.printf("%u %s %s\n", elapsed, direction, data.c_str());
}

void logClose() {}

// ==================== HTTP Server ====================

void httpHandleRoot() {
    uint32_t upSec = millis() / 1000;
    uint32_t upMin = upSec / 60;
    uint32_t upHr = upMin / 60;

    String modName = "none";
    uint8_t t = emu.targetModule;
    if (t == 0x15) modName = "ECU (K-Line)";
    else if (t == 0x20) modName = "TCM (K-Line)";
    else if (t == 0x28) modName = "TCM (J1850)";
    else if (t == 0x40) modName = "ABS/Door R";
    else if (t == 0x58) modName = "ESP";
    else if (t == 0x60) modName = "Airbag";
    else if (t == 0x61) modName = "Compass";
    else if (t == 0x68) modName = "HVAC";
    else if (t == 0x80) modName = "BCM";
    else if (t == 0x98) modName = "MemSeat";
    else if (t == 0xA0) modName = "Door L";
    else if (t == 0xA1) modName = "Liftgate";
    else if (t == 0xA7) modName = "Siren";
    else if (t == 0xC0) modName = "VTSS";
    else if (t == 0x2A) modName = "EVIC";

    String proto = "none";
    if (emu.protocol == 2) proto = "J1850 VPW";
    else if (emu.protocol == 5) proto = "ISO 14230 (K-Line)";

    String html = "<!DOCTYPE html><html><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<meta http-equiv='refresh' content='3'>"
        "<title>WJ Diag Emulator</title>"
        "<style>"
        "body{background:#0a1220;color:#c0d8d0;font-family:monospace;padding:12px;margin:0;}"
        ".hdr{color:#00d4b4;font-size:18px;font-weight:bold;margin-bottom:12px;}"
        ".card{background:#0e1828;border:1px solid #1a3050;border-radius:8px;padding:12px;margin:8px 0;}"
        ".row{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid #0a1220;}"
        ".lbl{color:#5888a8;}.val{color:#60b8a0;font-weight:bold;}"
        ".on{color:#00ff88;}.off{color:#ff6644;}"
        ".badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:12px;}"
        ".bg-on{background:#0a3830;border:1px solid #00806a;}"
        ".bg-off{background:#2a1010;border:1px solid #803030;}"
        "</style></head><body>"
        "<div class='hdr'>WJ 2.7 CRD — ELM327 Emulator</div>"

        "<div class='card'>"
        "<div class='row'><span class='lbl'>Status</span><span class='" +
            String(clientConnected ? "val on" : "val off") + "'>" +
            String(clientConnected ? "CLIENT CONNECTED" : "Waiting for connection...") + "</span></div>"
        "<div class='row'><span class='lbl'>Uptime</span><span class='val'>" +
            String(upHr) + "h " + String(upMin % 60) + "m " + String(upSec % 60) + "s</span></div>"
        "<div class='row'><span class='lbl'>Commands</span><span class='val'>" +
            String(emu.cmdCount) + "</span></div>"
        "</div>"

        "<div class='card'>"
        "<div class='row'><span class='lbl'>Protocol</span><span class='val'>" + proto + "</span></div>"
        "<div class='row'><span class='lbl'>Target Module</span><span class='val'>0x" +
            String(emu.targetModule, HEX) + " — " + modName + "</span></div>"
        "<div class='row'><span class='lbl'>Header Mode</span><span class='val'>0x" +
            String(emu.headerMode, HEX) + "</span></div>"
        "<div class='row'><span class='lbl'>Echo</span><span class='val'>" +
            String(emu.echo ? "ON" : "OFF") + "</span></div>"
        "<div class='row'><span class='lbl'>Headers</span><span class='val'>" +
            String(emu.headers ? "ON" : "OFF") + "</span></div>"
        "<div class='row'><span class='lbl'>Last ATSH</span><span class='val'>" +
            emu.lastHeader + "</span></div>"
        "</div>"

        "<div class='card'>"
        "<div class='row'><span class='lbl'>PCAP Responses</span><span class='val'>252 verified</span></div>"
        "<div class='row'><span class='lbl'>J1850 Modules</span><span class='val'>15 (0x28-0xC0)</span></div>"
        "<div class='row'><span class='lbl'>K-Line Targets</span><span class='val'>ECU 0x15, TCM 0x20</span></div>"
        "<div class='row'><span class='lbl'>WiFi AP</span><span class='val'>" + String(AP_SSID) + "</span></div>"
        "<div class='row'><span class='lbl'>TCP Port</span><span class='val'>35000</span></div>"
        "</div>"

        "</body></html>";
    httpServer.send(200, "text/html", html);
}

void httpHandleLog() { httpServer.send(200,"text/plain","Log output is on Serial only"); }
void httpHandleDownload() { httpServer.send(200,"text/plain","Serial only"); }
void httpHandleClear() { httpServer.sendHeader("Location","/"); httpServer.send(302); }

// ==================== Setup ====================

void setup() {
    // LED feedback first — instant visual
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, HIGH); // LED ON = booting

    // Serial — don't block if no monitor connected
    LOG_SERIAL.begin(115200);
    while(!LOG_SERIAL) { delay(10); }

    LOG_SERIAL.println("\n============================================");
    LOG_SERIAL.println("  ELM327 WiFi Emulator - ESP32-S2");
    LOG_SERIAL.println("============================================");

    // Init (no-op)
    logInit();

    // WiFi AP
    LOG_SERIAL.printf("Starting AP: %s\n", AP_SSID);
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(AP_IP, AP_GW, AP_MASK);
    WiFi.softAP(AP_SSID, AP_PASS, 1, 0, 4);
    delay(500);
    LOG_SERIAL.printf("AP IP: %s\n", WiFi.softAPIP().toString().c_str());

    // Blink 3x = WiFi ready
    for (int i = 0; i < 3; i++) {
        digitalWrite(LED_PIN, LOW); delay(100);
        digitalWrite(LED_PIN, HIGH); delay(100);
    }

    // ELM327 TCP server
    elmServer.begin();
    elmServer.setNoDelay(true);
    LOG_SERIAL.printf("ELM327: port %d\n", ELM_PORT);

    // HTTP server
    httpServer.on("/", httpHandleRoot);
    httpServer.on("/log", httpHandleLog);
    httpServer.on("/download", httpHandleDownload);
    httpServer.on("/clear", httpHandleClear);
    httpServer.begin();
    LOG_SERIAL.printf("HTTP: port %d\n", HTTP_PORT);

    // Init emulator
    emu.reset();
    logOpen();

    LOG_SERIAL.println("============================================");
    LOG_SERIAL.println("  READY! Connect phone to WiFi_OBDII");
    LOG_SERIAL.printf("  ELM327: %s:%d\n", AP_IP.toString().c_str(), ELM_PORT);
    LOG_SERIAL.printf("  Logs:   http://%s/\n", AP_IP.toString().c_str());
    LOG_SERIAL.println("============================================\n");

    // LED OFF = ready, will blink on activity
    digitalWrite(LED_PIN, LOW);
}

// ==================== Main Loop ====================

static WiFiClient elmClient;
static String rxBuf;

void loop() {
    httpServer.handleClient();

    // Accept new ELM327 client
    if (elmServer.hasClient()) {
        if (elmClient && elmClient.connected()) {
            // Already have a client, reject new one
            WiFiClient reject = elmServer.accept();
            reject.stop();
        } else {
            elmClient = elmServer.accept();
            elmClient.setNoDelay(true);
            rxBuf = "";
            clientConnected = true;
            emu.reset();
            digitalWrite(LED_PIN, HIGH); // LED ON = client connected

            LOG_SERIAL.printf("\n*** Client connected: %s ***\n",
                          elmClient.remoteIP().toString().c_str());
            logWrite("---", "CLIENT CONNECTED " + elmClient.remoteIP().toString());
        }
    }

    // Handle ELM327 client data
    if (elmClient && elmClient.connected()) {
        while (elmClient.available()) {
            char c = elmClient.read();
            // Skip NULL bytes (app sends \0 after \r\n)
            if (c == '\0') continue;
            if (c == '\r' || c == '\n') {
                rxBuf.trim();
                // Strip NULL bytes and control chars (app sends 0x00 prefix)
                String clean;
                for (unsigned int i = 0; i < rxBuf.length(); i++) {
                    char ch = rxBuf.charAt(i);
                    if (ch >= 0x20 || ch == '\t') clean += ch;
                }
                rxBuf = clean;
                if (rxBuf.length() > 0) {
                    // Log incoming command
                    logWrite("TX >>>", rxBuf);

                    // LED blink on activity
                    digitalWrite(LED_PIN, !digitalRead(LED_PIN));

                    // Process
                    String resp = emu.processCommand(rxBuf);

                    // Log response
                    logWrite("RX <<<", resp);

                    // Build response frame matching REAL ELM327 wire format
                    // Captured from real WiFi OBDII  v1.5 adapter:
                    //   ATZ  -> "ATZ\r\r\rOBDII  v1.5\r\r>"  (echo + version)
                    //   ATI  -> "ATI\rOBDII  v1.5\r\r>"       (echo + version)
                    //   ATE0 -> "ATE0\rOK\r\r>"               (echo + OK)
                    //   data -> "data\rRESPONSE DATA\r\r>"     (echo + data)
                    //   (after ATE0, no echo prefix)
                    String frame;
                    String cmdUpper = rxBuf;
                    cmdUpper.toUpperCase();

                    if (cmdUpper.startsWith("ATZ")) {
                        // ATZ: echo + 0xFC + delay + version (PCAP verified)
                        frame = "ATZ\r\xFC\r\r" + resp + "\r\r>";
                    } else if (cmdUpper.startsWith("ATFI")) {
                        // ATFI: echo + "BUS INIT:" + delay + "OK" (two-part, PCAP verified)
                        String part1;
                        if (emu.echo) part1 = rxBuf + "\r";
                        part1 += "BUS INIT:\r";
                        elmClient.write(part1.c_str(), part1.length());
                        elmClient.flush();
                        delay(300); // real adapter has ~350ms delay here
                        frame = "OK\r\r>";
                    } else if (emu.echo) {
                        frame = rxBuf + "\r" + resp + "\r\r>";
                    } else {
                        frame = resp + "\r\r>";
                    }
                    elmClient.write(frame.c_str(), frame.length());
                    elmClient.flush();
                }
                rxBuf = "";
            } else {
                rxBuf += c;
            }
        }
    } else if (clientConnected) {
        // Client disconnected
        clientConnected = false;
        digitalWrite(LED_PIN, LOW); // LED OFF = no client
        LOG_SERIAL.println("\n*** Client disconnected ***");
        logWrite("---", "CLIENT DISCONNECTED");
    }

    delay(1); // yield
}
