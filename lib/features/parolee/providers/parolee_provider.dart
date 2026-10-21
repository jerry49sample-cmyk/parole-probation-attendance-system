import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/auth/models/app_user.dart';
import 'package:last/features/parolee/services/schedule_service.dart';
import 'package:last/features/shared/models/attendance_record.dart';
import 'package:last/features/shared/models/schedule_model.dart';

class ParoleeProvider extends ChangeNotifier {
  ParoleeProvider({
    ScheduleService? scheduleService,
  }) : _scheduleService = scheduleService ?? ScheduleService();

  final ScheduleService _scheduleService;

  List<ScheduleModel> _schedules = [];
  ScheduleModel? _nextSchedule;
  AppUser? _assignedOfficer;
  double _complianceRate = 0;
  bool _loading = false;
  String? _error;
  StreamSubscription<List<ScheduleModel>>? _scheduleSub;

  List<ScheduleModel> get schedules => _schedules;
  ScheduleModel? get nextSchedule => _nextSchedule;
  AppUser? get assignedOfficer => _assignedOfficer;
  double get complianceRate => _complianceRate;
  bool get isLoading => _loading;
  String? get error => _error;

  void startListening({
    required String paroleeId,
    String? officerId,
    required List<AttendanceRecord> attendanceRecords,
  }) {
    _scheduleSub?.cancel();
    _loading = true;
    notifyListeners();

    _scheduleSub = _scheduleService.watchForParolee(paroleeId).listen(
      (list) async {
        _schedules = list;
        final now = DateTime.now();
        final upcoming = list.where((s) => s.scheduledAt.isAfter(now)).toList()
          ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
        _nextSchedule = upcoming.isEmpty ? null : upcoming.first;
        _complianceRate = _computeCompliance(attendanceRecords);
        _assignedOfficer = null;
        if (officerId != null && officerId.isNotEmpty) {
          _assignedOfficer = await _loadAssignedOfficer(officerId);
        }
        _loading = false;
        _error = null;
        notifyListeners();
      },
      onError: (_) {
        _error = 'Failed to load schedule';
        _loading = false;
        notifyListeners();
      },
    );
  }

  Future<AppUser?> _loadAssignedOfficer(String officerId) async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      final row = await SupabaseConfig.client
          .from('profiles')
          .select()
          .eq('id', officerId)
          .maybeSingle();
      if (row == null) return null;

      return AppUser.fromMap({
        'id': row['id']?.toString() ?? officerId,
        'email': row['email']?.toString() ?? '',
        'fullName': (row['full_name'] ?? row['fullName'])?.toString() ?? '',
        'role': row['role']?.toString() ?? 'officer',
        'department': row['department']?.toString(),
        'caseNumber': (row['case_number'] ?? row['caseNumber'])?.toString(),
        'officerId': (row['officer_id'] ?? row['officerId'])?.toString(),
        'trackerId': (row['tracker_id'] ?? row['trackerId'])?.toString(),
        'phone': row['phone']?.toString(),
        'isActive': row['is_active'] == null ? true : row['is_active'] == true,
        'supervisionStartDate':
            (row['supervision_start_date'] ?? row['supervisionStartDate'])?.toString(),
        'supervisionEndDate':
            (row['supervision_end_date'] ?? row['supervisionEndDate'])?.toString(),
        'supervisionIsSuspended':
            row['supervision_is_suspended'] == true ||
                row['supervisionIsSuspended'] == true,
      });
    } catch (_) {
      return null;
    }
  }

  void updateCompliance(List<AttendanceRecord> records) {
    _complianceRate = _computeCompliance(records);
    notifyListeners();
  }

  double _computeCompliance(List<AttendanceRecord> records) {
    if (records.isEmpty) return 0;
    final onTime = records.where((r) => r.status != AttendanceStatus.missed).length;
    return (onTime / records.length) * 100;
  }

  @override
  void dispose() {
    _scheduleSub?.cancel();
    super.dispose();
  }
}
