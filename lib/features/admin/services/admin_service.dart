import 'package:last/core/utils/error_handler.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/auth/models/app_user.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

abstract class AdminService {
  Stream<List<AppUser>> watchAllUsers();
  Future<List<AppUser>> getAllUsers();
  Future<List<AppUser>> getUnassignedParolees();
  Future<void> assignParoleeToSelf(String paroleeId);
  Future<void> assignOfficer(String paroleeId, String officerId);
  Future<void> removeOfficer(String paroleeId);
  Future<void> toggleUserActive(String userId, bool active);
  Future<void> createUser(AppUser user);
  Future<void> deleteUser(String userId);
  Future<double> computeComplianceRate();
  Stream<double> watchComplianceRate();
}

class SupabaseAdminService implements AdminService {
  final SupabaseClient _db = SupabaseConfig.client;

  @override
  Stream<List<AppUser>> watchAllUsers() => _db
      .from('profiles')
      .stream(primaryKey: ['id'])
      .map((rows) => rows.map(AppUser.fromMap).toList());

  @override
  Future<List<AppUser>> getAllUsers() async {
    try {
      final rows = await _db.from('profiles').select().order('full_name');
      return rows.map((row) => AppUser.fromMap(row)).toList();
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to load users');
    }
  }

  @override
  Future<List<AppUser>> getUnassignedParolees() async {
    try {
      final rows =
          await _db.rpc('ppa_list_unassigned_parolees') as List<dynamic>;
      return rows
          .map((row) => AppUser.fromMap(Map<String, dynamic>.from(row as Map)))
          .toList();
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to load unassigned parolees');
    }
  }

  @override
  Future<void> assignParoleeToSelf(String paroleeId) async {
    try {
      await _db.rpc(
        'ppa_assign_parolee_to_self',
        params: {'target_parolee_id': paroleeId},
      );
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to assign parolee');
    }
  }

  @override
  Future<void> assignOfficer(String paroleeId, String officerId) async {
    try {
      await _db
          .from('profiles')
          .update({'officer_id': officerId})
          .eq('id', paroleeId);
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to assign officer');
    }
  }

  @override
  Future<void> removeOfficer(String paroleeId) async {
    try {
      await _db
          .from('profiles')
          .update({'officer_id': null})
          .eq('id', paroleeId);
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to remove officer assignment');
    }
  }

  @override
  Future<void> toggleUserActive(String userId, bool active) async {
    try {
      await _db.from('profiles').update({'is_active': active}).eq('id', userId);
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to update user status');
    }
  }

  @override
  Future<void> createUser(AppUser user) async {
    try {
      // Supabase Auth accounts must be provisioned through Auth or a trusted
      // server function. This writes the profile for an existing auth user.
      final profile = user.toProfileMap()
        ..remove('id')
        ..remove('role')
        ..remove('email');
      final updated = await _db
          .from('profiles')
          .update(profile)
          .eq('id', user.id)
          .select('id')
          .maybeSingle();
      if (updated == null) {
        throw StateError('The profile does not exist for this auth user.');
      }
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to create user profile');
    }
  }

  @override
  Future<void> deleteUser(String userId) async {
    try {
      // Keep the auth identity and history; disabling the profile prevents access.
      await toggleUserActive(userId, false);
      await _db
          .from('gps_trackers')
          .update({
            'parolee_id': null,
            'parolee_name': null,
            'status': 'unassigned',
          })
          .eq('parolee_id', userId);
    } catch (error) {
      throw ErrorHandler.wrap(error, 'Failed to deactivate user');
    }
  }

  @override
  Future<double> computeComplianceRate() async {
    final rows = await _db
        .from('attendance_records')
        .select('status,check_in_time,created_at');
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final recent = rows.where((row) {
      final timestamp = row['check_in_time'] ?? row['created_at'];
      final date = DateTime.tryParse(timestamp?.toString() ?? '');
      return date != null && date.isAfter(cutoff);
    }).toList();
    if (recent.isEmpty) return 0;
    final compliant = recent.where((row) => row['status'] != 'missed').length;
    return compliant * 100 / recent.length;
  }

  @override
  Stream<double> watchComplianceRate() => _db
      .from('attendance_records')
      .stream(primaryKey: ['id'])
      .asyncMap((_) => computeComplianceRate());
}

AdminService createAdminService() => SupabaseAdminService();
