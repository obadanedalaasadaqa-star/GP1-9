import 'receipt_model.dart';

/// Payload of the server's `receipt:new` socket event: the saved receipt,
/// the points it earned, and the customer's new points balance.
class ReceiptEvent {
  final Receipt receipt;
  final int pointsEarned;
  final int loyaltyPoints;

  const ReceiptEvent({
    required this.receipt,
    required this.pointsEarned,
    required this.loyaltyPoints,
  });

  factory ReceiptEvent.fromJson(Map<String, dynamic> json) => ReceiptEvent(
    receipt: Receipt.fromJson(json['receipt'] as Map<String, dynamic>),
    pointsEarned: (json['pointsEarned'] as num).toInt(),
    loyaltyPoints: (json['loyaltyPoints'] as num).toInt(),
  );
}
