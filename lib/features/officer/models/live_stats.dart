import 'package:last/features/officer/models/dashboard_stats.dart';
import 'package:last/features/officer/models/parolee_summary.dart';
import 'package:last/features/shared/models/attendance_record.dart';

class LiveStats {
  const LiveStats({
    required this.stats,
    required this.checkedIn,
    required this.pending,
    required this.missed,
    required this.updatedAt,
  });

  final DashboardStats stats;
  final List<ParoleeSummary> checkedIn;
  final List<ParoleeSummary> pending;
  final List<ParoleeSummary> missed;
  final DateTime? updatedAt;

  factory LiveStats.fromDashboard(List<ParoleeSummary> all, {DateTime? updatedAt}) {
    final checkedIn = all
        .where((p) =>
            p.status == AttendanceStatus.checkedIn ||
            p.status == AttendanceStatus.confirmed)
        .toList();
    final pending = all.where((p) => p.status == AttendanceStatus.pending).toList();
    final missed = all.where((p) => p.status == AttendanceStatus.missed).toList();
    return LiveStats(
      stats: DashboardStats(
        totalCases: all.length,
        checkedIn: checkedIn.length,
        pending: pending.length,
        missed: missed.length,
      ),
      checkedIn: checkedIn,
      pending: pending,
      missed: missed,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  factory LiveStats.fromMap(Map<String, dynamic> map) {
    List<ParoleeSummary> parseList(String key) {
      final raw = map[key] as List<dynamic>? ?? [];
      return raw.map((e) {
        final m = e as Map<String, dynamic>;
        return ParoleeSummary(
          id: m['id']?.toString() ?? '',
          fullName: m['full_name'] as String? ?? m['fullName'] as String? ?? '',
          caseNumber: m['case_number'] as String? ?? m['caseNumber'] as String? ?? '',
          status: AttendanceStatus.fromString(m['status'] as String? ?? 'pending'),
          officerId: m['officer_id']?.toString() ?? m['officerId']?.toString() ?? '',
        );
      }).toList();
    }

    return LiveStats(
      stats: DashboardStats(
        totalCases: (map['total_cases'] ?? map['totalCases'] as num?)?.toInt() ?? 0,
        checkedIn: (map['checked_in'] ?? map['checkedIn'] as num?)?.toInt() ?? 0,
        pending: (map['pending'] as num?)?.toInt() ?? 0,
        missed: (map['missed'] as num?)?.toInt() ?? 0,
      ),
      checkedIn: parseList('checked_in_list'),
      pending: parseList('pending_list'),
      missed: parseList('missed_list'),
      updatedAt: _parseDate(map['updated_at'] ?? map['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() => {
        'total_cases': stats.totalCases,
        'checked_in': stats.checkedIn,
        'pending': stats.pending,
        'missed': stats.missed,
        'updated_at': (updatedAt ?? DateTime.now()).toIso8601String(),
        'checked_in_list': _serialize(checkedIn),
        'pending_list': _serialize(pending),
        'missed_list': _serialize(missed),
      };

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }

  static List<Map<String, dynamic>> _serialize(List<ParoleeSummary> list) {
    return list
        .map((p) => {
              'id': p.id,
              'fullName': p.fullName,
              'caseNumber': p.caseNumber,
              'status': p.status.name,
              'officerId': p.officerId,
            })
        .toList();
  }
}
