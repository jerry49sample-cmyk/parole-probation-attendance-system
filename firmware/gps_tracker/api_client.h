#ifndef API_CLIENT_H
#define API_CLIENT_H

#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <ArduinoJson.h>
#include "device_config.h"
#if __has_include("device_secrets.h")
#include "device_secrets.h"
#else
#include "device_secrets.example.h"
#endif
#include "tls_root_ca.h"

struct LocationPayload {
  double latitude;
  double longitude;
  double accuracy;
  double speed;
  int batteryLevel;
  String timestamp;
  unsigned long fixCapturedAtMs;
};

class ApiClient {
public:
  bool sendLocation(const LocationPayload& loc) {
    WiFiClientSecure client;
    client.setCACert(SUPABASE_ROOT_CA);

    HTTPClient http;
    String endpoint = String(SUPABASE_URL) + "/functions/v1/esp32-location";

    if (!http.begin(client, endpoint)) {
      Serial.println("[HTTP] Failed to connect to the GPS upload endpoint");
      return false;
    }

    http.setConnectTimeout(10000);
    http.setTimeout(10000);
    http.addHeader("Content-Type", "application/json");
    // Supabase's public project key is not device authentication. The
    // Edge Function separately validates this tracker's private token.
    http.addHeader("apikey", SUPABASE_ANON_KEY);
    http.addHeader("X-Device-Token", DEVICE_TOKEN);

    StaticJsonDocument<256> doc;
    doc["device_id"] = DEVICE_ID;
    doc["latitude"] = loc.latitude;
    doc["longitude"] = loc.longitude;
    doc["accuracy"] = loc.accuracy;
    doc["speed"] = loc.speed;
    doc["battery_level"] = loc.batteryLevel;

    String requestBody;
    serializeJson(doc, requestBody);

    int httpResponseCode = http.POST(requestBody);

    if (httpResponseCode >= 200 && httpResponseCode < 300) {
      Serial.printf("[GPS upload] Accepted (HTTP %d)\n", httpResponseCode);
      http.end();
      return true;
    } else {
      Serial.printf("[GPS upload] Rejected (HTTP %d)\n", httpResponseCode);
      // The Edge Function returns a short error code without credentials.
      // Printing it makes setup failures diagnosable from Serial Monitor.
      String responseBody = http.getString();
      if (responseBody.length() > 0) {
        Serial.printf("[GPS upload] Server response: %s\n", responseBody.c_str());
      }
      http.end();
      return false;
    }
  }
};

#endif
