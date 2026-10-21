import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/auth/models/app_user.dart';
import 'package:last/features/auth/models/user_role.dart';
import 'package:last/features/tracking/models/geofence.dart';
import 'package:last/features/tracking/models/gps_tracker.dart';
import 'package:last/features/tracking/models/location_record.dart';
import 'package:last/features/tracking/models/parolee_tracking_summary.dart';
import 'package:last/features/tracking/services/geofence_evaluation_service.dart';
import 'package:last/features/tracking/services/check_in_proximity_service.dart';
import 'package:last/features/tracking/services/tracking_status_service.dart';
import 'package:last/features/tracking/services/tracking_repository.dart';

class SupabaseTrackingRepository implements TrackingRepository {
  final SupabaseClient _supabase = SupabaseConfig.client;
  final GeofenceEvaluationService _geofenceEvaluator =
      GeofenceEvaluationService();
  final CheckInProximityService _checkInProximity = CheckInProximityService();
  final TrackingStatusService _trackingStatus = TrackingStatusService();

  @override
  Stream<List<ParoleeTrackingSummary>> watchAssignedParolees({
    required AppUser requester,
    required String officerId,
  }) {
    final controller = StreamController<List<ParoleeTrackingSummary>>();
    var currentProfiles = <Map<String, dynamic>>[];
    var visibleParoleeIds = <String>{};

    Future<void> emitCurrentProfiles() async {
      try {
        final summaries = await Future.wait(
          currentProfiles.map(
            (row) => _loadSummary(
              requester: requester,
              paroleeId: row['id'].toString(),
              profileRow: row,
            ),
          ),
        );
        controller.add(summaries);
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }
    }

    final profileSubscription = _supabase
        .from('profiles')
        .stream(primaryKey: ['id'])
        .eq('role', 'parolee')
        .listen((rows) {
          currentProfiles = rows;
          visibleParoleeIds = rows.map((row) => row['id'].toString()).toSet();
          unawaited(emitCurrentProfiles());
        }, onError: controller.addError);

    final locationChannel = _supabase
        .channel('public:assigned-location-logs:${requester.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'location_logs',
          callback: (payload) {
            final paroleeId = payload.newRecord['parolee_id']?.toString();
            if (paroleeId != null && visibleParoleeIds.contains(paroleeId)) {
              unawaited(emitCurrentProfiles());
            }
          },
        )
        .subscribe();
    final trackerChannel = _supabase
        .channel('public:assigned-gps-trackers:${requester.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'gps_trackers',
          callback: (_) => unawaited(emitCurrentProfiles()),
        )
        .subscribe();

    controller.onCancel = () async {
      await profileSubscription.cancel();
      await _supabase.removeChannel(locationChannel);
      await _supabase.removeChannel(trackerChannel);
    };

    return controller.stream;
  }

  @override
  Stream<ParoleeTrackingSummary> watchParoleeTracking({
    required AppUser requester,
    required String paroleeId,
  }) {
    final controller = StreamController<ParoleeTrackingSummary>();

    Future<void> emitSummary({Map<String, dynamic>? locationRow}) async {
      try {
        controller.add(
          await _loadSummary(
            requester: requester,
            paroleeId: paroleeId,
            locationRow: locationRow,
          ),
        );
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }
    }

    final channel = _supabase
        .channel('public:location_logs:$paroleeId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'location_logs',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'parolee_id',
            value: paroleeId,
          ),
          callback: (payload) {
            unawaited(emitSummary(locationRow: payload.newRecord));
          },
        )
        .subscribe();
    final trackerChannel = _supabase
        .channel('public:parolee-gps-tracker:$paroleeId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'gps_trackers',
          callback: (_) => unawaited(emitSummary()),
        )
        .subscribe();

    unawaited(emitSummary());

    controller.onCancel = () async {
      await _supabase.removeChannel(channel);
      await _supabase.removeChannel(trackerChannel);
    };

    return controller.stream;
  }

  @override
  Future<LocationRecord?> getLatestLocation({
    required AppUser requester,
    required String paroleeId,
  }) async {
    final rows = await _supabase
        .from('location_logs')
        .select()
        .eq('parolee_id', paroleeId)
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    return LocationRecord.fromMap(Map<String, dynamic>.from(rows.first));
  }

  @override
  Future<List<LocationRecord>> getLocationHistory({
    required AppUser requester,
    required String paroleeId,
    DateTime? start,
    DateTime? end,
    int limit = 50,
    String? startAfterId,
  }) async {
    var query = _supabase
        .from('location_logs')
        .select()
        .eq('parolee_id', paroleeId);
    if (start != null) {
      query = query.gte('created_at', start.toIso8601String());
    }
    if (end != null) {
      query = query.lte('created_at', end.toIso8601String());
    }
    if (startAfterId != null && startAfterId.isNotEmpty) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(startAfterId)) {
        throw const FormatException('Invalid location-history cursor.');
      }
      final cursor = await _supabase
          .from('location_logs')
          .select('created_at')
          .eq('parolee_id', paroleeId)
          .eq('id', startAfterId)
          .maybeSingle();
      final cursorTimeRaw = cursor?['created_at']?.toString();
      if (cursorTimeRaw == null) return [];
      final cursorTime = DateTime.parse(
        cursorTimeRaw,
      ).toUtc().toIso8601String();
      query = query.or(
        'created_at.lt.$cursorTime,'
        'and(created_at.eq.$cursorTime,id.lt.$startAfterId)',
      );
    }
    final rows = await query
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(limit);
    return rows
        .map((row) => LocationRecord.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  @override
  Future<GpsTracker?> getTrackerForParolee(String paroleeId) async {
    final row = await _supabase
        .from('gps_trackers')
        .select()
        .eq('parolee_id', paroleeId)
        .limit(1)
        .maybeSingle();
    if (row == null) return null;
    return GpsTracker.fromMap(Map<String, dynamic>.from(row));
  }

  @override
  Future<List<Geofence>> getGeofencesForParolee(String paroleeId) async {
    final rows = await _supabase
        .from('geofences')
        .select()
        .eq('parolee_id', paroleeId);
    return rows
        .map((row) => Geofence.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  @override
  Future<void> submitLocation({
    required String trackerId,
    required String deviceToken,
    required LocationRecord location,
  }) async {
    throw UnsupportedError(
      'Direct tracker uploads are disabled until device-token validation is '
      'implemented. Use authenticated phone location sharing instead.',
    );
  }

  @override
  void dispose() {}

  Future<ParoleeTrackingSummary> _loadSummary({
    required AppUser requester,
    required String paroleeId,
    Map<String, dynamic>? profileRow,
    Map<String, dynamic>? locationRow,
  }) async {
    final profile =
        profileRow ??
        await _supabase
            .from('profiles')
            .select('id, full_name, case_number, officer_id')
            .eq('id', paroleeId)
            .maybeSingle();
    if (profile == null) {
      throw StateError('No visible profile found for parolee $paroleeId.');
    }

    final location = locationRow == null
        ? await getLatestLocation(requester: requester, paroleeId: paroleeId)
        : LocationRecord.fromMap(locationRow);
    final tracker = await getTrackerForParolee(paroleeId);
    final geofences = await getGeofencesForParolee(paroleeId);
    final isAuthorized = switch (requester.role) {
      UserRole.officer => profile['officer_id']?.toString() == requester.id,
      UserRole.parolee => requester.id == paroleeId,
    };

    return ParoleeTrackingSummary(
      paroleeId: paroleeId,
      fullName: profile['full_name']?.toString() ?? '',
      caseNumber: profile['case_number']?.toString() ?? '',
      officerId: profile['officer_id']?.toString() ?? '',
      trackingStatus: _trackingStatus.resolve(latestLocation: location),
      tracker: tracker,
      latestLocation: location,
      geofences: geofences,
      geofenceStatus: _geofenceEvaluator.evaluate(
        location: location,
        geofences: geofences,
      ),
      checkInProximity: _checkInProximity.evaluate(
        isAuthorized: isAuthorized,
        tracker: tracker,
        location: location,
        geofences: geofences,
      ),
    );
  }
}
