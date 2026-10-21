import 'dart:async';

import 'package:intl/intl.dart';
import 'package:last/core/utils/date_utils.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/activities/models/activity_attendance_record.dart';
import 'package:last/features/auth/models/app_user.dart';
import 'package:last/features/auth/models/user_role.dart';
import 'package:last/features/reports/models/report_data.dart';
import 'package:last/features/shared/models/attendance_record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class ReportsService {
  Future<ReportData> getReportData({String? officerId});
  Stream<ReportData> watchReportData({String? officerId});
}

class SupabaseReportsService implements ReportsService {
  final SupabaseClient _db = SupabaseConfig.client;

  @override
  Stream<ReportData> watchReportData({String? officerId}) {
    late final StreamController<ReportData> controller;
    StreamSubscription? attendanceSubscription;
    StreamSubscription? activityAttendanceSubscription;

    Future<void> refresh() async {
      try {
        final data = await getReportData(officerId: officerId);
        if (!controller.isClosed) controller.add(data);
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      }
    }

    controller = StreamController<ReportData>(
      onListen: () {
        attendanceSubscription = _db
            .from('attendance_records')
            .stream(primaryKey: ['id'])
            .listen((_) => unawaited(refresh()), onError: controller.addError);
        activityAttendanceSubscription = _db
            .from('activity_attendance_records')
            .stream(primaryKey: ['id'])
            .listen((_) => unawaited(refresh()), onError: controller.addError);
        unawaited(refresh());
      },
      onCancel: () async {
        await attendanceSubscription?.cancel();
        await activityAttendanceSubscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<ReportData> getReportData({String? officerId}) async {
    var attendanceQuery = _db.from('attendance_records').select();
    if (officerId != null && officerId.isNotEmpty) {
      attendanceQuery = attendanceQuery.eq('officer_id', officerId);
    }
    final attendanceRows = await attendanceQuery.order('check_in_time', ascending: false);
    final records = attendanceRows.map((row) => AttendanceRecord.fromMap(row)).toList();
    var activityAttendanceQuery =
        _db.from('activity_attendance_records').select();
    if (officerId != null && officerId.isNotEmpty) {
      activityAttendanceQuery =
          activityAttendanceQuery.eq('officer_id', officerId);
    }
    final activityAttendanceRows = await activityAttendanceQuery
        .order('scanned_at', ascending: false);
    final activityAttendanceRecords = activityAttendanceRows
        .map((row) => ActivityAttendanceRecord.fromMap(row))
        .toList();
    final activityAttendanceStats = ActivityAttendanceStats(
      present: activityAttendanceRecords
          .where((record) => record.status == ActivityParticipationStatus.present)
          .length,
      absent: activityAttendanceRecords
          .where((record) => record.status == ActivityParticipationStatus.absent)
          .length,
      late: activityAttendanceRecords
          .where((record) => record.status == ActivityParticipationStatus.late)
          .length,
      pending: activityAttendanceRecords
          .where((record) => record.status == ActivityParticipationStatus.pending)
          .length,
      total: activityAttendanceRecords.length,
    );
    final userRows = await _db.from('profiles').select().order('full_name');
    final users = userRows.map((row) => AppUser.fromMap(row)).toList();
    final parolees = users.where((user) =>
        user.role == UserRole.parolee &&
        (officerId == null || officerId.isEmpty || user.officerId == officerId));

    final checkedInRecords = records.where((record) =>
        record.status == AttendanceStatus.checkedIn ||
        record.status == AttendanceStatus.confirmed);
    final missedCount = records.where((record) => record.status == AttendanceStatus.missed).length;
    final checkedToday = records
        .where((record) => AppDateUtils.isToday(record.checkInTime))
        .map((record) => record.paroleeId)
        .toSet();
    final paroleeList = parolees.toList();
    final attendanceCount = records.length;

    return ReportData(
      weeklyPoints: _buildWeeklyPoints(records),
      monthlyPoints: _buildMonthlyPoints(records),
      complianceRate: attendanceCount == 0
          ? 0
          : ((attendanceCount - missedCount) / attendanceCount) * 100,
      attendancePercentage: paroleeList.isEmpty
          ? 0
          : (checkedToday.length / paroleeList.length) * 100,
      missedCount: missedCount,
      totalCheckIns: checkedInRecords.length,
      pendingCount: paroleeList.where((user) => !checkedToday.contains(user.id)).length,
      totalAttendance: attendanceCount,
      recentRecords: records.take(20).toList(),
      activityAttendanceStats: activityAttendanceStats,
      recentActivityRecords: activityAttendanceRecords.take(20).toList(),
      officerPerformance: _buildOfficerPerformance(users, records),
      generatedAt: DateTime.now(),
    );
  }

  List<ChartPoint> _buildWeeklyPoints(List<AttendanceRecord> records) {
    final now = DateTime.now();
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return List.generate(7, (index) {
      final day = DateTime(now.year, now.month, now.day - (6 - index));
      final count = records.where((record) =>
          record.checkInTime != null && AppDateUtils.isSameDay(record.checkInTime, day)).length;
      return ChartPoint(label: labels[day.weekday - 1], value: count.toDouble());
    });
  }

  List<ChartPoint> _buildMonthlyPoints(List<AttendanceRecord> records) {
    final now = DateTime.now();
    final format = DateFormat('MMM');
    return List.generate(12, (index) {
      final month = DateTime(now.year, now.month - (11 - index), 1);
      final count = records.where((record) {
        final date = record.checkInTime ?? record.scheduledTime;
        return date != null && date.year == month.year && date.month == month.month;
      }).length;
      return ChartPoint(label: format.format(month), value: count.toDouble());
    });
  }

  List<OfficerPerformance> _buildOfficerPerformance(
    List<AppUser> users,
    List<AttendanceRecord> records,
  ) =>
      users.where((user) => user.role == UserRole.officer).map((officer) {
        final officerRecords = records.where((record) => record.officerId == officer.id).toList();
        final missed = officerRecords.where((record) => record.status == AttendanceStatus.missed).length;
        final checkIns = officerRecords.where((record) =>
            record.status == AttendanceStatus.checkedIn ||
            record.status == AttendanceStatus.confirmed).length;
        final paroleeCount = users
            .where((user) => user.role == UserRole.parolee && user.officerId == officer.id)
            .length;
        return OfficerPerformance(
          officerId: officer.id,
          officerName: officer.fullName,
          totalParolees: paroleeCount,
          checkIns: checkIns,
          missed: missed,
          complianceRate: officerRecords.isEmpty
              ? 0
              : ((officerRecords.length - missed) / officerRecords.length) * 100,
        );
      }).toList();
}

ReportsService createReportsService() => SupabaseReportsService();
