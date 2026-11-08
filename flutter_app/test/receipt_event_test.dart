import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/receipt_event.dart';
import 'package:nexus_app/core/receipt_model.dart';

void main() {
  // Same shape the backend emits from POST /api/store/receipts.
  final payload = <String, dynamic>{
    'receipt': {
      'id': 'r1',
      'userId': 'u1',
      'storeId': 's1',
      'storeName': 'Carrefour',
      'category': 'Supermarket',
      'totalAmount': 3,
      'items': ['Milk x2', 'Bread'],
      'pointsEarned': 3,
      'createdAt': '2026-11-08T10:00:00.000Z',
    },
    'pointsEarned': 3,
    'loyaltyPoints': 120,
  };

  test('parses a receipt:new payload (storeId is ignored)', () {
    final e = ReceiptEvent.fromJson(payload);
    expect(e.receipt.id, 'r1');
    expect(e.receipt.storeName, 'Carrefour');
    expect(e.receipt.category, 'Supermarket');
    expect(e.receipt.totalAmount, 3.0);
    expect(e.receipt.items, ['Milk x2', 'Bread']);
    expect(e.receipt.pointsEarned, 3);
    expect(e.receipt.date, DateTime.utc(2026, 11, 8, 10));
    expect(e.pointsEarned, 3);
    expect(e.loyaltyPoints, 120);
  });

  test('Receipt.fromJson without pointsEarned gives 0', () {
    final json = Map<String, dynamic>.from(payload['receipt'] as Map)..remove('pointsEarned');
    expect(Receipt.fromJson(json).pointsEarned, 0);
  });
}
