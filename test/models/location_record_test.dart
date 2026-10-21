import 'package:flutter_test/flutter_test.dart';
import 'package:last/features/tracking/models/location_record.dart';

void main() {
  group('LocationRecord', () {
    test('parses numeric database IDs and canonical location columns', () {
      final location = LocationRecord.fromMap({
        'id': 84,
        'tracker_id': 'phone_user-1',
        'parolee_id': 'user-1',
        'latitude': 11.24,
        'longitude': 125.0,
        'accuracy': 6.5,
        'created_at': '2026-10-19T04:00:00Z',
      });

      expect(location.id, '84');
      expect(location.trackerId, 'phone_user-1');
      expect(location.paroleeId, 'user-1');
      expect(location.latitude, 11.24);
      expect(location.longitude, 125.0);
      expect(location.recordedAt, DateTime.utc(2026, 10, 19, 4));
    });
  });
}
