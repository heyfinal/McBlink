/*
 * garage_cam.ino — McBlink ESP32-CAM garage door camera firmware
 * Target : AI-Thinker ESP32-CAM (OV2640 sensor, M12 wide-angle lens upgrade)
 *
 * Endpoints
 *   GET /stream                       — MJPEG multipart stream (McBlink MJPEGAdapter compatible)
 *   GET /capture                      — Single JPEG snapshot
 *   GET /status                       — JSON: ip, rssi, flash, motion, uptime
 *   GET /control?var=VAR&val=VAL      — Control flash, framesize, quality, hmirror, vflip, etc.
 *
 * Setup
 *   1. Install ESP32 board package in Arduino IDE 2.x
 *      (Boards Manager URL: https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json)
 *   2. Board: AI Thinker ESP32-CAM
 *   3. Upload via ESP32-CAM-MB (plug in micro-USB, hold IO0 button while powering)
 *   4. Set WIFI_SSID / WIFI_PASS below, flash, open Serial Monitor at 115200
 *
 * Motion detection
 *   Runs a JPEG byte-diff comparison every 1 second. Works well for garage
 *   driveway lighting changes and person/vehicle entry. The /status endpoint
 *   exposes the current motion flag; McBlink's ESP32CAMAdapter polls it.
 */

#include "esp_camera.h"
#include <WiFi.h>
#include <WebServer.h>

// ── CONFIGURE THESE ──────────────────────────────────────────────────────────
#define WIFI_SSID    "YOUR_SSID"
#define WIFI_PASS    "YOUR_WIFI_PASS"
#define DEVICE_NAME  "garage-cam"
// ─────────────────────────────────────────────────────────────────────────────

// AI-Thinker ESP32-CAM GPIO map
#define PWDN_GPIO_NUM   32
#define RESET_GPIO_NUM  -1
#define XCLK_GPIO_NUM    0
#define SIOD_GPIO_NUM   26
#define SIOC_GPIO_NUM   27
#define Y9_GPIO_NUM     35
#define Y8_GPIO_NUM     34
#define Y7_GPIO_NUM     39
#define Y6_GPIO_NUM     36
#define Y5_GPIO_NUM     21
#define Y4_GPIO_NUM     19
#define Y3_GPIO_NUM     18
#define Y2_GPIO_NUM      5
#define VSYNC_GPIO_NUM  25
#define HREF_GPIO_NUM   23
#define PCLK_GPIO_NUM   22
#define FLASH_GPIO       4

// Motion detection tuning
#define MOTION_SAMPLE_STEP  32    // compare every Nth byte (lower = more CPU)
#define MOTION_THRESHOLD    22    // per-byte diff to count as changed
#define MOTION_MIN_HITS    180    // minimum hits to declare motion
#define MOTION_COOLDOWN_MS 3000   // rearm delay after event

WebServer server(80);

static uint8_t* prevBuf    = nullptr;
static size_t   prevLen    = 0;
static bool     motionFlag = false;
static uint32_t lastMotionMs = 0;
static bool     flashOn    = false;

// ─── Camera init ─────────────────────────────────────────────────────────────

static bool initCamera() {
    camera_config_t cfg = {};
    cfg.ledc_channel = LEDC_CHANNEL_0;
    cfg.ledc_timer   = LEDC_TIMER_0;
    cfg.pin_d0 = Y2_GPIO_NUM;  cfg.pin_d1 = Y3_GPIO_NUM;
    cfg.pin_d2 = Y4_GPIO_NUM;  cfg.pin_d3 = Y5_GPIO_NUM;
    cfg.pin_d4 = Y6_GPIO_NUM;  cfg.pin_d5 = Y7_GPIO_NUM;
    cfg.pin_d6 = Y8_GPIO_NUM;  cfg.pin_d7 = Y9_GPIO_NUM;
    cfg.pin_xclk     = XCLK_GPIO_NUM;
    cfg.pin_pclk     = PCLK_GPIO_NUM;
    cfg.pin_vsync    = VSYNC_GPIO_NUM;
    cfg.pin_href     = HREF_GPIO_NUM;
    cfg.pin_sscb_sda = SIOD_GPIO_NUM;
    cfg.pin_sscb_scl = SIOC_GPIO_NUM;
    cfg.pin_pwdn     = PWDN_GPIO_NUM;
    cfg.pin_reset    = RESET_GPIO_NUM;
    cfg.xclk_freq_hz = 20000000;
    cfg.pixel_format = PIXFORMAT_JPEG;
    cfg.frame_size   = FRAMESIZE_SVGA;   // 800×600 default; change via /control
    cfg.jpeg_quality = 12;               // 0 = best, 63 = worst
    cfg.fb_count     = 2;
    cfg.grab_mode    = CAMERA_GRAB_LATEST;
    return esp_camera_init(&cfg) == ESP_OK;
}

// ─── Flash ───────────────────────────────────────────────────────────────────

static void setFlash(bool on) {
    flashOn = on;
    digitalWrite(FLASH_GPIO, on ? HIGH : LOW);
}

// ─── Motion detection ────────────────────────────────────────────────────────

static void checkMotion(const uint8_t* buf, size_t len) {
    if (prevLen == 0) {
        prevBuf = (uint8_t*)malloc(len);
        if (prevBuf) { memcpy(prevBuf, buf, len); prevLen = len; }
        return;
    }
    size_t cmpLen = min(len, prevLen);
    int hits = 0;
    for (size_t i = 0; i < cmpLen; i += MOTION_SAMPLE_STEP) {
        if (abs((int)buf[i] - (int)prevBuf[i]) > MOTION_THRESHOLD) hits++;
    }
    uint32_t now = millis();
    if (hits > MOTION_MIN_HITS && now - lastMotionMs > MOTION_COOLDOWN_MS) {
        motionFlag  = true;
        lastMotionMs = now;
    } else if (now - lastMotionMs > MOTION_COOLDOWN_MS * 3) {
        motionFlag = false;
    }
    if (prevLen != len) {
        free(prevBuf);
        prevBuf = (uint8_t*)malloc(len);
        if (!prevBuf) { prevLen = 0; return; }
    }
    memcpy(prevBuf, buf, len);
    prevLen = len;
}

// ─── HTTP handlers ───────────────────────────────────────────────────────────

static void handleStream() {
    WiFiClient client = server.client();
    client.print(
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
        "Cache-Control: no-cache\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Connection: keep-alive\r\n\r\n"
    );
    while (client.connected()) {
        camera_fb_t* fb = esp_camera_fb_get();
        if (!fb) { delay(30); continue; }
        client.printf(
            "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n",
            fb->len
        );
        client.write(fb->buf, fb->len);
        client.print("\r\n");
        esp_camera_fb_return(fb);
        delay(40);  // ~25 fps ceiling
    }
}

static void handleCapture() {
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb) { server.send(503, "text/plain", "camera busy"); return; }
    server.sendHeader("Content-Disposition", "inline; filename=snapshot.jpg");
    server.sendHeader("Access-Control-Allow-Origin", "*");
    server.send_P(200, "image/jpeg", (const char*)fb->buf, fb->len);
    esp_camera_fb_return(fb);
}

static void handleStatus() {
    char json[256];
    snprintf(json, sizeof(json),
        "{\"device\":\"%s\",\"ip\":\"%s\",\"rssi\":%d,"
        "\"flash\":%s,\"motion\":%s,\"uptime\":%lu}",
        DEVICE_NAME,
        WiFi.localIP().toString().c_str(),
        WiFi.RSSI(),
        flashOn    ? "true" : "false",
        motionFlag ? "true" : "false",
        millis() / 1000UL
    );
    server.sendHeader("Access-Control-Allow-Origin", "*");
    server.send(200, "application/json", json);
}

static void handleControl() {
    if (!server.hasArg("var") || !server.hasArg("val")) {
        server.send(400, "text/plain", "missing var or val");
        return;
    }
    String var = server.arg("var");
    int    val = server.arg("val").toInt();
    sensor_t* s = esp_camera_sensor_get();

    if      (var == "flash"      )             setFlash(val != 0);
    else if (var == "framesize"  && s) s->set_framesize(s,   (framesize_t)val);
    else if (var == "quality"    && s) s->set_quality(s,     val);
    else if (var == "brightness" && s) s->set_brightness(s,  val);
    else if (var == "contrast"   && s) s->set_contrast(s,    val);
    else if (var == "saturation" && s) s->set_saturation(s,  val);
    else if (var == "hmirror"    && s) s->set_hmirror(s,     val);
    else if (var == "vflip"      && s) s->set_vflip(s,       val);
    else if (var == "aec2"       && s) s->set_aec2(s,        val);
    else if (var == "awb"        && s) s->set_whitebal(s,    val);

    server.send(200, "text/plain", "ok");
}

// ─── Setup / Loop ─────────────────────────────────────────────────────────────

void setup() {
    Serial.begin(115200);
    pinMode(FLASH_GPIO, OUTPUT);
    setFlash(false);

    Serial.print("[cam] init... ");
    if (!initCamera()) {
        Serial.println("FAILED — restarting in 3s");
        delay(3000);
        ESP.restart();
    }
    Serial.println("OK");

    WiFi.mode(WIFI_STA);
    WiFi.setHostname(DEVICE_NAME);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    Serial.print("[wifi] connecting");
    while (WiFi.status() != WL_CONNECTED) { delay(300); Serial.print('.'); }
    Serial.println();
    Serial.printf("[wifi] IP: %s  RSSI: %d dBm\n",
        WiFi.localIP().toString().c_str(), WiFi.RSSI());
    Serial.printf("[http] http://%s/stream\n",   WiFi.localIP().toString().c_str());
    Serial.printf("[http] http://%s/capture\n",  WiFi.localIP().toString().c_str());
    Serial.printf("[http] http://%s/status\n",   WiFi.localIP().toString().c_str());

    server.on("/stream",  HTTP_GET, handleStream);
    server.on("/capture", HTTP_GET, handleCapture);
    server.on("/status",  HTTP_GET, handleStatus);
    server.on("/control", HTTP_GET, handleControl);
    server.begin();
    Serial.println("[http] server started");
}

void loop() {
    server.handleClient();

    static uint32_t lastCheck = 0;
    if (millis() - lastCheck > 1000) {
        lastCheck = millis();
        camera_fb_t* fb = esp_camera_fb_get();
        if (fb) {
            checkMotion(fb->buf, fb->len);
            esp_camera_fb_return(fb);
        }
    }
}
