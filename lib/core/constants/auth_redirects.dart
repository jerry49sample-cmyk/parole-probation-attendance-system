import 'package:flutter/foundation.dart';

class AuthRedirects {
  const AuthRedirects._();

  static const String androidConfirmation =
      'com.example.last://login-callback/';

  static String? get emailConfirmation {
    if (kIsWeb) {
      return Uri.base.resolve('/').toString();
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    return androidConfirmation;
  }
}
