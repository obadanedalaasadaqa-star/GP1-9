class Receipt {
  final String id;
  final String storeName;
  final String category;
  final double totalAmount;
  final List<String> items;
  final DateTime date;
  final int pointsEarned;

  const Receipt({
    required this.id,
    required this.storeName,
    required this.category,
    required this.totalAmount,
    required this.items,
    required this.date,
    this.pointsEarned = 0,
  });

  factory Receipt.fromJson(Map<String, dynamic> json) => Receipt(
    id: json['id'] as String,
    storeName: json['storeName'] as String,
    category: json['category'] as String,
    totalAmount: (json['totalAmount'] as num).toDouble(),
    items: (json['items'] as List<dynamic>).map((e) => e as String).toList(),
    date: DateTime.parse(json['createdAt'] as String),
    pointsEarned: (json['pointsEarned'] as num?)?.toInt() ?? 0,
  );

  // Aggregate totals by category from a list
  static Map<String, double> totalsByCategory(List<Receipt> receipts) {
    final map = <String, double>{};
    for (final r in receipts) {
      map[r.category] = (map[r.category] ?? 0) + r.totalAmount;
    }
    return map;
  }
}
