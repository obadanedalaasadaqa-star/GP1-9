import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/money.dart';

void main() {
  group('formatJd: Archive and Trends print the same total', () {
    // archive = the Archive's own fold, server = what round3() sends back.
    void same(List<double> amounts, String expected) {
      final archive = amounts.fold(0.0, (s, a) => s + a);
      final reversed = amounts.reversed.fold(0.0, (s, a) => s + a);
      final server = (archive * 1000).round() / 1000;
      expect(formatJd(archive), expected, reason: 'archive fold $archive');
      expect(formatJd(reversed), expected, reason: 'reversed fold $reversed');
      expect(formatJd(server), expected, reason: 'server $server');
    }

    test('[0.1, 0.1, 1.005] gives 1.21 (the old toStringAsFixed gave 1.20)', () {
      final raw = [0.1, 0.1, 1.005].fold(0.0, (s, a) => s + a);
      expect(raw, 1.2049999999999998);
      expect(raw.toStringAsFixed(2), '1.20'); // the old Archive header
      same([0.1, 0.1, 1.005], '1.21');
    });

    test('[0.1, 0.1, 0.015] gives 0.22', () {
      expect([0.1, 0.1, 0.015].fold(0.0, (s, a) => s + a), 0.21500000000000002);
      same([0.1, 0.1, 0.015], '0.22');
    });

    test('[0.1, 0.2, 2.675] gives 2.98', () {
      expect([0.1, 0.2, 2.675].fold(0.0, (s, a) => s + a), 2.9749999999999996);
      same([0.1, 0.2, 2.675], '2.98');
    });

    test('[12.345] gives 12.35 and [1.005] gives 1.01', () {
      same([12.345], '12.35');
      same([1.005], '1.01');
    });
  });

  test('plain values', () {
    expect(formatJd(0), '0.00');
    expect(formatJd(287.99), '287.99');
    expect(formatJd(89.99), '89.99');
    expect(formatJd(1.205, decimals: 3), '1.205');
  });

  test('decimals: 0 snaps to fils first', () {
    expect(formatJd(12.5, decimals: 0), '13');
    expect(formatJd(12.4999999, decimals: 0), '13');
    expect(formatJd(12.49, decimals: 0), '12');
  });
}
