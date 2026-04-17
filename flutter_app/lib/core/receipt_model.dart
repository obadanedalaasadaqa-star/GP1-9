class Receipt {
  final String id;
  final String storeName;
  final String category;
  final double totalAmount;
  final List<String> items;
  final DateTime date;

  const Receipt({
    required this.id,
    required this.storeName,
    required this.category,
    required this.totalAmount,
    required this.items,
    required this.date,
  });

  factory Receipt.fromJson(Map<String, dynamic> json) => Receipt(
    id:          json['id'] as String,
    storeName:   json['storeName'] as String,
    category:    json['category'] as String,
    totalAmount: (json['totalAmount'] as num).toDouble(),
    items:       (json['items'] as List<dynamic>).map((e) => e as String).toList(),
    date:        DateTime.parse(json['createdAt'] as String),
  );

  static List<Receipt> demoData() => [
    Receipt(
      id: 'r1',
      storeName: 'Carrefour',
      category: 'Supermarket',
      totalAmount: 45.50,
      items: ['Milk x2', 'Bread', 'Eggs x12', 'Chicken 1kg', 'Rice 2kg'],
      date: DateTime(2026, 4, 10),
    ),
    Receipt(
      id: 'r2',
      storeName: 'City Pharmacy',
      category: 'Pharmacy',
      totalAmount: 23.00,
      items: ['Vitamin C', 'Panadol x20', 'Hand Sanitizer'],
      date: DateTime(2026, 4, 9),
    ),
    Receipt(
      id: 'r3',
      storeName: 'Hashem Restaurant',
      category: 'Food',
      totalAmount: 18.75,
      items: ['Falafel plate x2', 'Hummus', 'Fresh Juice x2'],
      date: DateTime(2026, 4, 8),
    ),
    Receipt(
      id: 'r4',
      storeName: 'Zara',
      category: 'Clothing',
      totalAmount: 67.00,
      items: ['T-Shirt', 'Jeans'],
      date: DateTime(2026, 4, 7),
    ),
    Receipt(
      id: 'r5',
      storeName: 'Co-op Supermarket',
      category: 'Supermarket',
      totalAmount: 31.25,
      items: ['Yogurt x3', 'Cheese 500g', 'Tomatoes 1kg', 'Juice 1L x2'],
      date: DateTime(2026, 4, 6),
    ),
    Receipt(
      id: 'r6',
      storeName: 'Books@Cafe',
      category: 'Food',
      totalAmount: 12.50,
      items: ['Cappuccino x2', 'Cheesecake slice'],
      date: DateTime(2026, 4, 5),
    ),
    Receipt(
      id: 'r7',
      storeName: 'iStore',
      category: 'Electronics',
      totalAmount: 89.99,
      items: ['USB-C Cable', 'Screen Protector', 'Phone Case'],
      date: DateTime(2026, 4, 3),
    ),
  ];

  // Aggregate totals by category from a list
  static Map<String, double> totalsByCategory(List<Receipt> receipts) {
    final map = <String, double>{};
    for (final r in receipts) {
      map[r.category] = (map[r.category] ?? 0) + r.totalAmount;
    }
    return map;
  }
}
