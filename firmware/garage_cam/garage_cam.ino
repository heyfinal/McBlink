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
 *   Every ~1 s the latest JPEG is decoded to RGB888 (in PSRAM) and downsampled
 *   to a fixed grayscale luma grid, diffed against the previous grid. Operating
 *   on actual luma (not raw JPEG bytes) makes detection spatially meaningful,
 *   and the fixed-size grid avoids per-frame heap allocation. The /status
 *   endpoint exposes the motion flag; ESP32CAMAdapter polls it.
 *   NOTE: the synchronous WebServer pauses motion checks while a client is
 *   actively pulling /stream — fine for McBlink's snapshot+poll usage.
 */

#include "esp_camera.h"
#include "img_converters.h"   // fmt2rgb888 (JPEG -> RGB888)
#include "esp_heap_caps.h"    // heap_caps_malloc (PSRAM)
#include <WiFi.h>
#include <WebServer.h>

// ── CONFIGURE: copy wifi_secrets.h.example -> wifi_secrets.h and fill it in ───
#include "wifi_secrets.h"     // defines WIFI_SSID and WIFI_PASS (gitignored)
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

// Motion detection tuning (grayscale-grid luma diff)
#define MOTION_GRID_W      32     // luma grid columns
#define MOTION_GRID_H      24     // luma grid rows
#define MOTION_GRID_N      (MOTION_GRID_W * MOTION_GRID_H)
#define MOTION_CELL_DELTA  18     // per-cell luma change to count a moved cell
#define MOTION_CELLS       40     // moved cells required to declare motion
#define MOTION_COOLDOWN_MS 3000   // rearm delay after event

WebServer server(80);

static bool     motionFlag   = false;
static uint32_t lastMotionMs = 0;
static bool     flashOn      = false;

// Motion grid state — fixed-size buffers, no per-frame allocation.
static uint8_t  prevGrid[MOTION_GRID_N];
static bool     haveGrid = false;
static uint8_t* rgbBuf   = nullptr;   // RGB888 decode buffer (PSRAM), reused
static int      rgbW = 0, rgbH = 0;

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

// Sample a fixed grayscale grid from an RGB888 frame (center pixel per cell).
static void computeGrid(const uint8_t* rgb, int w, int h, uint8_t* grid) {
    for (int gy = 0; gy < MOTION_GRID_H; gy++) {
        int py = (gy * h) / MOTION_GRID_H + (h / MOTION_GRID_H / 2);
        if (py >= h) py = h - 1;
        for (int gx = 0; gx < MOTION_GRID_W; gx++) {
            int px = (gx * w) / MOTION_GRID_W + (w / MOTION_GRID_W / 2);
            if (px >= w) px = w - 1;
            const uint8_t* p = rgb + ((size_t)py * w + px) * 3;
            grid[gy * MOTION_GRID_W + gx] = (uint8_t)((p[0] + p[1] + p[2]) / 3);
        }
    }
}

static void checkMotion(camera_fb_t* fb) {
    int w = fb->width, h = fb->height;
    // (Re)allocate the RGB888 buffer only when frame dimensions change.
    if (!rgbBuf || rgbW != w || rgbH != h) {
        if (rgbBuf) { free(rgbBuf); rgbBuf = nullptr; }
        rgbBuf = (uint8_t*)heap_caps_malloc((size_t)w * h * 3, MALLOC_CAP_SPIRAM);
        rgbW = w; rgbH = h; haveGrid = false;
        if (!rgbBuf) return;   // no PSRAM — skip motion this frame
    }
    if (!fmt2rgb888(fb->buf, fb->len, PIXFORMAT_JPEG, rgbBuf)) return;

    uint8_t grid[MOTION_GRID_N];
    computeGrid(rgbBuf, w, h, grid);

    if (!haveGrid) { memcpy(prevGrid, grid, MOTION_GRID_N); haveGrid = true; return; }

    int changed = 0;
    for (int i = 0; i < MOTION_GRID_N; i++) {
        if (abs((int)grid[i] - (int)prevGrid[i]) > MOTION_CELL_DELTA) changed++;
    }
    uint32_t now = millis();
    if (changed > MOTION_CELLS && now - lastMotionMs > MOTION_COOLDOWN_MS) {
        motionFlag   = true;
        lastMotionMs = now;
    } else if (now - lastMotionMs > MOTION_COOLDOWN_MS * 3) {
        motionFlag = false;
    }
    memcpy(prevGrid, grid, MOTION_GRID_N);
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
    Serial.print("[wifi] connecting (hidden SSID)");
    uint32_t wifiStart = millis();
    while (WiFi.status() != WL_CONNECTED) {
        delay(500); Serial.print('.');
        if (millis() - wifiStart > 30000) {
            // Status codes: 0=IDLE 1=NO_SSID 3=CONNECTED 4=WRONG_PASS 6=DISCONNECTED
            Serial.printf("\n[wifi] timeout — status=%d — restarting\n", WiFi.status());
            ESP.restart();
        }
    }
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
            checkMotion(fb);
            esp_camera_fb_return(fb);
        }
    }
}
