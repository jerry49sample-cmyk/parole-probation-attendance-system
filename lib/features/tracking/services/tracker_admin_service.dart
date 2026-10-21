import 'package:last/core/constants/tracking_config.dart';
import 'package:last/core/utils/error_handler.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/tracking/models/geofence.dart';
import 'package:last/features/tracking/models/gps_tracker.dart';
import 'package:last/features/tracking/models/location_record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

abstract class TrackerAdminService {
  Stream<List<GpsTracker>> watchAllTrackers();
  Future<List<GpsTracker>> getAllTrackers();
  Future<GpsTracker?> getTrackerById(String trackerId);
  Future<GpsTracker> createTracker({
    required String trackerId,
    required String deviceIdentifier,
  });
  Future<void> assignTracker({
    required String trackerId,
    required String paroleeId,
  });
  Future<void> unassignTracker(String trackerId);
  Future<void> updateTrackerStatus(
    String trackerId,
    TrackerDeviceStatus status,
  );
  Future<List<LocationRecord>> getDeviceLocationLogs(
    String trackerId, {
    int limit = 50,
  });
  Future<void> assignGeofence({
    required String paroleeId,
    required String name,
    required double centerLat,
    required double centerLng,
    double radiusMeters = TrackingConfig.defaultGeofenceRadiusMeters,
  });
  Future<List<Geofence>> getGeofencesForParolee(String paroleeId);
}

class SupabaseTrackerAdminService implements TrackerAdminService {
  SupabaseTrackerAdminService({SupabaseClient? client})
    : _db = client ?? SupabaseConfig.client;

  final SupabaseClient _db;

  @override
  Stream<List<GpsTracker>> watchAllTrackers() async* {
    yield await getAllTrackers();
    yield* Stream.periodic(
      const Duration(seconds: 30),
    ).asyncMap((_) => getAllTrackers());
  }

  @override
  Future<List<GpsTracker>> getAllTrackers() async {
    try {
      return await _loadSharedTrackers();
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to load trackers');
    }
  }

  @override
  Future<GpsTracker?> getTrackerById(String trackerId) async {
    try {
      final trackers = await _loadSharedTrackers();
      for (final tracker in trackers) {
        if (tracker.id == trackerId) return tracker;
      }
      return null;
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to load tracker');
    }
  }

  @override
  Future<GpsTracker> createTracker({
    required String trackerId,
    required String deviceIdentifier,
  }) async {
    final id = trackerId.trim();
    final deviceId = deviceIdentifier.trim();
    if (id.isEmpty || deviceId.isEmpty) {
      throw ArgumentError('Tracker ID and device identifier are required.');
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(deviceId)) {
      throw ArgumentError(
        'Device identifier must be 1–128 letters, numbers, dots, underscores, colons, or hyphens.',
      );
    }

    try {
      final row = await _db
          .from('gps_trackers')
          .insert({'id': id, 'device_id': deviceId})
          .select()
          .single();
      return GpsTracker.fromMap(row);
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to create tracker');
    }
  }

  @override
  Future<void> assignTracker({
    required String trackerId,
    required String paroleeId,
  }) async {
    try {
      await _db.rpc(
        'ppa_assign_tracker',
        params: {'p_tracker_id': trackerId, 'p_parolee_id': paroleeId},
      );
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to assign tracker');
    }
  }

  @override
  Future<void> unassignTracker(String trackerId) async {
    try {
      await _db.rpc(
        'ppa_unassign_tracker',
        params: {'p_tracker_id': trackerId},
      );
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to unassign tracker');
    }
  }

  @override
  Future<void> updateTrackerStatus(
    String trackerId,
    TrackerDeviceStatus status,
  ) async {
    try {
      await _db.rpc(
        'ppa_update_tracker_status',
        params: {'p_tracker_id': trackerId, 'p_status': status.name},
      );
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to update tracker status');
    }
  }

  @override
  Future<List<LocationRecord>> getDeviceLocationLogs(
    String trackerId, {
    int limit = 50,
  }) async {
    try {
      final rows = await _db
          .from('location_logs')
          .select()
          .eq('tracker_id', trackerId)
          .order('created_at', ascending: false)
          .limit(limit);
      return rows.map((row) => LocationRecord.fromMap(row)).toList();
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to load tracker location logs');
    }
  }

  @override
  Future<void> assignGeofence({
    required String paroleeId,
    required String name,
    required double centerLat,
    required double centerLng,
    double radiusMeters = TrackingConfig.defaultGeofenceRadiusMeters,
  }) async {
    try {
      await _db.from('geofences').insert({
        'id': const Uuid().v4(),
        'parolee_id': paroleeId,
        'name': name,
        'latitude': centerLat,
        'longitude': centerLng,
        'radius_meters': radiusMeters,
      });
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to assign geofence');
    }
  }

  @override
  Future<List<Geofence>> getGeofencesForParolee(String paroleeId) async {
    try {
      final rows = await _db
          .from('geofences')
          .select()
          .eq('parolee_id', paroleeId);
      return rows.map((row) => Geofence.fromMap(row)).toList();
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to load geofences');
    }
  }

  Future<List<GpsTracker>> _loadSharedTrackers() async {
    final rows = await _db.rpc('ppa_list_shared_trackers');
    final trackers =
        (rows as List)
            .map(
              (row) =>
                  GpsTracker.fromMap(Map<String, dynamic>.from(row as Map)),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return trackers;
  }
}

TrackerAdminService createTrackerAdminService() =>
    SupabaseTrackerAdminService();
