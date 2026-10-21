import 'package:flutter_test/flutter_test.dart';
import 'package:last/features/auth/models/user_role.dart';
import 'package:last/features/auth/services/auth_profile_mapper.dart';

void main() {
  const authUserId = 'auth-user-1';

  Map<String, dynamic> profile({
    String id = authUserId,
    String role = 'parolee',
    Object? isActive = true,
  }) {
    return {
      'id': id,
      'email': 'juan@example.com',
      'full_name': 'Juan Dela Cruz',
      'role': role,
      'is_active': isActive,
      'department': 'District 4',
      'case_number': 'PP-2024-1847',
      'officer_id': 'officer-1',
      'avatar_initials': 'JD',
      'phone': '09171234567',
      'supervision_start_date': '2024-06-01',
      'supervision_end_date': '2027-06-01',
      'supervision_is_suspended': false,
    };
  }

  group('AuthProfileMapper', () {
    test('uses the verified profile for the signed-in account', () {
      final user = AuthProfileMapper.fromRow(
        profile(),
        authUserId: authUserId,
        authEmail: 'auth@example.com',
      );

      expect(user.id, authUserId);
      expect(user.email, 'juan@example.com');
      expect(user.fullName, 'Juan Dela Cruz');
      expect(user.role, UserRole.parolee);
      expect(user.isActive, isTrue);
      expect(user.officerId, 'officer-1');
      expect(user.caseNumber, 'PP-2024-1847');
      expect(user.supervisionStartDate, '2024-06-01');
    });

    test('rejects inactive profiles', () {
      expect(
        () => AuthProfileMapper.fromRow(
          profile(isActive: false),
          authUserId: authUserId,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects missing active status', () {
      expect(
        () => AuthProfileMapper.fromRow(
          profile(isActive: null),
          authUserId: authUserId,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unsupported profile roles', () {
      expect(
        () => AuthProfileMapper.fromRow(
          profile(role: 'admin'),
          authUserId: authUserId,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a profile that belongs to another auth user', () {
      expect(
        () => AuthProfileMapper.fromRow(
          profile(id: 'different-user'),
          authUserId: authUserId,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
