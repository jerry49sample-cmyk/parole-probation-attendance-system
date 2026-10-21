import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/activities/models/activity_model.dart';
import 'package:last/features/activities/models/activity_qr_payload.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ActivityQrException implements Exception {
  ActivityQrException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ActivityQrService {
  final SupabaseClient _db = SupabaseConfig.client;

  Future<ActivityQrPayload> generateForActivity({
    required ActivityModel activity,
    required String paroleeId,
    bool rotate = false,
  }) async {
    final signedInId = _db.auth.currentUser?.id;
    if (signedInId == null || signedInId.isEmpty) {
      throw ActivityQrException('You are not signed in. Sign in again to view your QR code.');
    }
    if (paroleeId != signedInId) {
      throw ActivityQrException('This QR can only be generated for the signed-in parolee account.');
    }
    if (!activity.isAssignedTo(signedInId)) {
      throw ActivityQrException('You are not assigned to this activity.');
    }
    if (activity.status == ActivityStatus.missed || activity.status == ActivityStatus.completed) {
      throw ActivityQrException('This activity is no longer available for check-in.');
    }

    final result = await _db.rpc(
      'ppa_issue_activity_qr',
      params: {
        'p_activity_id': activity.id,
        'p_rotate': rotate,
      },
    );
    if (result is! Map) {
      throw ActivityQrException('The server returned an invalid activity QR ticket.');
    }
    return _payloadFromRow(Map<String, dynamic>.from(result));
  }

  ActivityQrPayload _payloadFromRow(Map<String, dynamic> row) => ActivityQrPayload(
        paroleeId: row['parolee_id']?.toString() ?? '',
        paroleeName: row['parolee_name']?.toString() ?? '',
        activityId: row['activity_id']?.toString() ?? '',
        assignedOfficerId: row['officer_id']?.toString() ?? '',
        activityTitle: row['activity_title']?.toString() ?? '',
        token: row['token']?.toString() ?? '',
        timestamp: DateTime.tryParse(row['issued_at']?.toString() ?? '') ?? DateTime.now(),
      );
}
