enum AttendanceStatus {
  checkedIn,
  pending,
  missed,
  confirmed;

  String get label {
    switch (this) {
      case AttendanceStatus.checkedIn:
        return 'Checked In';
      case AttendanceStatus.pending:
        return 'Pending';
      case AttendanceStatus.missed:
        return 'Missed';
      case AttendanceStatus.confirmed:
        return 'Confirmed';
    }
  }

  static AttendanceStatus fromString(String value) {
    return AttendanceStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => AttendanceStatus.pending,
    );
  }
}

class AttendanceRecord {
  AttendanceRecord({
    required this.id,
    required this.ticketId,
    required this.paroleeId,
    required this.paroleeName,
    required this.officerId,
    required this.status,
    this.checkInTime,
    this.scheduledTime,
    this.location,
    this.verified = false,
    this.qrPayload,
  });

  final String id;
  final String ticketId;
  final String paroleeId;
  final String paroleeName;
  final String officerId;
  final AttendanceStatus status;
  final DateTime? checkInTime;
  final DateTime? scheduledTime;
  final String? location;
  final bool verified;
  final String? qrPayload;

  Map<String, dynamic> toMap() => {
    'id': id,
    'ticketId': ticketId,
    'paroleeId': paroleeId,
    'paroleeName': paroleeName,
    'officerId': officerId,
    'status': status.name,
    'checkInTime': checkInTime?.toIso8601String(),
    'scheduledTime': scheduledTime?.toIso8601String(),
    'location': location,
    'verified': verified,
    'qrPayload': qrPayload,
  };

  factory AttendanceRecord.fromMap(Map<String, dynamic> map) {
    return AttendanceRecord(
      id: map['id']?.toString() ?? '',
      ticketId:
          map['ticket_id']?.toString() ?? map['ticketId']?.toString() ?? '',
      paroleeId:
          map['parolee_id']?.toString() ?? map['paroleeId']?.toString() ?? '',
      paroleeName:
          map['parolee_name'] as String? ?? map['paroleeName'] as String? ?? '',
      officerId:
          map['officer_id']?.toString() ?? map['officerId']?.toString() ?? '',
      status: AttendanceStatus.fromString(
        map['status'] as String? ?? 'pending',
      ),
      checkInTime: (map['check_in_time'] ?? map['checkInTime']) != null
          ? DateTime.tryParse(
              (map['check_in_time'] ?? map['checkInTime']).toString(),
            )
          : null,
      scheduledTime: (map['scheduled_time'] ?? map['scheduledTime']) != null
          ? DateTime.tryParse(
              (map['scheduled_time'] ?? map['scheduledTime']).toString(),
            )
          : null,
      location: map['location'] as String?,
      verified: map['verified'] as bool? ?? false,
      qrPayload: map['qr_payload'] as String? ?? map['qrPayload'] as String?,
    );
  }

  AttendanceRecord copyWith({
    AttendanceStatus? status,
    DateTime? checkInTime,
    bool? verified,
    String? qrPayload,
  }) {
    return AttendanceRecord(
      id: id,
      ticketId: ticketId,
      paroleeId: paroleeId,
      paroleeName: paroleeName,
      officerId: officerId,
      status: status ?? this.status,
      checkInTime: checkInTime ?? this.checkInTime,
      scheduledTime: scheduledTime,
      location: location,
      verified: verified ?? this.verified,
      qrPayload: qrPayload ?? this.qrPayload,
    );
  }
}
