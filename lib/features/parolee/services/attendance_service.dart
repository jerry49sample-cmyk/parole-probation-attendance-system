import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/shared/models/attendance_record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class AttendanceService {
  Stream<List<AttendanceRecord>> watchAttendance({
    String? officerId,
    String? paroleeId,
  });
  Future<List<AttendanceRecord>> getAttendance({
    String? officerId,
    String? paroleeId,
  });
  Future<void> updateStatus(String id, AttendanceStatus status);
}

class SupabaseAttendanceService implements AttendanceService {
  final SupabaseClient _db = SupabaseConfig.client;

  @override
  Stream<List<AttendanceRecord>> watchAttendance({
    String? officerId,
    String? paroleeId,
  }) => _db
      .from('attendance_records')
      .stream(primaryKey: ['id'])
      .map(
        (rows) => _mapRows(rows)
            .where(
              (record) =>
                  (officerId == null || record.officerId == officerId) &&
                  (paroleeId == null || record.paroleeId == paroleeId),
            )
            .toList(),
      );

  @override
  Future<List<AttendanceRecord>> getAttendance({
    String? officerId,
    String? paroleeId,
  }) async {
    var query = _db.from('attendance_records').select();
    if (officerId != null && officerId.isNotEmpty)
      query = query.eq('officer_id', officerId);
    if (paroleeId != null && paroleeId.isNotEmpty)
      query = query.eq('parolee_id', paroleeId);
    final rows = await query.order('check_in_time', ascending: false);
    return _mapRows(List<Map<String, dynamic>>.from(rows));
  }

  @override
  Future<void> updateStatus(String id, AttendanceStatus status) async {
    await _db
        .from('attendance_records')
        .update({'status': status.name})
        .eq('id', id);
  }

  List<AttendanceRecord> _mapRows(List<Map<String, dynamic>> rows) {
    final records = rows.map(AttendanceRecord.fromMap).toList()
      ..sort(
        (a, b) => (b.checkInTime ?? DateTime(2000)).compareTo(
          a.checkInTime ?? DateTime(2000),
        ),
      );
    return records;
  }
}

AttendanceService createAttendanceService() => SupabaseAttendanceService();
