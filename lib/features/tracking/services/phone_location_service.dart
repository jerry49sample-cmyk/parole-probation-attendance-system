import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:last/core/constants/tracking_config.dart';
import 'package:last/core/utils/app_logger.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PhoneLocationException implements Exception {
  PhoneLocationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Foreground GPS sharing from the signed-in parolee's phone into Supabase.
class PhoneLocationService {
  PhoneLocationService._();
  static final PhoneLocationService instance = PhoneLocationService._();

  SupabaseClient get _supabase => SupabaseConfig.client;
  Timer? _timer;
  String? _paroleeId;
  DateTime? lastSentAt;
  String? lastError;
  void Function()? onUpdate;
  Position? _lastPosition;

  bool get isSharing => _timer != null && _paroleeId != null;

  Future<void> start(String paroleeId) async {
    if (!SupabaseConfig.isConfigured) {
      throw PhoneLocationException('Supabase is not configured.');
    }
    final uid = _supabase.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) {
      throw PhoneLocationException(
        'Sign in with your Supabase account to share location.',
      );
    }
    if (paroleeId != uid) {
      throw PhoneLocationException(
        'You can only share location for your own account.',
      );
    }

    await _ensurePermission();
    _paroleeId = uid;
    lastError = null;
    _timer?.cancel();
    await _publish();
    _timer = Timer.periodic(const Duration(seconds: 45), (_) async {
      try {
        lastError = null;
        await _publish();
      } catch (e, st) {
        lastError = e.toString();
        AppLogger.e('PhoneLocationService', 'Periodic publish failed', e, st);
      }
      onUpdate?.call();
    });
    onUpdate?.call();
    AppLogger.d('PhoneLocationService', 'Sharing started', uid);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _paroleeId = null;
    AppLogger.d('PhoneLocationService', 'Sharing stopped');
    onUpdate?.call();
  }

  Future<void> _ensurePermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw PhoneLocationException(
        'Turn on location services, then try again.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw PhoneLocationException('Location permission was denied.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw PhoneLocationException(
        'Location permission is blocked. Enable it in system settings.',
      );
    }
  }

  Future<void> _publish() async {
    final uid = _paroleeId;
    if (uid == null) {
      stop();
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );

      if (pos.latitude.abs() < 0.0001 && pos.longitude.abs() < 0.0001) {
        throw PhoneLocationException('GPS does not have a valid fix yet.');
      }

      final now = DateTime.now();
      if (_lastPosition != null &&
          lastSentAt != null &&
          now.difference(lastSentAt!) <
              TrackingConfig.duplicateLocationWindow) {
        final d = Geolocator.distanceBetween(
          _lastPosition!.latitude,
          _lastPosition!.longitude,
          pos.latitude,
          pos.longitude,
        );
        if (d < 8) return;
      }

      await _supabase.from('location_logs').insert({
        'tracker_id': 'phone_$uid',
        'parolee_id': uid,
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        'accuracy': pos.accuracy,
        'speed': pos.speed.isNaN ? 0.0 : pos.speed,
      });
      _lastPosition = pos;
      lastSentAt = now;
      AppLogger.d(
        'PhoneLocationService',
        'Location saved',
        '$uid ${pos.latitude}',
      );
    } on PhoneLocationException {
      rethrow;
    } on TimeoutException {
      throw PhoneLocationException('Timed out waiting for GPS. Try outdoors.');
    } on PostgrestException catch (e) {
      throw PhoneLocationException(e.message);
    } catch (e) {
      throw PhoneLocationException(
        e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }
}
