class User {
  final String id;
  final String email;
  final String name;
  final String serialNumber;
  final int loyaltyPoints;
  final DateTime createdAt;

  const User({
    required this.id,
    required this.email,
    required this.name,
    required this.serialNumber,
    required this.loyaltyPoints,
    required this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as String,
        email: j['email'] as String,
        name: j['name'] as String,
        serialNumber: j['serialNumber'] as String,
        loyaltyPoints: (j['loyaltyPoints'] as num).toInt(),
        createdAt: DateTime.parse(j['createdAt'] as String),
      );

  User copyWith({String? name, int? loyaltyPoints}) => User(
        id: id,
        email: email,
        name: name ?? this.name,
        serialNumber: serialNumber,
        loyaltyPoints: loyaltyPoints ?? this.loyaltyPoints,
        createdAt: createdAt,
      );
}
