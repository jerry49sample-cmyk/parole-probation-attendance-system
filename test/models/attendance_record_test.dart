import 'package:flutter_test/flutter_test.dart';
import 'package:last/features/shared/models/attendance_record.dart';

void main() {
  group('AttendanceRecord', () {
    test('parses a numeric database id as a string', () {
      final record = AttendanceRecord.fromMap({
        'id': 42,
        'ticket_id': 'TKT-42',
        'parolee_id': 'parolee-1',
        'parolee_name': 'Jordan Lee',
        'officer_id': 'officer-1',
        'status': 'checkedIn',
      });

      expect(record.id, '42');
      expect(record.ticketId, 'TKT-42');
      expect(record.paroleeName, 'Jordan Lee');
    });
  });
}
