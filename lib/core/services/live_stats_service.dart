import 'package:last/features/officer/models/live_stats.dart';
import 'package:last/features/officer/models/parolee_summary.dart';
import 'package:last/features/shared/models/attendance_record.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LiveStatsService {
  final SupabaseClient _db = SupabaseConfig.client;

  Future<void> publish(String officerId, List<ParoleeSummary> parolees) async {
    if (officerId.isEmpty) return;
    final stats = LiveStats.fromDashboard(parolees);
    await _db.from('live_stats').upsert({
      'officer_id': officerId,
      ...stats.toMap(),
    }, onConflict: 'officer_id');
  }

  Future<void> syncParoleeStatus({
    required String paroleeId,
    required AttendanceStatus status,
  }) async {
    if (paroleeId.isEmpty) return;
    await _db.from('profiles').update({
      'today_status': status.name,
      'status_updated_at': DateTime.now().toIso8601String(),
    }).eq('id', paroleeId);
  }

  Stream<LiveStats?> watchOfficer(String officerId) => _db
      .from('live_stats')
      .stream(primaryKey: ['officer_id'])
      .eq('officer_id', officerId)
      .map((rows) => rows.isEmpty ? null : LiveStats.fromMap(rows.first));

  Stream<List<LiveStats>> watchAll() => _db
      .from('live_stats')
      .stream(primaryKey: ['officer_id'])
      .map((rows) => rows.map(LiveStats.fromMap).toList());
}
