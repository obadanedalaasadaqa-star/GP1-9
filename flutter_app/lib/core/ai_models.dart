// Models for the AI page: the insight (GET /api/ai/insight), Ask AI chat
// messages (POST /api/ai/chat) and spending reports (GET /api/ai/report).

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
int _i(Object? v) => (v as num?)?.toInt() ?? 0;
DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

// ── Insight ─────────────────────────────────────────────────────────────────

enum InsightStatus { ready, notEnoughData }

/// The AI summary + tip for this month, or "not enough data yet".
class Insight {
  final InsightStatus status;
  final String summary;
  final String tip;
  final DateTime? createdAt; // local
  final int receiptCount;
  final int minReceipts;

  const Insight({
    required this.status,
    this.summary = '',
    this.tip = '',
    this.createdAt,
    this.receiptCount = 0,
    this.minReceipts = 3,
  });

  factory Insight.fromJson(Map<String, dynamic> json) {
    switch (json['status']) {
      case 'ready':
        return Insight(
          status: InsightStatus.ready,
          summary: json['summary'] as String,
          tip: json['tip'] as String,
          createdAt: _date(json['createdAt']),
        );
      case 'not_enough_data':
        return Insight(
          status: InsightStatus.notEnoughData,
          receiptCount: _i(json['receiptCount']),
          minReceipts: _i(json['minReceipts']),
        );
      default:
        throw FormatException('Unknown insight status: ${json['status']}');
    }
  }

  Map<String, dynamic> toJson() => status == InsightStatus.ready
      ? {
          'status': 'ready',
          'summary': summary,
          'tip': tip,
          if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
        }
      : {'status': 'not_enough_data', 'receiptCount': receiptCount, 'minReceipts': minReceipts};
}

// ── Chat ────────────────────────────────────────────────────────────────────

enum ChatRole { user, assistant }

/// One chat bubble. Error bubbles are never sent back as history.
class ChatMessage {
  final ChatRole role;
  final String text;
  final bool isError;

  /// For an error bubble: the question that "Try again" sends again.
  final String? retryQuestion;

  const ChatMessage({
    required this.role,
    required this.text,
    this.isError = false,
    this.retryQuestion,
  });

  /// The `{ role, text }` item the server expects in `history`.
  Map<String, String> toHistoryJson() =>
      {'role': role == ChatRole.user ? 'user' : 'assistant', 'text': text};
}

// ── Reports ─────────────────────────────────────────────────────────────────

enum ReportPeriod {
  oneMonth('1m', '1 month'),
  threeMonths('3m', '3 months'),
  sixMonths('6m', '6 months'),
  oneYear('1y', '1 year'),
  custom('custom', 'Custom');

  final String code;
  final String label;
  const ReportPeriod(this.code, this.label);
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// What report to ask for. [from]/[to] (local days, both included) only for custom.
class ReportRequest {
  final ReportPeriod period;
  final DateTime? from;
  final DateTime? to;

  const ReportRequest(this.period, {this.from, this.to});

  /// Query parameters (strings) for GET /api/ai/report.
  Map<String, String> toQuery(int tzOffsetMinutes) => {
        'period': period.code,
        if (period == ReportPeriod.custom && from != null) 'from': _ymd(from!),
        if (period == ReportPeriod.custom && to != null) 'to': _ymd(to!),
        'tzOffsetMinutes': '$tzOffsetMinutes',
      };

  /// "1m", or "custom:2026-09-01:2026-10-15". Offline, a saved report is only
  /// shown for the same key.
  String get cacheKey => period == ReportPeriod.custom
      ? 'custom:${from == null ? '' : _ymd(from!)}:${to == null ? '' : _ymd(to!)}'
      : period.code;
}

class ReportRange {
  final String period;
  final String from;
  final String to;
  final String label;
  final int days;
  const ReportRange({required this.period, required this.from, required this.to, required this.label, required this.days});

  factory ReportRange.fromJson(Map<String, dynamic> j) => ReportRange(
        period: j['period'] as String? ?? '',
        from: j['from'] as String,
        to: j['to'] as String,
        label: j['label'] as String,
        days: _i(j['days']),
      );
  Map<String, dynamic> toJson() => {'period': period, 'from': from, 'to': to, 'label': label, 'days': days};
}

class ReportTotals {
  final double total;
  final int receipts;
  final double average;
  const ReportTotals({required this.total, required this.receipts, required this.average});

  factory ReportTotals.fromJson(Map<String, dynamic> j) =>
      ReportTotals(total: _d(j['total']), receipts: _i(j['receipts']), average: _d(j['average']));
  Map<String, dynamic> toJson() => {'total': total, 'receipts': receipts, 'average': average};
}

class ReportComparison {
  final double previousTotal;
  final int previousReceipts;
  final double difference;
  final int? changePercent;
  final bool isNew;
  const ReportComparison({
    required this.previousTotal,
    required this.previousReceipts,
    required this.difference,
    required this.changePercent,
    required this.isNew,
  });

  factory ReportComparison.fromJson(Map<String, dynamic> j) => ReportComparison(
        previousTotal: _d(j['previousTotal']),
        previousReceipts: _i(j['previousReceipts']),
        difference: _d(j['difference']),
        changePercent: (j['changePercent'] as num?)?.toInt(),
        isNew: j['isNew'] == true,
      );
  Map<String, dynamic> toJson() => {
        'previousTotal': previousTotal,
        'previousReceipts': previousReceipts,
        'difference': difference,
        'changePercent': changePercent,
        'isNew': isNew,
      };

  /// "New", "—", "+12%", "−8%" or "0%" (real minus sign, like Trends).
  String get changeLabel {
    final p = changePercent;
    if (p == null) return isNew ? 'New' : '—';
    if (p > 0) return '+$p%';
    if (p < 0) return '−${-p}%';
    return '0%';
  }
}

class ReportCategory {
  final String category;
  final double total;
  final int receipts;
  final int sharePercent;
  final double previousTotal;
  const ReportCategory({
    required this.category,
    required this.total,
    required this.receipts,
    required this.sharePercent,
    required this.previousTotal,
  });

  factory ReportCategory.fromJson(Map<String, dynamic> j) => ReportCategory(
        category: j['category'] as String,
        total: _d(j['total']),
        receipts: _i(j['receipts']),
        sharePercent: _i(j['sharePercent']),
        previousTotal: _d(j['previousTotal']),
      );
  Map<String, dynamic> toJson() => {
        'category': category,
        'total': total,
        'receipts': receipts,
        'sharePercent': sharePercent,
        'previousTotal': previousTotal,
      };
}

class ReportMonth {
  final String month;
  final String label;
  final double total;
  final int receipts;
  final bool partial;
  const ReportMonth({required this.month, required this.label, required this.total, required this.receipts, required this.partial});

  factory ReportMonth.fromJson(Map<String, dynamic> j) => ReportMonth(
        month: j['month'] as String,
        label: j['label'] as String,
        total: _d(j['total']),
        receipts: _i(j['receipts']),
        partial: j['partial'] == true,
      );
  Map<String, dynamic> toJson() =>
      {'month': month, 'label': label, 'total': total, 'receipts': receipts, 'partial': partial};
}

class ReportStore {
  final String storeName;
  final double total;
  final int receipts;
  const ReportStore({required this.storeName, required this.total, required this.receipts});

  factory ReportStore.fromJson(Map<String, dynamic> j) =>
      ReportStore(storeName: j['storeName'] as String, total: _d(j['total']), receipts: _i(j['receipts']));
  Map<String, dynamic> toJson() => {'storeName': storeName, 'total': total, 'receipts': receipts};
}

class ReportReceipt {
  final DateTime date; // local
  final String storeName;
  final String category;
  final double total;
  const ReportReceipt({required this.date, required this.storeName, required this.category, required this.total});

  factory ReportReceipt.fromJson(Map<String, dynamic> j) => ReportReceipt(
        date: DateTime.parse(j['date'] as String).toLocal(),
        storeName: j['storeName'] as String,
        category: j['category'] as String,
        total: _d(j['total']),
      );
  Map<String, dynamic> toJson() => {
        'date': date.toUtc().toIso8601String(),
        'storeName': storeName,
        'category': category,
        'total': total,
      };
}

enum ReportAiStatus { ready, notEnoughData, unavailable }

/// The AI part of a report. The numbers never depend on it.
class ReportAi {
  final ReportAiStatus status;
  final String headline;
  final String narrative;
  final List<String> tips;
  final String? error;
  final DateTime? createdAt;
  final int minReceipts;

  const ReportAi({
    required this.status,
    this.headline = '',
    this.narrative = '',
    this.tips = const [],
    this.error,
    this.createdAt,
    this.minReceipts = 3,
  });

  factory ReportAi.fromJson(Map<String, dynamic>? j) {
    switch (j?['status']) {
      case 'ready':
        return ReportAi(
          status: ReportAiStatus.ready,
          headline: j!['headline'] as String,
          narrative: j['narrative'] as String,
          tips: (j['tips'] as List<dynamic>).map((t) => t as String).toList(),
          createdAt: _date(j['createdAt']),
        );
      case 'not_enough_data':
        return ReportAi(status: ReportAiStatus.notEnoughData, minReceipts: _i(j!['minReceipts']));
      default:
        return ReportAi(status: ReportAiStatus.unavailable, error: j?['error'] as String?);
    }
  }

  Map<String, dynamic> toJson() => switch (status) {
        ReportAiStatus.ready => {
            'status': 'ready',
            'headline': headline,
            'narrative': narrative,
            'tips': tips,
            if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
          },
        ReportAiStatus.notEnoughData => {'status': 'not_enough_data', 'minReceipts': minReceipts},
        ReportAiStatus.unavailable => {'status': 'unavailable', 'error': error},
      };
}

/// A spending report: every number from the server, plus the AI text.
class SpendingReport {
  final ReportRange range;
  final ReportRange previous;
  final ReportTotals totals;
  final ReportComparison comparison;
  final List<ReportCategory> byCategory;
  final List<ReportMonth> byMonth;
  final List<ReportStore> topStores;
  final List<ReportReceipt> biggestReceipts;
  final ReportAi ai;

  const SpendingReport({
    required this.range,
    required this.previous,
    required this.totals,
    required this.comparison,
    required this.byCategory,
    required this.byMonth,
    required this.topStores,
    required this.biggestReceipts,
    required this.ai,
  });

  static List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) f) =>
      (v as List<dynamic>? ?? const []).map((e) => f(e as Map<String, dynamic>)).toList();

  factory SpendingReport.fromJson(Map<String, dynamic> j) => SpendingReport(
        range: ReportRange.fromJson(j['range'] as Map<String, dynamic>),
        previous: ReportRange.fromJson(j['previous'] as Map<String, dynamic>),
        totals: ReportTotals.fromJson(j['totals'] as Map<String, dynamic>),
        comparison: ReportComparison.fromJson(j['comparison'] as Map<String, dynamic>),
        byCategory: _list(j['byCategory'], ReportCategory.fromJson),
        byMonth: _list(j['byMonth'], ReportMonth.fromJson),
        topStores: _list(j['topStores'], ReportStore.fromJson),
        biggestReceipts: _list(j['biggestReceipts'], ReportReceipt.fromJson),
        ai: ReportAi.fromJson(j['ai'] as Map<String, dynamic>?),
      );

  Map<String, dynamic> toJson() => {
        'range': range.toJson(),
        'previous': previous.toJson(),
        'totals': totals.toJson(),
        'comparison': comparison.toJson(),
        'byCategory': byCategory.map((c) => c.toJson()).toList(),
        'byMonth': byMonth.map((m) => m.toJson()).toList(),
        'topStores': topStores.map((s) => s.toJson()).toList(),
        'biggestReceipts': biggestReceipts.map((r) => r.toJson()).toList(),
        'ai': ai.toJson(),
      };
}
