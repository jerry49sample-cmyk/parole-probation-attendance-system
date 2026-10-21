import 'package:last/features/auth/models/app_user.dart';
import 'package:last/features/auth/models/user_role.dart';

class AuthProfileMapper {
  const AuthProfileMapper._();

  static AppUser fromRow(
    Map<String, dynamic> row, {
    required String authUserId,
    String? authEmail,
  }) {
    final profileId = row['id']?.toString();
    if (profileId != authUserId) {
      throw const FormatException(
        'The account profile does not match the signed-in user.',
      );
    }

    final roleName = row['role']?.toString().trim().toLowerCase();
    final role = switch (roleName) {
      'officer' => UserRole.officer,
      'parolee' => UserRole.parolee,
      _ => throw const FormatException(
        'This account has a role that is not supported by the app.',
      ),
    };

    if (row['is_active'] != true) {
      throw const FormatException(
        'This account is inactive and cannot sign in.',
      );
    }

    final email = _optionalString(row['email']) ?? authEmail ?? '';
    return AppUser(
      id: profileId!,
      email: email,
      fullName: _optionalString(row['full_name']) ?? email,
      role: role,
      department: _optionalString(row['department']),
      caseNumber: _optionalString(row['case_number']),
      officerId: _optionalString(row['officer_id']),
      avatarInitials: _optionalString(row['avatar_initials']),
      phone: _optionalString(row['phone']),
      isActive: true,
      supervisionStartDate: _optionalString(row['supervision_start_date']),
      supervisionEndDate: _optionalString(row['supervision_end_date']),
      supervisionIsSuspended: row['supervision_is_suspended'] == true,
    );
  }

  static String? _optionalString(Object? value) {
    if (value == null) return null;
    final normalized = value.toString().trim();
    return normalized.isEmpty ? null : normalized;
  }
}
