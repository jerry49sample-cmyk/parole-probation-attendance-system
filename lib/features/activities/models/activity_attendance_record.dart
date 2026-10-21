enum ActivityParticipationStatus {
  present,
  absent,
  late,
  pending;

  String get label {
    switch (this) {
      case ActivityParticipationStatus.present:
        return 'Present';
      case ActivityParticipationStatus.absent:
        return 'Absent';
      case ActivityParticipationStatus.late:
        return 'Late';
      case ActivityParticipationStatus.pending:
        return 'Pending';
    }
  }

  static ActivityParticipationStatus fromString(String value) {
    return ActivityParticipationStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => ActivityParticipationStatus.pending,
    );
  }

  bool get countsAsPresent =>
      this == ActivityParticipationStatus.present ||
      this == ActivityParticipationStatus.late;
}

class ActivityAttendanceRecord {
  ActivityAttendanceRecord({
    required this.id,
    required this.activityId,
    required this.paroleeId,
    required this.paroleeName,
    required this.officerId,
    required this.status,
    required this.scannedAt,
    required this.verifiedByOfficer,
    required this.timestamp,
    this.activityTitle,
  });

  final String id;
  final String activityId;
  final String paroleeId;
  final String paroleeName;
  final String officerId;
  final ActivityParticipationStatus status;
  final DateTime scannedAt;
  final bool verifiedByOfficer;
  final DateTime timestamp;
  final String? activityTitle;

  Map<String, dynamic> toMap() => {
        'activityId': activityId,
        'paroleeId': paroleeId,
        'paroleeName': paroleeName,
        'officerId': officerId,
        'status': status.name,
        'scannedAt': scannedAt.toIso8601String(),
        'verifiedByOfficer': verifiedByOfficer,
        'timestamp': timestamp.toIso8601String(),
        if (activityTitle != null) 'activityTitle': activityTitle,
        'recordType': 'activity',
      };

  factory ActivityAttendanceRecord.fromMap(Map<String, dynamic> map) {
    return ActivityAttendanceRecord(
      id: map['id'] as String? ?? '',
      activityId: map['activity_id']?.toString() ?? map['activityId']?.toString() ?? '',
      paroleeId: map['parolee_id']?.toString() ?? map['paroleeId']?.toString() ?? '',
      paroleeName: map['parolee_name'] as String? ?? map['paroleeName'] as String? ?? '',
      officerId: map['officer_id']?.toString() ?? map['officerId']?.toString() ?? '',
      status: ActivityParticipationStatus.fromString(map['status'] as String? ?? 'pending'),
      scannedAt: DateTime.tryParse(
            (map['scanned_at'] ?? map['scannedAt'])?.toString() ?? '',
          ) ??
          DateTime.now(),
      verifiedByOfficer:
          map['verified_by_officer'] as bool? ?? map['verifiedByOfficer'] as bool? ?? true,
      timestamp: DateTime.tryParse(
            (map['ticket_timestamp'] ?? map['timestamp'])?.toString() ?? '',
          ) ??
          DateTime.now(),
      activityTitle: map['activity_title'] as String? ?? map['activityTitle'] as String?,
    );
  }
}

class ActivityAttendanceStats {
  const ActivityAttendanceStats({
    required this.present,
    required this.absent,
    required this.late,
    required this.pending,
    required this.total,
  });

  final int present;
  final int absent;
  final int late;
  final int pending;
  final int total;

  int get attended => present + late;
}
