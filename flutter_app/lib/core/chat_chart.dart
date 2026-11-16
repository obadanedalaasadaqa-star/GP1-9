// The small chart under an Ask AI answer (POST /api/ai/chat "chart").
// The server builds it from the tool results; the app only draws it.
// tryParse returns null for anything unexpected, so a future server shape
// can never break the chat.

enum ChartKind { bars, columns, compare }

enum ChartUnit { jd, times, items }

class ChartItem {
  final String label;
  final double value;
  final String? note;
  const ChartItem(this.label, this.value, {this.note});
}

class ChartPoint {
  final String label;
  final double value;
  const ChartPoint(this.label, this.value);
}

class ChartPair {
  final String label;
  final double a;
  final double b;
  const ChartPair(this.label, this.a, this.b);
}

class ChatChart {
  static const maxItems = 25;
  static const maxPairs = 5;
  static const maxLabelRunes = 40;
  static final _change = RegExp(r'^[+-]?\d+%$');

  final ChartKind kind;
  final String title;
  final ChartUnit unit;
  final List<ChartItem> items;
  final ChartPoint? a;
  final ChartPoint? b;
  final String? change;
  final List<ChartPair> pairs;

  const ChatChart({
    required this.kind,
    required this.title,
    required this.unit,
    this.items = const [],
    this.a,
    this.b,
    this.change,
    this.pairs = const [],
  });

  static String? _label(Object? v) =>
      v is String && v.runes.length <= maxLabelRunes ? v : null;

  static double? _value(Object? v) {
    if (v is! num) return null;
    final d = v.toDouble();
    return d.isFinite && d >= 0 ? d : null;
  }

  static ChartPoint? _point(Object? v) {
    if (v is! Map) return null;
    final label = _label(v['label']);
    final value = _value(v['value']);
    return label == null || value == null ? null : ChartPoint(label, value);
  }

  /// The chart, or null when [json] is missing or not a shape this app knows.
  static ChatChart? tryParse(Object? json) {
    if (json is! Map) return null;
    final kind = switch (json['kind']) {
      'bars' => ChartKind.bars,
      'columns' => ChartKind.columns,
      'compare' => ChartKind.compare,
      _ => null,
    };
    final unit = switch (json['unit']) {
      'JD' => ChartUnit.jd,
      'times' => ChartUnit.times,
      'items' => ChartUnit.items,
      _ => null,
    };
    final title = json['title'];
    if (kind == null || unit == null || title is! String || title.trim().isEmpty) return null;

    final rawItems = json['items'];
    final items = <ChartItem>[];
    if (rawItems != null) {
      if (rawItems is! List) return null;
      for (final e in rawItems) {
        if (e is! Map) return null;
        final label = _label(e['label']);
        final value = _value(e['value']);
        final note = e['note'];
        if (label == null || value == null || (note != null && note is! String)) return null;
        items.add(ChartItem(label, value, note: note as String?));
      }
    }

    if (kind != ChartKind.compare) {
      if (items.isEmpty || items.length > maxItems) return null;
      return ChatChart(kind: kind, title: title, unit: unit, items: items);
    }

    // compare: a and b, no items, up to 5 pairs, a known change text.
    if (items.isNotEmpty) return null;
    final a = _point(json['a']);
    final b = _point(json['b']);
    if (a == null || b == null) return null;
    final rawPairs = json['pairs'];
    final pairs = <ChartPair>[];
    if (rawPairs != null) {
      if (rawPairs is! List || rawPairs.length > maxPairs) return null;
      for (final p in rawPairs) {
        if (p is! Map) return null;
        final label = _label(p['label']);
        final pa = _value(p['a']);
        final pb = _value(p['b']);
        if (label == null || pa == null || pb == null) return null;
        pairs.add(ChartPair(label, pa, pb));
      }
    }
    final change = json['change'];
    if (change != null &&
        (change is! String || !(change == 'new' || change == 'none' || _change.hasMatch(change)))) {
      return null;
    }
    return ChatChart(
      kind: kind, title: title, unit: unit, a: a, b: b, change: change as String?, pairs: pairs);
  }
}
