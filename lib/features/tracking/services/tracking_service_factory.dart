import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/tracking/services/supabase_tracking_repository.dart';
import 'package:last/features/tracking/services/tracking_repository.dart';

TrackingRepository createTrackingRepository() {
  if (!SupabaseConfig.isConfigured) {
    throw StateError('Supabase must be configured to load live tracking data.');
  }
  return SupabaseTrackingRepository();
}
