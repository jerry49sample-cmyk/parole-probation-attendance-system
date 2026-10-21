import 'dart:async';

import 'package:last/core/services/live_stats_service.dart';
import 'package:last/core/utils/app_logger.dart';
import 'package:last/core/utils/date_utils.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:last/core/utils/validators.dart';
import 'package:last/features/auth/models/app_user.dart';
import 'package:last/features/auth/models/supervision_period.dart';
import 'package:last/features/officer/models/dashboard_stats.dart';
import 'package:last/features/officer/models/parolee_summary.dart';
import 'package:last/features/shared/models/attendance_record.dart';
import 'package:last/features/shared/models/schedule_model.dart';
import 'package:last/features/tracking/services/tracking_audit_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OfficerService {
  OfficerService({
    LiveStatsService? liveStatsService,
    TrackingAuditService? auditService,
  })  : _liveStats = liveStatsService ?? LiveStatsService(),
        _audit = auditService ?? createTrackingAuditService();

  final SupabaseClient _db = SupabaseConfig.client;
  final LiveStatsService _liveStats;
  final TrackingAuditService _audit;

  Stream<DashboardSnapshot> watchDashboard(
    String officerId, {
    String? query,
    AttendanceStatus? filter,
  }) {
    if (officerId.isEmpty) {
      return Stream.error(Exception('Officer ID is missing. Sign out and sign in again.'));
    }
    final controller = StreamController<DashboardSnapshot>();
    final subscriptions = <StreamSubscription<dynamic>>[];
    Timer? debounce;
    var building = false;

    Future<void> emit() async {
      if (controller.isClosed || building) return;
      building = true;
      try {
        final snapshot = await _buildDashboard(officerId, query: query, filter: filter);
        if (!controller.isClosed) controller.add(snapshot);
      } catch (error, stack) {
        AppLogger.e('OfficerService', 'Supabase dashboard load failed', error, stack);
        if (!controller.isClosed) controller.addError(error);
      } finally {
        building = false;
      }
    }

    void scheduleEmit() {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 250), emit);
    }

    for (final table in ['profiles', 'attendance_records', 'schedules']) {
      subscriptions.add(
        _db.from(table).stream(primaryKey: ['id']).listen(
          (_) => scheduleEmit(),
          onError: (Object error, StackTrace stack) {
            if (!controller.isClosed) controller.addError(error, stack);
          },
        ),
      );
    }
    scheduleEmit();
    controller.onCancel = () async {
      debounce?.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
  }

  Future<DashboardSnapshot> _buildDashboard(
    String officerId, {
    String? query,
    AttendanceStatus? filter,
  }) async {
    final parolees = await getParolees(officerId, query: query, filter: filter);
    final schedules = await getSchedules(officerId);
    try {
      await _liveStats.publish(officerId, parolees);
    } catch (error, stack) {
      AppLogger.e('OfficerService', 'Could not publish live stats', error, stack);
    }
    return DashboardSnapshot(
      stats: DashboardStats(
        totalCases: parolees.length,
        checkedIn: parolees
            .where((p) =>
                p.status == AttendanceStatus.checkedIn ||
                p.status == AttendanceStatus.confirmed)
            .length,
        pending: parolees.where((p) => p.status == AttendanceStatus.pending).length,
        missed: parolees.where((p) => p.status == AttendanceStatus.missed).length,
      ),
      parolees: parolees,
      schedules: schedules,
    );
  }

  Future<List<ParoleeSummary>> getParolees(
    String officerId, {
    String? query,
    AttendanceStatus? filter,
  }) async {
    final profileRows = await _db
        .from('profiles')
        .select()
        .eq('role', 'parolee')
        .eq('officer_id', officerId);
    final attendanceRows = await _db
        .from('attendance_records')
        .select()
        .eq('officer_id', officerId)
        .order('check_in_time', ascending: false);
    final scheduleRows =
        await _db.from('schedules').select().eq('officer_id', officerId);
    final attendance = attendanceRows
        .map((row) => AttendanceRecord.fromMap(row))
        .toList();
    final schedules = scheduleRows
        .map((row) => ScheduleModel.fromMap({
              ...row,
              'paroleeId': row['parolee_id'],
              'paroleeName': row['parolee_name'],
              'officerId': row['officer_id'],
              'scheduledAt': row['scheduled_at'],
            }))
        .where((schedule) => schedule.scheduledAt.isBefore(DateTime.now()))
        .toList();

    var results = profileRows.map((row) {
      final user = AppUser.fromMap(row);
      final status = _resolveStatus(user.id, attendance, schedules);
      final today = attendance.where(
        (record) => record.paroleeId == user.id && AppDateUtils.isToday(record.checkInTime),
      );
      final supervision = SupervisionPeriod.compute(
        startRaw: user.supervisionStartDate,
        endRaw: user.supervisionEndDate,
        isSuspended: user.supervisionIsSuspended,
      );
      return ParoleeSummary(
        id: user.id,
        fullName: user.fullName,
        caseNumber: user.caseNumber ?? 'N/A',
        status: status,
        officerId: officerId,
        lastCheckIn: today.isEmpty ? null : today.first.checkInTime,
        supervisionDatesMissing: supervision.hasMissingDates,
        supervisionShortLabel: supervision.shortLabel,
      );
    }).toList();

    if (query != null && query.trim().isNotEmpty) {
      final search = query.trim().toLowerCase();
      results = results
          .where((p) =>
              p.fullName.toLowerCase().contains(search) ||
              p.caseNumber.toLowerCase().contains(search))
          .toList();
    }
    if (filter != null) results = results.where((p) => p.status == filter).toList();
    return results;
  }

  AttendanceStatus _resolveStatus(
    String paroleeId,
    List<AttendanceRecord> attendance,
    List<ScheduleModel> overdueSchedules,
  ) {
    final today = attendance.where(
      (record) => record.paroleeId == paroleeId && AppDateUtils.isToday(record.checkInTime),
    );
    if (today.any((record) =>
        record.status == AttendanceStatus.checkedIn ||
        record.status == AttendanceStatus.confirmed)) {
      return AttendanceStatus.checkedIn;
    }
    final missed = overdueSchedules.any((schedule) =>
        schedule.paroleeId == paroleeId &&
        !attendance.any((record) =>
            record.paroleeId == paroleeId &&
            AppDateUtils.isSameDay(record.checkInTime, schedule.scheduledAt)));
    return missed ? AttendanceStatus.missed : AttendanceStatus.pending;
  }

  Future<List<ScheduleModel>> getSchedules(String officerId) async {
    final rows = await _db
        .from('schedules')
        .select()
        .eq('officer_id', officerId)
        .order('scheduled_at');
    return rows
        .map((row) => ScheduleModel.fromMap({
              ...row,
              'paroleeId': row['parolee_id'],
              'paroleeName': row['parolee_name'],
              'officerId': row['officer_id'],
              'scheduledAt': row['scheduled_at'],
            }))
        .where((schedule) => schedule.scheduledAt.isAfter(DateTime.now()))
        .toList();
  }

  Future<AppUser?> getUserById(String id) async {
    final row = await _db.from('profiles').select().eq('id', id).maybeSingle();
    return row == null ? null : AppUser.fromMap(row);
  }

  Future<void> updateSupervisionPeriod({
    required String paroleeId,
    required DateTime start,
    required DateTime end,
    required bool isSuspended,
    required String actorId,
    required String actorRole,
  }) async {
    final rangeError = Validators.supervisionRange(start, end);
    if (rangeError != null) throw Exception(rangeError);
    final existing = await getUserById(paroleeId);
    if (existing == null) throw Exception('Parolee not found.');

    final startIso = SupervisionPeriod.formatIso(start);
    final endIso = SupervisionPeriod.formatIso(end);
    await _db.from('profiles').update({
      'supervision_start_date': startIso,
      'supervision_end_date': endIso,
      'supervision_is_suspended': isSuspended,
    }).eq('id', paroleeId);
    await _audit.logSupervisionPeriodUpdated(
      paroleeId: paroleeId,
      actorId: actorId,
      actorRole: actorRole,
      metadata: {
        'previousStart': existing.supervisionStartDate,
        'previousEnd': existing.supervisionEndDate,
        'previousSuspended': existing.supervisionIsSuspended,
        'start': startIso,
        'end': endIso,
        'suspended': isSuspended,
      },
    );
  }
}

class DashboardSnapshot {
  const DashboardSnapshot({
    required this.stats,
    required this.parolees,
    required this.schedules,
  });

  final DashboardStats stats;
  final List<ParoleeSummary> parolees;
  final List<ScheduleModel> schedules;
}

OfficerService createOfficerService() => OfficerService();
