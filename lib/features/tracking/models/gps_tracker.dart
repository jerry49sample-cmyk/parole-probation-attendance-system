enum TrackerDeviceStatus {
  active,
  inactive,
  offline,
  maintenance,
  unassigned;

  static TrackerDeviceStatus fromString(String? value) {
    return TrackerDeviceStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => TrackerDeviceStatus.unassigned,
    );
  }

  String get label => switch (this) {
    TrackerDeviceStatus.active => 'Active',
    TrackerDeviceStatus.inactive => 'Inactive',
    TrackerDeviceStatus.offline => 'Offline',
    TrackerDeviceStatus.maintenance => 'Maintenance',
    TrackerDeviceStatus.unassigned => 'Unassigned',
  };
}

class GpsTracker {
  const GpsTracker({
    required this.id,
    required this.deviceIdentifier,
    this.deviceName,
    this.deviceType,
    this.serialNumber,
    this.paroleeId,
    this.paroleeName,
    this.hasHiddenAssignment = false,
    this.status = TrackerDeviceStatus.unassigned,
    this.batteryLevel,
    this.lastSeenAt,
    this.assignedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String deviceIdentifier;

  /// Human-readable device ID (e.g. DEV-000001). Falls back to [id].
  String get deviceId => deviceIdentifier.isNotEmpty ? deviceIdentifier : id;
  final String? deviceName;
  final String? deviceType;
  final String? serialNumber;
  final String? paroleeId;
  final String? paroleeName;

  /// The tracker is assigned, but the current officer cannot see the case.
  final bool hasHiddenAssignment;
  final TrackerDeviceStatus status;
  final int? batteryLevel;
  final DateTime? lastSeenAt;
  final DateTime? assignedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  bool get isAssigned =>
      hasHiddenAssignment || (paroleeId != null && paroleeId!.isNotEmpty);

  Map<String, dynamic> toMap() => {
    'id': id,
    'device_id': deviceIdentifier,
    'device_name': deviceName,
    'device_type': deviceType,
    'serial_number': serialNumber,
    'parolee_id': paroleeId,
    'parolee_name': paroleeName,
    'has_hidden_assignment': hasHiddenAssignment,
    'status': status.name,
    'battery_level': batteryLevel,
    'last_seen_at': lastSeenAt?.toIso8601String(),
    'assigned_at': assignedAt?.toIso8601String(),
    'created_at': createdAt?.toIso8601String(),
    'updated_at': updatedAt?.toIso8601String(),
  };

  factory GpsTracker.fromMap(Map<String, dynamic> map) {
    return GpsTracker(
      id: map['id']?.toString() ?? '',
      deviceIdentifier:
          map['device_id'] as String? ??
          map['device_identifier'] as String? ??
          map['deviceIdentifier'] as String? ??
          '',
      deviceName: map['device_name'] as String? ?? map['deviceName'] as String?,
      deviceType: map['device_type'] as String? ?? map['deviceType'] as String?,
      serialNumber:
          map['serial_number'] as String? ?? map['serialNumber'] as String?,
      paroleeId: map['parolee_id'] as String? ?? map['paroleeId'] as String?,
      paroleeName:
          map['parolee_name'] as String? ?? map['paroleeName'] as String?,
      hasHiddenAssignment:
          map['has_hidden_assignment'] as bool? ??
          map['hasHiddenAssignment'] as bool? ??
          false,
      status: TrackerDeviceStatus.fromString(map['status'] as String?),
      batteryLevel: ((map['battery_level'] ?? map['batteryLevel']) as num?)
          ?.toInt(),
      lastSeenAt: _parseDate(map['last_seen_at'] ?? map['lastSeenAt']),
      assignedAt: _parseDate(map['assigned_at'] ?? map['assignedAt']),
      createdAt: _parseDate(map['created_at'] ?? map['createdAt']),
      updatedAt: _parseDate(map['updated_at'] ?? map['updatedAt']),
    );
  }

  GpsTracker copyWith({
    String? paroleeId,
    String? paroleeName,
    TrackerDeviceStatus? status,
    int? batteryLevel,
    DateTime? lastSeenAt,
    DateTime? updatedAt,
  }) {
    return GpsTracker(
      id: id,
      deviceIdentifier: deviceIdentifier,
      paroleeId: paroleeId ?? this.paroleeId,
      paroleeName: paroleeName ?? this.paroleeName,
      hasHiddenAssignment: hasHiddenAssignment ?? this.hasHiddenAssignment,
      status: status ?? this.status,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static DateTime? _parseDate(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
    return null;
  }
}
