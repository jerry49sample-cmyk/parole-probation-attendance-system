import 'package:flutter_test/flutter_test.dart';
import 'package:last/features/tracking/models/gps_tracker.dart';

void main() {
  test('keeps a shared assignment visible without exposing its parolee', () {
    final tracker = GpsTracker.fromMap({
      'id': 'tracker-1',
      'device_id': 'device-1',
      'parolee_id': null,
      'parolee_name': null,
      'has_hidden_assignment': true,
    });

    expect(tracker.hasHiddenAssignment, isTrue);
    expect(tracker.isAssigned, isTrue);
    expect(tracker.paroleeId, isNull);
    expect(tracker.paroleeName, isNull);
  });
}
