import 'dart:convert';

import 'package:http/http.dart' as http;

// GET /api/ai/report for the demo account (backend test R-1 shape).
Map<String, dynamic> reportJson({
  Map<String, dynamic>? ai,
  int receipts = 7,
  String label = '1 – 11 Nov 2026',
}) => {
      'range': {'period': '1m', 'from': '2026-11-01', 'to': '2026-11-11', 'label': label, 'days': 11},
      'previous': {'from': '2026-10-01', 'to': '2026-10-11', 'label': '1 – 11 Oct 2026'},
      'totals': {'total': receipts == 0 ? 0 : 287.99, 'receipts': receipts, 'average': receipts == 0 ? 0 : 41.141},
      'comparison': {
        'previousTotal': 0, 'previousReceipts': 0, 'difference': receipts == 0 ? 0 : 287.99,
        'changePercent': null, 'isNew': receipts != 0,
      },
      'byCategory': receipts == 0 ? [] : [
        {'category': 'Electronics', 'total': 89.99, 'receipts': 1, 'sharePercent': 31, 'previousTotal': 0},
        {'category': 'Supermarket', 'total': 76.75, 'receipts': 2, 'sharePercent': 27, 'previousTotal': 0},
      ],
      'byMonth': [
        {'month': '2026-11', 'label': 'November 2026', 'total': receipts == 0 ? 0 : 287.99, 'receipts': receipts, 'partial': true},
      ],
      'topStores': receipts == 0 ? [] : [{'storeName': 'iStore', 'total': 89.99, 'receipts': 1}],
      'biggestReceipts': receipts == 0 ? [] : [
        {'date': '2026-11-03T09:12:00.000Z', 'storeName': 'iStore', 'category': 'Electronics', 'total': 89.99},
      ],
      'ai': ai ?? {
        'status': 'ready', 'headline': 'You spent 287.99 JD so far.',
        'narrative': 'Electronics was the biggest category at 89.99 JD.',
        'tips': ['Plan big purchases.'], 'createdAt': '2026-11-11T09:00:00.000Z', 'cached': false,
      },
    };

/// A JSON reply encoded as UTF-8, like Express sends it (labels have an en dash).
http.Response utf8Json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json; charset=utf-8'});
