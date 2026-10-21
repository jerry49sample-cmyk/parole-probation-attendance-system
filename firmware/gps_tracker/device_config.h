/**
 * GPS Tracker Firmware — PPA-TAC secure Edge Function client.
 */

#ifndef DEVICE_CONFIG_H
#define DEVICE_CONFIG_H

// Public project settings. The anon key only identifies the Supabase project;
// device authorization is performed with the per-device token in
// device_secrets.h and the Edge Function.
#define SUPABASE_URL "https://iqltrfkyzbeepfpmsxci.supabase.co"
#define SUPABASE_ANON_KEY "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlxbHRyZmt5emJlZXBmcG1zeGNpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIyMTg1OTUsImV4cCI6MjEwNzc5NDU5NX0.aYfh--wAJP1Fua_VrqgXn5kKIaVE-jnK9ZqqVrBTgIU"

// Adaptive transmission intervals (milliseconds)
#define INTERVAL_MOVING_MS 30000
#define INTERVAL_NORMAL_MS 60000
// Stay comfortably below the Flutter app's two-minute offline threshold.
#define INTERVAL_STATIONARY_MS 60000
#define MAX_GPS_FIX_AGE_MS 10000

#define MOVING_SPEED_KMH 3.0

// Hardware Pin Configuration
#define GPS_RX_PIN 16
#define GPS_TX_PIN 17
#define GSM_RX_PIN 18
#define GSM_TX_PIN 19
#define BATTERY_ADC_PIN 34

#define MAX_QUEUE_SIZE 20

#endif
