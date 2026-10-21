class Geofence {
  const Geofence({
    required this.id,
    required this.paroleeId,
    required this.name,
    required this.centerLat,
    required this.centerLng,
    required this.radiusMeters,
    this.isActive = true,
  });

  final String id;
  final String paroleeId;
  final String name;
  final double centerLat;
  final double centerLng;
  final double radiusMeters;
  final bool isActive;

  /// Check-in points supply coordinates for the 50 m proximity geofence.
  /// They are not a monitoring zone — leaving them must not count as a
  /// geofence violation or as absence.
  bool get isCheckInPoint {
    final n = name.toLowerCase();
    return n.contains('check-in') || n.contains('check in');
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'parolee_id': paroleeId,
    'name': name,
    'latitude': centerLat,
    'longitude': centerLng,
    'radius_meters': radiusMeters,
  };

  factory Geofence.fromMap(Map<String, dynamic> map) {
    return Geofence(
      id: map['id'] as String? ?? '',
      paroleeId:
          map['parolee_id']?.toString() ?? map['paroleeId']?.toString() ?? '',
      name: map['name'] as String? ?? 'Monitoring Area',
      centerLat:
          ((map['latitude'] ?? map['center_lat'] ?? map['centerLat']) as num?)
                  ?.toDouble() ??
              0,
      centerLng:
          ((map['longitude'] ?? map['center_lng'] ?? map['centerLng']) as num?)
                  ?.toDouble() ??
              0,
      radiusMeters:
          ((map['radius_meters'] ?? map['radiusMeters']) as num?)?.toDouble() ??
          500,
      isActive: map['is_active'] as bool? ?? map['isActive'] as bool? ?? true,
    );
  }
}

enum GeofenceStatus {
  inside,
  outside,
  noGeofence,
  unknown;

  String get label => switch (this) {
    GeofenceStatus.inside => 'INSIDE ASSIGNED AREA',
    GeofenceStatus.outside => 'OUTSIDE ASSIGNED AREA',
    GeofenceStatus.noGeofence => 'NO GEOFENCE CONFIGURED',
    GeofenceStatus.unknown => 'UNKNOWN',
  };
}
