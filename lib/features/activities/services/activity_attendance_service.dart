import 'package:last/core/services/notification_service.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/activities/models/activity_attendance_record.dart';
import 'package:last/features/activities/models/activity_model.dart';
import 'package:last/features/activities/models/activity_qr_payload.dart';
import 'package:last/features/auth/models/app_user.dart';
import 'package:last/features/auth/models/user_role.dart';
import 'package:last/features/shared/models/notification_model.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ActivityScanResult {
  const ActivityScanResult.success(this.record, {this.warning}) : error = null;
  const ActivityScanResult.failure(this.error)
      : record = null,
        warning = null;

  final ActivityAttendanceRecord? record;
  final String? error;
  final String? warning;
  bool get isSuccess => record != null;
}

class ActivityAttendanceService {
  final SupabaseClient _db = SupabaseConfig.client;
  final NotificationService _notifications = createNotificationService();

  Stream<List<ActivityAttendanceRecord>> watchForActivity(String activityId) => _db
      .from('activity_attendance_records')
      .stream(primaryKey: ['id'])
      .eq('activity_id', activityId)
      .map(_mapRows);

  Stream<List<ActivityAttendanceRecord>> watchForParolee(String paroleeId) => _db
      .from('activity_attendance_records')
      .stream(primaryKey: ['id'])
      .eq('parolee_id', paroleeId)
      .map(_mapRows);

  Stream<List<ActivityAttendanceRecord>> watchAll() => _db
      .from('activity_attendance_records')
      .stream(primaryKey: ['id'])
      .map(_mapRows);

  Stream<ActivityAttendanceStats> watchStatsForActivity(String activityId) =>
      watchForActivity(activityId).map(_computeStats);

  ActivityAttendanceStats _computeStats(List<ActivityAttendanceRecord> list) =>
      ActivityAttendanceStats(
        present: list.where((r) => r.status == ActivityParticipationStatus.present).length,
        absent: list.where((r) => r.status == ActivityParticipationStatus.absent).length,
        late: list.where((r) => r.status == ActivityParticipationStatus.late).length,
        pending: list.where((r) => r.status == ActivityParticipationStatus.pending).length,
        total: list.length,
      );

  Future<ActivityAttendanceRecord?> getForParoleeActivity(
    String activityId,
    String paroleeId,
  ) async {
    final row = await _db
        .from('activity_attendance_records')
        .select()
        .eq('activity_id', activityId)
        .eq('parolee_id', paroleeId)
        .maybeSingle();
    return row == null ? null : ActivityAttendanceRecord.fromMap(row);
  }

  Future<ActivityScanResult> scanAndMark({
    required String rawQr,
    required AppUser officer,
    required String expectedActivityId,
    required ActivityParticipationStatus status,
    required ActivityModel activity,
  }) async {
    if (officer.role != UserRole.officer) {
      return const ActivityScanResult.failure('Only officers can mark activity attendance');
    }

    final decoded = ActivityQrPayload.decode(rawQr);
    if (decoded == null || decoded.token.isEmpty) {
      return const ActivityScanResult.failure('Invalid QR code format');
    }
    if (decoded.activityId != expectedActivityId) {
      return const ActivityScanResult.failure(
        'This QR code was not issued for the selected activity.',
      );
    }

    try {
      final response = await _db.rpc(
        'ppa_record_activity_attendance',
        params: {
          'p_token': decoded.token,
          'p_activity_id': expectedActivityId,
          'p_status': status.name,
        },
      );
      if (response is! Map) {
        return const ActivityScanResult.failure(
          'The server returned an invalid attendance result.',
        );
      }
      final record = ActivityAttendanceRecord.fromMap(Map<String, dynamic>.from(response));
      final warnings = <String>[];

      try {
        await _syncActivityCompletion(activity, record.paroleeId, status);
      } catch (_) {
        warnings.add('Attendance was saved, but activity progress could not be updated.');
      }

      try {
        await _notifications.send(
          userId: record.paroleeId,
          title: 'Activity Attendance Recorded',
          body: 'Your attendance for ${activity.title} was marked ${status.label} by your officer.',
          type: NotificationType.success,
        );
      } catch (_) {
        warnings.add('Attendance was saved, but the parolee notification could not be sent.');
      }

      return ActivityScanResult.success(
        record,
        warning: warnings.isEmpty ? null : warnings.join(' '),
      );
    } catch (error) {
      return ActivityScanResult.failure('Failed to save attendance: $error');
    }
  }

  Future<void> _syncActivityCompletion(
    ActivityModel activity,
    String paroleeId,
    ActivityParticipationStatus status,
  ) async {
    final completed = List<String>.from(activity.completedParoleeIds);
    if (status.countsAsPresent) {
      if (!completed.contains(paroleeId)) completed.add(paroleeId);
    } else if (status == ActivityParticipationStatus.absent) {
      completed.remove(paroleeId);
    }

    final activityStatus = completed.length >= activity.assignedParoleeIds.length &&
            activity.assignedParoleeIds.isNotEmpty
        ? ActivityStatus.completed
        : activity.status == ActivityStatus.pending
            ? ActivityStatus.ongoing
            : activity.status;
    await _db.from('activities').update({
      'completed_parolee_ids': completed,
      'status': activityStatus.name,
    }).eq('id', activity.id);
  }

  List<ActivityAttendanceRecord> _mapRows(List<Map<String, dynamic>> rows) {
    final records = rows.map(ActivityAttendanceRecord.fromMap).toList()
      ..sort((a, b) => b.scannedAt.compareTo(a.scannedAt));
    return records;
  }
}
