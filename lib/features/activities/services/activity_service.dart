import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/activities/models/activity_model.dart';
import 'package:last/features/shared/models/notification_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class ActivityService {
  final SupabaseClient _db = SupabaseConfig.client;

  Stream<List<ActivityModel>> watchForOfficer(String officerId) =>
      watchAll(officerId: officerId);

  Stream<List<ActivityModel>> watchForParolee(String paroleeId) =>
      _watchRows().map((rows) {
        final activities = rows
            .where((row) => _stringList(row['assigned_parolee_ids'] ?? row['assignedParolees'])
                .contains(paroleeId))
            .map(_fromRow)
            .toList()
          ..sort((a, b) => a.scheduleDate.compareTo(b.scheduleDate));
        return activities;
      });

  Stream<List<ActivityModel>> watchAll({
    String? officerId,
    ActivityStatus? status,
    ActivityType? type,
  }) =>
      _watchRows().map((rows) {
        return rows
            .map(_fromRow)
            .where((activity) =>
                (officerId == null || officerId.isEmpty || activity.assignedOfficerId == officerId) &&
                (status == null || activity.status == status) &&
                (type == null || activity.type == type))
            .toList()
          ..sort((a, b) => b.scheduleDate.compareTo(a.scheduleDate));
      });

  Stream<List<Map<String, dynamic>>> _watchRows() =>
      _db.from('activities').stream(primaryKey: ['id']);

  Stream<ActivityStats> watchStats({String? officerId}) =>
      watchAll(officerId: officerId).map((list) => ActivityStats(
            total: list.length,
            ongoing: list.where((a) => a.status == ActivityStatus.ongoing).length,
            completed: list.where((a) => a.status == ActivityStatus.completed).length,
            missed: list.where((a) => a.status == ActivityStatus.missed).length,
            pending: list.where((a) => a.status == ActivityStatus.pending).length,
          ));

  Future<ActivityModel> createActivity({
    required String title,
    required ActivityType type,
    required String description,
    required String location,
    required DateTime scheduleDate,
    required String officerId,
    required String officerName,
    required List<String> paroleeIds,
  }) async {
    final row = await _db
        .from('activities')
        .insert({
          'title': title,
          'activity_type': type.name,
          'description': description,
          'location_name': location,
          'start_time': scheduleDate.toIso8601String(),
          'end_time': scheduleDate.add(const Duration(hours: 1)).toIso8601String(),
          'assigned_officer_id': officerId,
          'officer_name': officerName,
          'assigned_parolee_ids': paroleeIds,
          'completed_parolee_ids': <String>[],
          'status': ActivityStatus.pending.name,
        })
        .select()
        .single();

    for (final paroleeId in paroleeIds) {
      await _notify(
        userId: paroleeId,
        title: 'New Activity Assigned',
        body: '$title on ${scheduleDate.toLocal()}',
        type: NotificationType.reminder,
      );
    }
    return _fromRow(row);
  }

  Future<void> updateStatus(String activityId, ActivityStatus status) async {
    await _db.from('activities').update({'status': status.name}).eq('id', activityId);
  }

  Future<void> assignParolees(String activityId, List<String> paroleeIds) async {
    await _db
        .from('activities')
        .update({'assigned_parolee_ids': paroleeIds})
        .eq('id', activityId);
  }

  ActivityModel _fromRow(Map<String, dynamic> row) {
    final activity = ActivityModel.fromMap({
      ...row,
      'id': row['id']?.toString() ?? '',
      'type': row['activity_type'] ?? row['type'],
      'location': row['location_name'] ?? row['location'],
      'scheduleDate': row['start_time'] ?? row['scheduleDate'],
      'assignedParolees': row['assigned_parolee_ids'] ?? row['assignedParolees'],
      'assignedOfficerId': row['assigned_officer_id'] ?? row['assignedOfficerId'],
      'createdAt': row['created_at'] ?? row['createdAt'],
      'completedParolees': row['completed_parolee_ids'] ?? row['completedParolees'],
      'officerName': row['officer_name'] ?? row['officerName'],
    });
    final now = DateTime.now();
    if (activity.status == ActivityStatus.completed) return activity;
    if (activity.scheduleDate.isBefore(now.subtract(const Duration(hours: 2))) &&
        activity.completedParoleeIds.length < activity.assignedParoleeIds.length) {
      return activity.copyWith(status: ActivityStatus.missed);
    }
    if (_isSameDay(activity.scheduleDate, now) &&
        activity.status == ActivityStatus.pending) {
      return activity.copyWith(status: ActivityStatus.ongoing);
    }
    if (activity.assignedParoleeIds.isNotEmpty &&
        activity.completedParoleeIds.length >= activity.assignedParoleeIds.length) {
      return activity.copyWith(status: ActivityStatus.completed);
    }
    return activity;
  }

  Future<void> _notify({
    required String userId,
    required String title,
    required String body,
    required NotificationType type,
  }) async {
    if (userId.isEmpty) return;
    await _db.from('notifications').insert({
      'id': const Uuid().v4(),
      'user_id': userId,
      'title': title,
      'body': body,
      'type': type.name,
      'created_at': DateTime.now().toIso8601String(),
      'read': false,
    });
  }

  List<String> _stringList(Object? value) =>
      value is List ? value.map((item) => item.toString()).toList() : const [];

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

ActivityService createActivityService() => ActivityService();
