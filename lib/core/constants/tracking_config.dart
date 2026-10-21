class TrackingConfig {
  /// No location received within this window → OFFLINE (configurable).
  static const Duration offlineTimeout = Duration(minutes: 2);

  /// Battery below this percentage → LOW_BATTERY.
  static const int lowBatteryThreshold = 20;

  /// Officer client refresh interval for live tracking updates.
  static const Duration refreshInterval = Duration(seconds: 10);

  /// Max records per location history page.
  static const int locationHistoryPageSize = 50;

  /// Default geofence radius for new zones (meters).
  static const double defaultGeofenceRadiusMeters = 500;

  /// Officer proximity alert radius around the assigned check-in location.
  /// Notify only when a valid reading is at or inside this distance.
  static const double checkInProximityRadiusMeters = 50;

  /// Maximum horizontal GPS accuracy (meters) accepted for proximity alerts.
  static const double maxGpsAccuracyMeters = 30;

  /// Maximum age of a GPS reading before it is treated as stale.
  static const Duration maxGpsAgeForProximity = Duration(minutes: 2);

  /// Alert deduplication cooldown.
  static const int alertCooldownMinutes = 60;

  /// Reject duplicate GPS within this window.
  static const Duration duplicateLocationWindow = Duration(seconds: 30);

  /// Historical GPS retention (days) — configure per deployment.
  static const int locationRetentionDays = 90;

  /// Default center for a new geofence near the PPA Tacloban field office.
  static const double defaultGeofenceLatitude = 11.240800;
  static const double defaultGeofenceLongitude = 125.003900;
}
