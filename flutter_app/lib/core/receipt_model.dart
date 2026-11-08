/// One line of a store receipt: [qty] x [name] at [unitPrice] JD each.
class LineItem {
  final String name;
  final int qty;
  final double unitPrice;

  const LineItem({required this.name, required this.qty, required this.unitPrice});

  /// qty x unitPrice, summed in whole fils so float noise can't creep in.
  double get lineTotal => qty * (unitPrice * 1000).round() / 1000;

  factory LineItem.fromJson(Map<String, dynamic> j) => LineItem(
    name: j['name'] as String,
    qty: (j['qty'] as num).toInt(),
    unitPrice: (j['unitPrice'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {'name': name, 'qty': qty, 'unitPrice': unitPrice};
}

class Receipt {
  final String id;
  final String storeName;
  final String category;
  final double totalAmount;
  final List<String> items;
  final DateTime date;
  final int pointsEarned;

  /// Full lines with prices. Only store receipts have them; null for older
  /// receipts, which only carry the "Milk x2" strings in [items].
  final List<LineItem>? lineItems;

  const Receipt({
    required this.id,
    required this.storeName,
    required this.category,
    required this.totalAmount,
    required this.items,
    required this.date,
    this.pointsEarned = 0,
    this.lineItems,
  });

  factory Receipt.fromJson(Map<String, dynamic> json) => Receipt(
    id: json['id'] as String,
    storeName: json['storeName'] as String,
    category: json['category'] as String,
    totalAmount: (json['totalAmount'] as num).toDouble(),
    items: (json['items'] as List<dynamic>).map((e) => e as String).toList(),
    // Local time, so month/day grouping and shown dates follow the phone (Jordan), not UTC.
    date: DateTime.parse(json['createdAt'] as String).toLocal(),
    pointsEarned: (json['pointsEarned'] as num?)?.toInt() ?? 0,
    lineItems: (json['lineItems'] as List<dynamic>?)
        ?.map((e) => LineItem.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'storeName': storeName,
    'category': category,
    'totalAmount': totalAmount,
    'items': items,
    'createdAt': date.toUtc().toIso8601String(),
    'pointsEarned': pointsEarned,
    if (lineItems != null) 'lineItems': lineItems!.map((l) => l.toJson()).toList(),
  };

  // Aggregate totals by category from a list
  static Map<String, double> totalsByCategory(List<Receipt> receipts) {
    final map = <String, double>{};
    for (final r in receipts) {
      map[r.category] = (map[r.category] ?? 0) + r.totalAmount;
    }
    return map;
  }
}
