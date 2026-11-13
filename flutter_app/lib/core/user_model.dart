class User {
  final String id;
  final String email;
  final String name;
  final String firstName;
  final String lastName;
  final String? phone;
  final bool emailVerified;

  /// The phone number was confirmed with an SMS code.
  final bool phoneVerified;
  final String serialNumber;
  final int loyaltyPoints;
  final DateTime createdAt;

  /// Email me at 80% and 100% of a budget (live alerts are always on).
  final bool budgetAlertEmails;

  /// Opt-in weekly summary email.
  final bool weeklySummaryEmails;

  const User({
    required this.id,
    required this.email,
    required this.name,
    required this.firstName,
    required this.lastName,
    this.phone,
    this.emailVerified = false,
    this.phoneVerified = false,
    required this.serialNumber,
    required this.loyaltyPoints,
    required this.createdAt,
    this.budgetAlertEmails = true,
    this.weeklySummaryEmails = false,
  });

  factory User.fromJson(Map<String, dynamic> j) {
    final name = j['name'] as String;
    // Older backend responses only carry the full name — split it as a fallback
    final parts = name.trim().split(' ');
    return User(
      id: j['id'] as String,
      email: j['email'] as String,
      name: name,
      firstName: j['firstName'] as String? ?? parts.first,
      lastName: j['lastName'] as String? ?? parts.skip(1).join(' '),
      phone: j['phone'] as String?,
      emailVerified: j['emailVerified'] as bool? ?? false,
      phoneVerified: j['phoneVerified'] as bool? ?? false,
      serialNumber: j['serialNumber'] as String,
      loyaltyPoints: (j['loyaltyPoints'] as num).toInt(),
      createdAt: DateTime.parse(j['createdAt'] as String),
      // Missing in older cached profiles: the server's defaults.
      budgetAlertEmails: j['budgetAlertEmails'] as bool? ?? true,
      weeklySummaryEmails: j['weeklySummaryEmails'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'name': name,
    'firstName': firstName,
    'lastName': lastName,
    'phone': phone,
    'emailVerified': emailVerified,
    'phoneVerified': phoneVerified,
    'serialNumber': serialNumber,
    'loyaltyPoints': loyaltyPoints,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'budgetAlertEmails': budgetAlertEmails,
    'weeklySummaryEmails': weeklySummaryEmails,
  };

  User copyWith({
    String? name,
    String? firstName,
    String? lastName,
    String? phone,
    bool? emailVerified,
    bool? phoneVerified,
    int? loyaltyPoints,
    bool? budgetAlertEmails,
    bool? weeklySummaryEmails,
  }) =>
      User(
        id: id,
        email: email,
        name: name ?? this.name,
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        phone: phone ?? this.phone,
        emailVerified: emailVerified ?? this.emailVerified,
        phoneVerified: phoneVerified ?? this.phoneVerified,
        serialNumber: serialNumber,
        loyaltyPoints: loyaltyPoints ?? this.loyaltyPoints,
        createdAt: createdAt,
        budgetAlertEmails: budgetAlertEmails ?? this.budgetAlertEmails,
        weeklySummaryEmails: weeklySummaryEmails ?? this.weeklySummaryEmails,
      );
}
