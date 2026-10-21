enum ActivityType {
  treePlanting,
  communityCleanup,
  counselingSession,
  other;

  String get label {
    switch (this) {
      case ActivityType.treePlanting:
        return 'Tree Planting';
      case ActivityType.communityCleanup:
        return 'Community Clean-Up Drive';
      case ActivityType.counselingSession:
        return 'Counseling Session';
      case ActivityType.other:
        return 'Other';
    }
  }

  static ActivityType fromString(String value) {
    return ActivityType.values.firstWhere(
      (t) => t.name == value,
      orElse: () => ActivityType.other,
    );
  }
}

enum ActivityStatus {
  pending,
  ongoing,
  completed,
  missed;

  String get label {
    switch (this) {
      case ActivityStatus.pending:
        return 'Pending';
      case ActivityStatus.ongoing:
        return 'Ongoing';
      case ActivityStatus.completed:
        return 'Completed';
      case ActivityStatus.missed:
        return 'Missed';
    }
  }

  static ActivityStatus fromString(String value) {
    return ActivityStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => ActivityStatus.pending,
    );
  }
}

class ActivityModel {
  ActivityModel({
    required this.id,
    required this.title,
    required this.type,
    required this.description,
    required this.location,
    required this.scheduleDate,
    required this.assignedParoleeIds,
    required this.assignedOfficerId,
    required this.status,
    required this.createdAt,
    this.completedParoleeIds = const [],
    this.officerName,
  });

  final String id;
  final String title;
  final ActivityType type;
  final String description;
  final String location;
  final DateTime scheduleDate;
  final List<String> assignedParoleeIds;
  final String assignedOfficerId;
  final ActivityStatus status;
  final DateTime createdAt;
  final List<String> completedParoleeIds;
  final String? officerName;

  int get totalAssigned => assignedParoleeIds.length;
  int get totalCompleted => completedParoleeIds.length;
  double get completionRate =>
      totalAssigned == 0 ? 0 : (totalCompleted / totalAssigned) * 100;

  bool isAssignedTo(String paroleeId) => assignedParoleeIds.contains(paroleeId);
  bool isCompletedBy(String paroleeId) => completedParoleeIds.contains(paroleeId);

  Map<String, dynamic> toMap() => {
        'title': title,
        'activity_type': type.name,
        'description': description,
        'location_name': location,
        'start_time': scheduleDate.toIso8601String(),
        'assigned_parolee_ids': assignedParoleeIds,
        'assigned_officer_id': assignedOfficerId,
        'status': status.name,
        'created_at': createdAt.toIso8601String(),
        'completed_parolee_ids': completedParoleeIds,
        if (officerName != null) 'officer_name': officerName,
      };

  factory ActivityModel.fromMap(Map<String, dynamic> map) {
    return ActivityModel(
      id: map['id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      type: ActivityType.fromString(
        map['activity_type'] as String? ?? map['type'] as String? ?? 'other',
      ),
      description: map['description'] as String? ?? '',
      location: map['location_name'] as String? ?? map['location'] as String? ?? '',
      scheduleDate: DateTime.tryParse(
            (map['start_time'] ?? map['scheduleDate'])?.toString() ?? '',
          ) ??
          DateTime.now(),
      assignedParoleeIds: List<String>.from(
        (map['assigned_parolee_ids'] ?? map['assignedParolees']) as List? ?? [],
      ),
      assignedOfficerId: map['assigned_officer_id'] as String? ??
          map['assignedOfficerId'] as String? ??
          '',
      status: ActivityStatus.fromString(map['status'] as String? ?? 'pending'),
      createdAt: DateTime.tryParse((map['created_at'] ?? map['createdAt'])?.toString() ?? '') ??
          DateTime.now(),
      completedParoleeIds: List<String>.from(
        (map['completed_parolee_ids'] ?? map['completedParolees']) as List? ?? [],
      ),
      officerName: map['officer_name'] as String? ?? map['officerName'] as String?,
    );
  }

  ActivityModel copyWith({
    ActivityStatus? status,
    List<String>? completedParoleeIds,
  }) {
    return ActivityModel(
      id: id,
      title: title,
      type: type,
      description: description,
      location: location,
      scheduleDate: scheduleDate,
      assignedParoleeIds: assignedParoleeIds,
      assignedOfficerId: assignedOfficerId,
      status: status ?? this.status,
      createdAt: createdAt,
      completedParoleeIds: completedParoleeIds ?? this.completedParoleeIds,
      officerName: officerName,
    );
  }
}

class ActivityStats {
  const ActivityStats({
    required this.total,
    required this.ongoing,
    required this.completed,
    required this.missed,
    required this.pending,
  });

  final int total;
  final int ongoing;
  final int completed;
  final int missed;
  final int pending;
}
