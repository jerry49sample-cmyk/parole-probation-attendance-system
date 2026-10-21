/**
 * GPS Tracker — Main firmware
 *
 * Libraries required (Arduino Library Manager):
 *   - TinyGPSPlus by Mikal Hart
 *   - ArduinoJson by Benoit Blanchon
 *
 * For GSM/GPRS instead of Wi-Fi, replace NetworkService with
 * a SIM800L HTTP client using AT commands.
 */

#include <time.h>
#include "device_config.h"
#include "gps_service.h"
#include "battery_service.h"
#include "network_service.h"
#include "api_client.h"

GpsService gps;
BatteryService battery;
NetworkService network;
ApiClient api;

// Offline queue
LocationPayload queue[MAX_QUEUE_SIZE];
int queueHead = 0;
int queueTail = 0;

// Last sent position (avoid duplicate sends)
double lastSentLat = 0;
double lastSentLng = 0;
unsigned long lastSentMs = 0;

unsigned long lastTransmitMs = 0;
unsigned long lastGpsDiagnosticMs = 0;

void enqueue(const LocationPayload& loc) {
  int next = (queueTail + 1) % MAX_QUEUE_SIZE;
  if (next == queueHead) return; // full
  queue[queueTail] = loc;
  queueTail = next;
}

bool dequeue(LocationPayload& loc) {
  if (queueHead == queueTail) return false;
  loc = queue[queueHead];
  queueHead = (queueHead + 1) % MAX_QUEUE_SIZE;
  return true;
}

bool isDuplicate(double lat, double lng) {
  if (millis() - lastSentMs < 30000) {
    if (abs(lat - lastSentLat) < 0.00001 && abs(lng - lastSentLng) < 0.00001) {
      return true;
    }
  }
  return false;
}

bool hasFreshFix(const LocationPayload& loc) {
  return millis() - loc.fixCapturedAtMs <= MAX_GPS_FIX_AGE_MS;
}

unsigned long getInterval(double speedKmh) {
  if (speedKmh > MOVING_SPEED_KMH) return INTERVAL_MOVING_MS;
  if (speedKmh > 0.5) return INTERVAL_NORMAL_MS;
  return INTERVAL_STATIONARY_MS;
}

String isoTimestamp() {
  time_t now = time(nullptr);
  if (now < 1700000000) {
    return "";
  }
  struct tm timeinfo;
  gmtime_r(&now, &timeinfo);
  char buf[32];
  strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &timeinfo);
  return String(buf);
}

bool transmit(LocationPayload loc) {
  if (!hasFreshFix(loc)) {
    Serial.println("[GPS] Skipping stale fix");
    return false;
  }
  if (isDuplicate(loc.latitude, loc.longitude)) return true;

  if (!network.isConnected()) {
    enqueue(loc);
    return false;
  }

  if (api.sendLocation(loc)) {
    lastSentLat = loc.latitude;
    lastSentLng = loc.longitude;
    lastSentMs = millis();
    return true;
  }

  enqueue(loc);
  return false;
}

bool sendQueuedLocation(const LocationPayload& loc) {
  if (!network.isConnected() || !api.sendLocation(loc)) return false;
  lastSentLat = loc.latitude;
  lastSentLng = loc.longitude;
  lastSentMs = millis();
  return true;
}

void flushQueue() {
  LocationPayload loc;
  while (dequeue(loc)) {
    if (!hasFreshFix(loc)) {
      Serial.println("[GPS] Dropping stale queued fix");
      continue;
    }
    if (isDuplicate(loc.latitude, loc.longitude)) {
      continue;
    }
    if (!sendQueuedLocation(loc)) {
      enqueue(loc); // put back if failed
      break;
    }
    delay(200); // rate limit
  }
}

void setup() {
  Serial.begin(115200);
  if (
      DEVICE_ID[0] == '\0' ||
      DEVICE_TOKEN[0] == '\0' ||
      DEVICE_WIFI_SSID[0] == '\0' ||
      DEVICE_WIFI_PASSWORD[0] == '\0' ||
      String(DEVICE_ID).startsWith("SET_") ||
      String(DEVICE_TOKEN).startsWith("SET_")) {
    Serial.println("Configure firmware/gps_tracker/device_secrets.h first.");
    while (true) delay(1000);
  }

  gps.begin(GPS_RX_PIN, GPS_TX_PIN);
  battery.begin(BATTERY_ADC_PIN);
  network.begin(DEVICE_WIFI_SSID, DEVICE_WIFI_PASSWORD);
  Serial.println("GPS Tracker initialized");
}

void loop() {
  network.reconnect(DEVICE_WIFI_SSID, DEVICE_WIFI_PASSWORD);

  const bool hasFreshFix = gps.update() && gps.hasValidFix();
  if (!hasFreshFix && millis() - lastGpsDiagnosticMs >= 15000) {
    Serial.println(
        "[GPS] No fresh GPS fix; no location upload will be sent yet.");
    lastGpsDiagnosticMs = millis();
  }

  if (hasFreshFix) {
    auto fix = gps.getFix();
    unsigned long interval = getInterval(fix.speedKmh);

    if (millis() - lastTransmitMs >= interval) {
      LocationPayload payload;
      payload.latitude = fix.latitude;
      payload.longitude = fix.longitude;
      payload.accuracy = fix.accuracy;
      payload.speed = fix.speedKmh;
      payload.batteryLevel = battery.readPercent();
      payload.timestamp = isoTimestamp();
      payload.fixCapturedAtMs = fix.capturedAtMs;

      transmit(payload);
      lastTransmitMs = millis();
    }
  }

  flushQueue();
  delay(1000);
}
