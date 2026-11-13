import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/receipt_model.dart';
import 'package:nexus_app/core/user_model.dart';
import 'package:nexus_app/core/validators.dart';

void main() {
  // ─── Receipt.totalsByCategory ───────────────────────────────────────────────

  group('Receipt.totalsByCategory', () {
    test('returns empty map for empty list', () {
      expect(Receipt.totalsByCategory([]), isEmpty);
    });

    test('returns correct total for a single receipt', () {
      final receipts = [
        Receipt(
          id: '1',
          storeName: 'Carrefour',
          category: 'Supermarket',
          totalAmount: 45.50,
          items: [],
          date: DateTime(2026, 5, 16),
        ),
      ];
      final result = Receipt.totalsByCategory(receipts);
      expect(result['Supermarket'], 45.50);
    });

    test('sums amounts for receipts in the same category', () {
      final receipts = [
        Receipt(
          id: '1',
          storeName: 'Carrefour',
          category: 'Supermarket',
          totalAmount: 45.50,
          items: [],
          date: DateTime(2026, 5, 16),
        ),
        Receipt(
          id: '2',
          storeName: 'Co-op',
          category: 'Supermarket',
          totalAmount: 31.25,
          items: [],
          date: DateTime(2026, 5, 15),
        ),
      ];
      final result = Receipt.totalsByCategory(receipts);
      expect(result['Supermarket'], closeTo(76.75, 0.001));
    });

    test('keeps separate totals for different categories', () {
      final receipts = [
        Receipt(
          id: '1',
          storeName: 'Carrefour',
          category: 'Supermarket',
          totalAmount: 45.50,
          items: [],
          date: DateTime(2026, 5, 16),
        ),
        Receipt(
          id: '2',
          storeName: 'City Pharmacy',
          category: 'Pharmacy',
          totalAmount: 23.00,
          items: [],
          date: DateTime(2026, 5, 16),
        ),
      ];
      final result = Receipt.totalsByCategory(receipts);
      expect(result.length, 2);
      expect(result['Supermarket'], 45.50);
      expect(result['Pharmacy'], 23.00);
    });
  });

  // ─── Receipt.fromJson ───────────────────────────────────────────────────────

  group('Receipt.fromJson', () {
    test('parses all fields correctly', () {
      final json = {
        'id': 'abc-123',
        'storeName': 'Hashem Restaurant',
        'category': 'Food',
        'totalAmount': 18.75,
        'items': ['Falafel', 'Hummus'],
        'createdAt': '2026-05-16T10:00:00.000Z',
      };
      final receipt = Receipt.fromJson(json);
      expect(receipt.id, 'abc-123');
      expect(receipt.storeName, 'Hashem Restaurant');
      expect(receipt.category, 'Food');
      expect(receipt.totalAmount, 18.75);
      expect(receipt.items, ['Falafel', 'Hummus']);
      expect(receipt.date.toUtc(), DateTime.parse('2026-05-16T10:00:00.000Z'));
      expect(receipt.date.isUtc, isFalse); // local time for month/day grouping
    });

    test('parses integer totalAmount from JSON as double', () {
      final json = {
        'id': '1',
        'storeName': 'Store',
        'category': 'Other',
        'totalAmount': 50,
        'items': [],
        'createdAt': '2026-05-16T10:00:00.000Z',
      };
      final receipt = Receipt.fromJson(json);
      expect(receipt.totalAmount, isA<double>());
      expect(receipt.totalAmount, 50.0);
    });
  });

  // ─── User.fromJson ──────────────────────────────────────────────────────────

  group('User.fromJson', () {
    test('parses all fields correctly', () {
      final json = {
        'id': 'user-123',
        'email': 'noor@gmail.com',
        'name': 'Noor',
        'serialNumber': 'NXS-442F8-AA1CC',
        'loyaltyPoints': 285,
        'createdAt': '2026-05-16T18:52:45.546Z',
      };
      final user = User.fromJson(json);
      expect(user.id, 'user-123');
      expect(user.email, 'noor@gmail.com');
      expect(user.name, 'Noor');
      expect(user.serialNumber, 'NXS-442F8-AA1CC');
      expect(user.loyaltyPoints, 285);
    });

    test('serial number matches NXS-XXXXX-XXXXX format', () {
      final json = {
        'id': 'user-123',
        'email': 'noor@gmail.com',
        'name': 'Noor',
        'serialNumber': 'NXS-442F8-AA1CC',
        'loyaltyPoints': 0,
        'createdAt': '2026-05-16T18:52:45.546Z',
      };
      final user = User.fromJson(json);
      final pattern = RegExp(r'^NXS-[A-F0-9]{5}-[A-F0-9]{5}$');
      expect(pattern.hasMatch(user.serialNumber), isTrue);
    });

    test('parses firstName and lastName; an old cached phone is ignored', () {
      final json = {
        'id': 'user-123',
        'email': 'noor@gmail.com',
        'name': 'Noor Assaf',
        'firstName': 'Noor',
        'lastName': 'Assaf',
        'phone': '+962791234567',
        'serialNumber': 'NXS-442F8-AA1CC',
        'loyaltyPoints': 0,
        'createdAt': '2026-05-16T18:52:45.546Z',
      };
      final user = User.fromJson(json);
      expect(user.firstName, 'Noor');
      expect(user.lastName, 'Assaf');
      expect(user.toJson().containsKey('phone'), isFalse);
    });

    test('falls back to splitting name when firstName/lastName are missing', () {
      final json = {
        'id': 'user-123',
        'email': 'noor@gmail.com',
        'name': 'Noor Al Assaf',
        'serialNumber': 'NXS-442F8-AA1CC',
        'loyaltyPoints': 0,
        'createdAt': '2026-05-16T18:52:45.546Z',
      };
      final user = User.fromJson(json);
      expect(user.firstName, 'Noor');
      expect(user.lastName, 'Al Assaf');
    });

    test('emailVerified parsed, defaults to false when missing', () {
      final base = {
        'id': 'user-123',
        'email': 'noor@gmail.com',
        'name': 'Noor Assaf',
        'serialNumber': 'NXS-442F8-AA1CC',
        'loyaltyPoints': 0,
        'createdAt': '2026-05-16T18:52:45.546Z',
      };
      expect(User.fromJson({...base, 'emailVerified': true}).emailVerified, isTrue);
      expect(User.fromJson(base).emailVerified, isFalse);
    });
  });

  // ─── User.copyWith ──────────────────────────────────────────────────────────

  group('User.copyWith', () {
    late User baseUser;

    setUp(() {
      baseUser = User(
        id: 'user-123',
        email: 'noor@gmail.com',
        name: 'Noor',
        firstName: 'Noor',
        lastName: '',
        serialNumber: 'NXS-442F8-AA1CC',
        loyaltyPoints: 0,
        createdAt: DateTime(2026, 5, 16),
      );
    });

    test('copyWith(name:) updates name and preserves all other fields', () {
      final updated = baseUser.copyWith(name: 'Noor Assaf');
      expect(updated.name, 'Noor Assaf');
      expect(updated.id, baseUser.id);
      expect(updated.email, baseUser.email);
      expect(updated.serialNumber, baseUser.serialNumber);
      expect(updated.loyaltyPoints, baseUser.loyaltyPoints);
    });

    test('copyWith(loyaltyPoints:) updates points and preserves all other fields', () {
      final updated = baseUser.copyWith(loyaltyPoints: 150);
      expect(updated.loyaltyPoints, 150);
      expect(updated.name, baseUser.name);
      expect(updated.id, baseUser.id);
      expect(updated.email, baseUser.email);
    });

    test('copyWith() with no arguments returns identical values', () {
      final copy = baseUser.copyWith();
      expect(copy.id, baseUser.id);
      expect(copy.email, baseUser.email);
      expect(copy.name, baseUser.name);
      expect(copy.serialNumber, baseUser.serialNumber);
      expect(copy.loyaltyPoints, baseUser.loyaltyPoints);
    });
  });

  // ─── Password rules & strength ──────────────────────────────────────────────

  group('Password rules', () {
    test('valid only when every rule is met', () {
      expect(isValidPassword('Nexus@2026'), isTrue);
      expect(isValidPassword('testtest'), isFalse);     // no upper, number, special
      expect(isValidPassword('Testtest1'), isFalse);    // no special
      expect(isValidPassword('N@1a'), isFalse);         // too short
      expect(isValidPassword('NEXUS@2026'), isFalse);   // no lowercase
    });

    test('strength levels', () {
      expect(passwordStrength(''), PasswordStrength.weak);
      expect(passwordStrength('testtest'), PasswordStrength.weak);
      expect(passwordStrength('Testtest1'), PasswordStrength.fair);
      expect(passwordStrength('Nexus@2026'), PasswordStrength.good);
      expect(passwordStrength('Nexus@2026-Secure'), PasswordStrength.strong);
    });

    test('validateNewPassword messages', () {
      expect(validateNewPassword(''), 'Password is required');
      expect(validateNewPassword('weak'), isNotNull);
      expect(validateNewPassword('Nexus@2026'), isNull);
    });
  });
}
