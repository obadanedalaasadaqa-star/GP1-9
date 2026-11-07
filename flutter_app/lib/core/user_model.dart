class User {
  final String id;
  final String email;
  final String name;
  final String firstName;
  final String lastName;
  final String? phone;
  final bool emailVerified;
  final String serialNumber;
  final int loyaltyPoints;
  final DateTime createdAt;

  const User({
    required this.id,
    required this.email,
    required this.name,
    required this.firstName,
    required this.lastName,
    this.phone,
    this.emailVerified = false,
    required this.serialNumber,
    required this.loyaltyPoints,
    required this.createdAt,
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
      serialNumber: j['serialNumber'] as String,
      loyaltyPoints: (j['loyaltyPoints'] as num).toInt(),
      createdAt: DateTime.parse(j['createdAt'] as String),
    );
  }

  User copyWith({
    String? name,
    String? firstName,
    String? lastName,
    String? phone,
    bool? emailVerified,
    int? loyaltyPoints,
  }) =>
      User(
        id: id,
        email: email,
        name: name ?? this.name,
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        phone: phone ?? this.phone,
        emailVerified: emailVerified ?? this.emailVerified,
        serialNumber: serialNumber,
        loyaltyPoints: loyaltyPoints ?? this.loyaltyPoints,
        createdAt: createdAt,
      );
}
