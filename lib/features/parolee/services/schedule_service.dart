import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/shared/models/schedule_model.dart';

class ScheduleService {
  ScheduleService({SupabaseClient? supabase}) : _supabaseOverride = supabase;

  final SupabaseClient? _supabaseOverride;

  SupabaseClient get _supabase => _supabaseOverride ?? SupabaseConfig.client;

  Stream<List<ScheduleModel>> watchForParolee(String paroleeId) =>
      _watchFor('parolee_id', paroleeId);

  Stream<List<ScheduleModel>> watchForOfficer(String officerId) =>
      _watchFor('officer_id', officerId);

  Future<ScheduleModel?> getNextForParolee(String paroleeId) async {
    final list = await watchForParolee(paroleeId).first;
    final now = DateTime.now();
    final upcoming = list.where((s) => s.scheduledAt.isAfter(now)).toList()
      ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    return upcoming.isEmpty ? null : upcoming.first;
  }

  Stream<List<ScheduleModel>> _watchFor(String column, String id) {
    if (!SupabaseConfig.isConfigured || id.isEmpty) {
      return Stream.value(<ScheduleModel>[]);
    }

    return _supabase
        .from('schedules')
        .stream(primaryKey: ['id'])
        .eq(column, id)
        .map(_mapSchedules);
  }

  List<ScheduleModel> _mapSchedules(List<Map<String, dynamic>> rows) {
    final schedules = <ScheduleModel>[];
    for (final row in rows) {
      final scheduledAt = DateTime.tryParse(
        (row['scheduled_at'] ?? row['scheduledAt'])?.toString() ?? '',
      );
      if (scheduledAt == null) continue;

      schedules.add(ScheduleModel(
        id: row['id']?.toString() ?? '',
        paroleeId: (row['parolee_id'] ?? row['paroleeId'])?.toString() ?? '',
        paroleeName: (row['parolee_name'] ?? row['paroleeName'])?.toString() ?? '',
        officerId: (row['officer_id'] ?? row['officerId'])?.toString() ?? '',
        scheduledAt: scheduledAt,
        location: row['location']?.toString() ?? '',
        type: (row['type'] ?? row['schedule_type'])?.toString() ?? 'Check-in',
        notes: row['notes']?.toString(),
      ));
    }
    schedules.sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    return schedules;
  }
}
