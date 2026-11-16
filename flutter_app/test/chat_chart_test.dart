import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/core/chat_chart.dart';

// COMPARE_CHART_JSON from backend/tests/unit/aiChart.test.js, pasted as is.
const compareJson = <String, dynamic>{
  'kind': 'compare',
  'title': '1 – 11 Nov 2026 vs 1 – 11 Oct 2026',
  'unit': 'JD',
  'items': <dynamic>[],
  'a': {'label': '1 – 11 Nov 2026', 'value': 60},
  'b': {'label': '1 – 11 Oct 2026', 'value': 70},
  'change': '-14%',
  'pairs': [
    {'label': 'Food', 'a': 60, 'b': 50},
    {'label': 'Zara', 'a': 0, 'b': 20},
  ],
};

Map<String, dynamic> bars({int n = 3, String kind = 'bars', String unit = 'JD'}) => {
  'kind': kind,
  'title': 'By category · 1 – 11 Nov 2026',
  'unit': unit,
  'items': [for (var i = 0; i < n; i++) {'label': 'C$i', 'value': 10.5 + i, 'note': '${i + 1}%'}],
};

void main() {
  group('ChatChart.tryParse accepts', () {
    test('bars', () {
      final c = ChatChart.tryParse(bars())!;
      expect(c.kind, ChartKind.bars);
      expect(c.unit, ChartUnit.jd);
      expect(c.items.map((i) => i.value), [10.5, 11.5, 12.5]);
      expect(c.items.first.note, '1%');
    });

    test('columns with 25 items, units times and items', () {
      expect(ChatChart.tryParse(bars(n: 25, kind: 'columns'))!.kind, ChartKind.columns);
      expect(ChatChart.tryParse(bars(unit: 'times'))!.unit, ChartUnit.times);
      expect(ChatChart.tryParse(bars(unit: 'items'))!.unit, ChartUnit.items);
    });

    test('the exact compare chart the server builds', () {
      final c = ChatChart.tryParse(compareJson)!;
      expect(c.kind, ChartKind.compare);
      expect(c.items, isEmpty);
      expect(c.a!.label, '1 – 11 Nov 2026');
      expect(c.a!.value, 60);
      expect(c.b!.value, 70);
      expect(c.change, '-14%');
      expect(c.pairs.map((p) => [p.label, p.a, p.b]), [['Food', 60, 50], ['Zara', 0, 20]]);
    });

    test('compare without items and without pairs; change 0%, new, none', () {
      final noLists = Map<String, dynamic>.of(compareJson)..remove('items')..remove('pairs');
      final c = ChatChart.tryParse(noLists)!;
      expect(c.pairs, isEmpty);
      for (final change in ['0%', 'new', 'none', '+12%']) {
        expect(ChatChart.tryParse({...compareJson, 'change': change})!.change, change);
      }
    });

    test('compare with a large change (+24900%) keeps the chart', () {
      final c = ChatChart.tryParse({...compareJson, 'change': '+24900%'})!;
      expect(c.kind, ChartKind.compare);
      expect(c.change, '+24900%');
    });
  });

  group('ChatChart.tryParse rejects', () {
    test('unknown kind or unit, missing title, not a map', () {
      expect(ChatChart.tryParse({...bars(), 'kind': 'pie'}), isNull);
      expect(ChatChart.tryParse({...bars(), 'unit': 'USD'}), isNull);
      expect(ChatChart.tryParse(bars()..remove('title')), isNull);
      expect(ChatChart.tryParse({...bars(), 'title': '  '}), isNull);
      expect(ChatChart.tryParse(null), isNull);
      expect(ChatChart.tryParse('bars'), isNull);
      expect(ChatChart.tryParse([bars()]), isNull);
    });

    test('NaN, negative or non-number values', () {
      for (final v in [double.nan, double.infinity, -1, '5']) {
        expect(ChatChart.tryParse({...bars(), 'items': [{'label': 'A', 'value': v}]}), isNull);
      }
    });

    test('bars with 0 or 26 items', () {
      expect(ChatChart.tryParse(bars(n: 0)), isNull);
      expect(ChatChart.tryParse(bars(n: 26)), isNull);
    });

    test('a 41-rune label (40 is fine)', () {
      expect(ChatChart.tryParse({...bars(), 'items': [{'label': 'é' * 40, 'value': 1}]}), isNotNull);
      expect(ChatChart.tryParse({...bars(), 'items': [{'label': 'é' * 41, 'value': 1}]}), isNull);
    });

    test('compare without b, with 6 pairs, with items, or a strange change', () {
      expect(ChatChart.tryParse(Map<String, dynamic>.of(compareJson)..remove('b')), isNull);
      final six = [for (var i = 0; i < 6; i++) {'label': 'P$i', 'a': 1, 'b': 2}];
      expect(ChatChart.tryParse({...compareJson, 'pairs': six}), isNull);
      expect(ChatChart.tryParse({...compareJson, 'items': [{'label': 'A', 'value': 1}]}), isNull);
      expect(ChatChart.tryParse({...compareJson, 'change': 'lots'}), isNull);
    });
  });
}
