import 'package:supabase_flutter/supabase_flutter.dart' hide AuthException;
import 'package:last/core/constants/auth_redirects.dart';
import 'package:last/core/utils/supabase_config.dart';
import 'package:last/features/auth/models/app_user.dart';
import 'package:last/features/auth/models/user_role.dart';
import 'package:last/features/auth/services/auth_service.dart';
import 'package:last/features/auth/services/auth_profile_mapper.dart';

class SupabaseAuthService implements AuthService {
  final SupabaseClient _supabase = SupabaseConfig.client;
  AppUser? _currentUser;

  @override
  AppUser? get currentUser => _currentUser;

  @override
  Stream<AppUser?> get authStateChanges =>
      _supabase.auth.onAuthStateChange.asyncMap((authState) async {
        final authUser = authState.session?.user;
        if (authUser == null) {
          _currentUser = null;
          return null;
        }

        try {
          final profileUser = await _loadProfile(authUser);
          _currentUser = profileUser;
          return profileUser;
        } catch (_) {
          await _rejectAuthenticatedSession();
          rethrow;
        }
      });

  Future<AppUser> _loadProfile(User authUser) async {
    try {
      final profile = await _supabase
          .from('profiles')
          .select(
            'id, email, full_name, role, is_active, department, case_number, '
            'officer_id, avatar_initials, phone, supervision_start_date, '
            'supervision_end_date, supervision_is_suspended',
          )
          .eq('id', authUser.id)
          .maybeSingle();

      if (profile == null) {
        throw AuthException(
          'Your account exists, but its PPA-TAC profile has not been set up yet.',
        );
      }

      try {
        return AuthProfileMapper.fromRow(
          profile,
          authUserId: authUser.id,
          authEmail: authUser.email,
        );
      } on FormatException catch (error) {
        throw AuthException(error.message.toString());
      }
    } on AuthException {
      rethrow;
    } catch (error) {
      throw AuthException('Could not verify your account profile: $error');
    }
  }

  Future<void> _rejectAuthenticatedSession() async {
    _currentUser = null;
    try {
      await _supabase.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
  }

  @override
  Future<AppUser> signIn({
    required String email,
    required String password,
    required UserRole selectedRole,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    _currentUser = null;

    try {
      final res = await _supabase.auth.signInWithPassword(
        email: cleanEmail,
        password: password,
      );

      final user = res.user;
      if (user == null) {
        throw AuthException('No user account returned from Supabase.');
      }

      AppUser appUser;
      try {
        appUser = await _loadProfile(user);
      } catch (_) {
        await _rejectAuthenticatedSession();
        rethrow;
      }

      if (appUser.role != selectedRole) {
        await _rejectAuthenticatedSession();
        throw AuthException(
          'Role mismatch. This account is registered as a ${appUser.role.label}, but you selected ${selectedRole.label}.',
        );
      }

      _currentUser = appUser;
      return appUser;
    } on AuthApiException catch (e) {
      if (e.message.toLowerCase().contains('email not confirmed')) {
        throw AuthException(
          'Email not confirmed. Check your inbox and spam folder. If the confirmation email is missing, ask the app administrator to check Supabase Auth email logs and SMTP settings.',
        );
      }
      throw AuthException(e.message);
    } on AuthException {
      rethrow;
    } catch (e) {
      throw AuthException('Sign in failed: $e');
    }
  }

  @override
  Future<void> register({
    required String email,
    required String password,
    required String fullName,
    required UserRole role,
    String? phone,
  }) async {
    try {
      final res = await _supabase.auth.signUp(
        email: email.trim(),
        password: password,
        emailRedirectTo: AuthRedirects.emailConfirmation,
        data: {'full_name': fullName, 'role': role.name, 'phone': phone},
      );

      if (res.user == null) {
        throw AuthException('Registration did not create an account.');
      }
      // The reviewed Supabase setup creates profiles from auth.users with a
      // database trigger. A client-side upsert is unreliable when email
      // confirmation is enabled because signUp may not return an active session.
    } on AuthApiException catch (e) {
      throw AuthException(e.message);
    } catch (e) {
      throw AuthException('Registration failed: $e');
    }
  }

  @override
  Future<void> signOut() async {
    _currentUser = null;
    try {
      await _supabase.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
  }
}
