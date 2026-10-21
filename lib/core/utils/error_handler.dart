import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

class AppException implements Exception {
  AppException(this.message, {this.code});
  final String message;
  final String? code;

  @override
  String toString() => message;
}

class ErrorHandler {
  static String friendlyMessage(Object error) {
    if (error is AppException) return error.message;
    if (error is supabase.PostgrestException) {
      if (error.code == '42501') return 'Access denied. Check your Supabase row-level security policies.';
      if (error.code == '23505') return 'This record already exists.';
      return error.message;
    }
    if (error is supabase.AuthException) return error.message;
    final msg = error.toString();
    if (msg.contains('permission denied') || msg.contains('42501')) {
      return 'Access denied. Check your Supabase row-level security policies.';
    }
    if (msg.contains('unavailable') || msg.contains('network')) {
      return 'Network unavailable. Check your connection and try again.';
    }
    return msg.replaceFirst('Exception: ', '');
  }

  static AppException wrap(Object error, [String? context]) {
    final msg = friendlyMessage(error);
    final prefix = context != null ? '$context: ' : '';
    return AppException('$prefix$msg');
  }
}
