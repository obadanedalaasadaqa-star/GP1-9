/// A server-style user body (`SAFE_SELECT`).
Map<String, dynamic> userJson({
  String id = 'u1',
  String email = 'a@nexus.test',
  bool verified = true,
  bool twoFactor = false,
}) =>
    {
      'id': id, 'email': email, 'name': 'Sara Ali', 'firstName': 'Sara', 'lastName': 'Ali',
      'serialNumber': 'NXS-AAAAA-BBBBB', 'loyaltyPoints': 3, 'createdAt': '2026-01-01T00:00:00.000Z',
      'emailVerified': verified, 'budgetAlertEmails': true, 'weeklySummaryEmails': false,
      'loginTwoFactor': twoFactor,
    };

/// The `/auth/login` answer when two-step sign-in is on.
const challengeJson = <String, dynamic>{
  'twoFactorRequired': true,
  'challengeToken': 'challenge-1',
  'method': 'email',
  'expiresInSeconds': 600,
};
