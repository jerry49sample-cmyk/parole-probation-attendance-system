import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/auth/models/officer_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OfficerProfileService {
  OfficerProfileService({SupabaseClient? client}) : _db = client ?? SupabaseConfig.client;

  final SupabaseClient _db;

  Future<OfficerProfile?> getById(String officerId) async {
    if (officerId.isEmpty) return null;
    final row = await _db.from('profiles').select().eq('id', officerId).maybeSingle();
    return row == null ? null : OfficerProfile.fromMap(officerId, row);
  }

  Stream<OfficerProfile?> watchById(String officerId) {
    if (officerId.isEmpty) return Stream.value(null);
    return _db
        .from('profiles')
        .stream(primaryKey: ['id'])
        .eq('id', officerId)
        .map((rows) => rows.isEmpty ? null : OfficerProfile.fromMap(officerId, rows.first));
  }
}
