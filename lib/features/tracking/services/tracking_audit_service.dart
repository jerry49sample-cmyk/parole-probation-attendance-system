import 'package:last/core/constants/tracking_config.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TrackingAuditService {
  final SupabaseClient _db = SupabaseConfig.client;

  Future<void> logDeviceAssignment({
    required String action,
    required String trackerId,
    String? paroleeId,
    String? actorId,
    String? actorRole,
    Map<String, dynamic>? metadata,
  }) => _log(
    action: action,
    resourceType: 'device',
    resourceId: trackerId,
    paroleeId: paroleeId,
    actorId: actorId,
    actorRole: actorRole,
    metadata: metadata,
  );

  Future<void> logSupervisionPeriodUpdated({
    required String paroleeId,
    required String actorId,
    required String actorRole,
    Map<String, dynamic>? metadata,
  }) => _log(
    action: 'supervision_period_updated',
    resourceType: 'parolee',
    resourceId: paroleeId,
    paroleeId: paroleeId,
    actorId: actorId,
    actorRole: actorRole,
    metadata: metadata,
  );

  Future<void> logTrackingAccess({
    required String paroleeId,
    required String actorId,
    required String actorRole,
    required String endpoint,
  }) => _log(
    action: 'tracking_access',
    resourceType: 'parolee',
    resourceId: paroleeId,
    paroleeId: paroleeId,
    actorId: actorId,
    actorRole: actorRole,
    metadata: {'endpoint': endpoint},
  );

  Future<void> _log({
    required String action,
    required String resourceType,
    required String resourceId,
    String? paroleeId,
    String? actorId,
    String? actorRole,
    Map<String, dynamic>? metadata,
  }) async {
    await _db.from('tracking_audit_logs').insert({
      'action': action,
      'resource_type': resourceType,
      'resource_id': resourceId,
      'parolee_id': paroleeId,
      'actor_id': actorId,
      'actor_role': actorRole,
      'metadata': metadata ?? <String, dynamic>{},
    });
  }
}

class TrackingAlertCooldownService {
  TrackingAlertCooldownService({SupabaseClient? client})
    : _db = client ?? SupabaseConfig.client;

  final SupabaseClient _db;

  Future<bool> shouldSendAlert({
    required String alertType,
    required String trackerId,
    String? paroleeId,
    Duration? cooldown,
  }) async {
    final duration =
        cooldown ?? Duration(minutes: TrackingConfig.alertCooldownMinutes);
    if (duration.isNegative || duration > const Duration(days: 7)) {
      throw ArgumentError.value(
        duration,
        'cooldown',
        'Must be between zero and seven days.',
      );
    }

    final result = await _db.rpc(
      'ppa_should_send_tracking_alert',
      params: {
        'p_alert_type': alertType,
        'p_tracker_id': trackerId,
        'p_cooldown_seconds': duration.inSeconds,
      },
    );
    if (result is! bool) {
      throw StateError('Supabase returned an invalid tracking alert cooldown result.');
    }
    return result;
  }
}

TrackingAuditService createTrackingAuditService() => TrackingAuditService();

TrackingAlertCooldownService createTrackingAlertCooldownService() =>
    TrackingAlertCooldownService();
