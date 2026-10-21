enum NotificationType { alert, success, reminder, info }

class NotificationModel {
  NotificationModel({
    required this.id,
    required this.userId,
    required this.title,
    required this.body,
    required this.type,
    required this.createdAt,
    this.read = false,
  });

  final String id;
  final String userId;
  final String title;
  final String body;
  final NotificationType type;
  final DateTime createdAt;
  final bool read;

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_id': userId,
        'title': title,
        'body': body,
        'type': type.name,
        'created_at': createdAt.toIso8601String(),
        'read': read,
      };

  factory NotificationModel.fromMap(Map<String, dynamic> map) {
    return NotificationModel(
      id: map['id'] as String? ?? '',
      userId: map['user_id']?.toString() ?? map['userId']?.toString() ?? '',
      title: map['title'] as String? ?? '',
      body: map['body'] as String? ?? '',
      type: NotificationType.values.firstWhere(
        (t) => t.name == (map['type'] as String? ?? 'info'),
        orElse: () => NotificationType.info,
      ),
      createdAt: DateTime.tryParse((map['created_at'] ?? map['createdAt'])?.toString() ?? '') ??
          DateTime.now(),
      read: map['read'] as bool? ?? false,
    );
  }

  NotificationModel copyWith({bool? read}) {
    return NotificationModel(
      id: id,
      userId: userId,
      title: title,
      body: body,
      type: type,
      createdAt: createdAt,
      read: read ?? this.read,
    );
  }
}
