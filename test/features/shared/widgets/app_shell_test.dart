import 'package:flutter_test/flutter_test.dart';
import 'package:last/features/shared/widgets/app_shell.dart';

void main() {
  group('role navigation', () {
    test('officer destinations match the web reference', () {
      final tabs = officerTabs('/officer');

      expect(tabs.map((tab) => tab.label).toList(), [
        'Dashboard',
        'Activities',
        'GPS Trackers',
        'User Management',
        'Reports',
        'Notifications',
        'Officer Profile',
      ]);
      expect(tabs.map((tab) => tab.route).toList(), [
        '/officer/dashboard',
        '/officer/activities',
        '/officer/trackers',
        '/officer/users',
        '/officer/reports',
        '/officer/notifications',
        '/officer/profile',
      ]);
    });

    test('parolee destinations match the web reference', () {
      final tabs = paroleeTabs('/parolee');

      expect(tabs.map((tab) => tab.label).toList(), [
        'Dashboard',
        'My Activities',
        'Check-in QR',
        'History',
        'Notifications',
        'My Profile',
      ]);
      expect(tabs.map((tab) => tab.route).toList(), [
        '/parolee/dashboard',
        '/parolee/activities',
        '/parolee/check-in',
        '/parolee/history',
        '/parolee/notifications',
        '/parolee/profile',
      ]);
    });
  });
}
