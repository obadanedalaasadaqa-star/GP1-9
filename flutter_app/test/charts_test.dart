import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:nexus_app/core/chat_chart.dart';
import 'package:nexus_app/core/constants.dart';
import 'package:nexus_app/core/theme_provider.dart';
import 'package:nexus_app/widgets/charts/bar_list.dart';
import 'package:nexus_app/widgets/charts/chat_chart_view.dart';
import 'package:nexus_app/widgets/charts/column_chart.dart';
import 'package:nexus_app/widgets/charts/compare_bars.dart';
import 'package:nexus_app/widgets/charts/count_up_text.dart';
import 'package:nexus_app/widgets/charts/donut_chart.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Widget child,
      {bool reduceMotion = false, double width = 390}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: MaterialApp(
        home: Builder(builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
        )),
      ),
    ));
  }

  // The same wait as report_view_test.dart.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  List<double> rods(WidgetTester tester, {int rod = 0}) => tester
      .widget<BarChart>(find.byType(BarChart))
      .data
      .barGroups
      .map((g) => g.barRods[rod].toY)
      .toList();

  const items = [
    BarItem('Milk', 6, '6×'),
    BarItem('Bread', 5, '5×'),
    BarItem('Eggs', 1.5, '1.5×'),
  ];

  group('CountUpText', () {
    testWidgets('ends exactly on formatJd(value) JD after the report wait', (tester) async {
      await pump(tester, const CountUpText(287.99));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('287.99 JD'), findsNothing); // still counting
      await settle(tester);
      expect(find.text('287.99 JD'), findsOneWidget);
    });

    testWidgets('reduce motion: the final text after one pump', (tester) async {
      await pump(tester, const CountUpText(1.205), reduceMotion: true);
      expect(find.text('1.21 JD'), findsOneWidget);
    });
  });

  group('BarList', () {
    testWidgets('after the settle: rod values in order, item 0 on top, values printed as given', (tester) async {
      final semantics = tester.ensureSemantics();
      await pump(tester, const BarList(items: items));
      await settle(tester);
      expect(rods(tester), [6, 5, 1.5]);
      final milk = tester.getTopLeft(find.text('Milk')).dy;
      final bread = tester.getTopLeft(find.text('Bread')).dy;
      final eggs = tester.getTopLeft(find.text('Eggs')).dy;
      expect(milk < bread && bread < eggs, isTrue);
      for (final t in ['6×', '5×', '1.5×']) {
        expect(find.text(t), findsOneWidget);
      }
      expect(find.bySemanticsLabel('Milk 6×, Bread 5×, Eggs 1.5×'), findsOneWidget);
      // The chart is turned a quarter, so its bars run left to right and
      // group 0 is at the top, next to the first label.
      expect(tester.widget<BarChart>(find.byType(BarChart)).data.rotationQuarterTurns, 1);
      semantics.dispose();
    });

    testWidgets('it grows: at 300 ms every rod is still below its final value', (tester) async {
      await pump(tester, const BarList(items: items));
      await tester.pump(const Duration(milliseconds: 300));
      final mid = rods(tester);
      expect(mid[0], lessThan(6));
      expect(mid[1], lessThan(5));
      expect(mid[2], lessThan(1.5));
      expect(mid.every((v) => v > 0), isTrue);
      await settle(tester);
    });

    testWidgets('reduce motion: final values after one pump; fl_chart animation is off', (tester) async {
      await pump(tester, const BarList(items: items), reduceMotion: true);
      expect(rods(tester), [6, 5, 1.5]);
      expect(tester.widget<BarChart>(find.byType(BarChart)).duration, Duration.zero);
    });

    testWidgets('all zero: no exception, maxY 1', (tester) async {
      await pump(tester, const BarList(items: [BarItem('A', 0, '0'), BarItem('B', 0, '0')]));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(tester.widget<BarChart>(find.byType(BarChart)).data.maxY, 1);
    });

    testWidgets('value2 adds a second rod in the same row', (tester) async {
      await pump(tester, const BarList(items: [BarItem('Food', 60, '60 / 50', value2: 50)]), reduceMotion: true);
      expect(rods(tester, rod: 1), [50]);
    });
  });

  group('donut', () {
    test('donutSlices merges slices under 2% into one Other slice; one slice stays', () {
      const a = DonutSlice('Food', 90, AppColors.mint);
      const b = DonutSlice('Pharmacy', 8.5, AppColors.violet);
      const c = DonutSlice('X', 1, AppColors.blue);
      const d = DonutSlice('Y', 0.5, AppColors.gold);
      final out = donutSlices([a, b, c, d]);
      expect(out.map((s) => s.label), ['Food', 'Pharmacy', 'Other']);
      expect(out.last.value, 1.5);
      expect(donutSlices([c]).single.label, 'X');
      expect(donutSlices([a, b]).map((s) => s.label), ['Food', 'Pharmacy']);
    });

    testWidgets('after the settle: sections sum to the total, no filler, no titles, only the centre text',
        (tester) async {
      await pump(tester, const DonutChart(
        slices: [DonutSlice('Electronics', 89.99, AppColors.blueLight), DonutSlice('Supermarket', 76.75, AppColors.blue)],
        center: Text('2 categories'),
      ));
      await settle(tester);
      final sections = tester.widget<PieChart>(find.byType(PieChart)).data.sections;
      expect(sections, hasLength(2));
      expect(sections.fold<double>(0, (s, x) => s + x.value), closeTo(166.74, 1e-9));
      expect(sections.every((s) => !s.showTitle), isTrue);
      expect(find.byType(Text), findsOneWidget);
      expect(find.text('2 categories'), findsOneWidget);
    });

    testWidgets('while it sweeps in, a transparent filler keeps the circle closed', (tester) async {
      await pump(tester, const DonutChart(
        slices: [DonutSlice('Food', 10, AppColors.mint), DonutSlice('Pharmacy', 10, AppColors.violet)],
        center: SizedBox(),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      final sections = tester.widget<PieChart>(find.byType(PieChart)).data.sections;
      expect(sections, hasLength(3));
      expect(sections.fold<double>(0, (s, x) => s + x.value), closeTo(20, 1e-9));
      await settle(tester);
    });
  });

  testWidgets('ColumnChart with 25 items scrolls; top labels have no " JD"', (tester) async {
    await pump(tester, ColumnChart(items: [
      for (var i = 0; i < 25; i++) ColumnItem('M$i', i * 10.0, '${i * 10}', highlight: i == 24),
    ]));
    await settle(tester);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.textContaining(' JD'), findsNothing);
    expect(find.text('M0'), findsOneWidget);
  });

  testWidgets('CompareBars(showValues: false, showChange: false) prints only its two labels', (tester) async {
    await pump(tester, const CompareBars(
      aLabel: 'This period', aValue: 287.99, bLabel: 'Before', bValue: 0,
      change: 'new', showValues: false, showChange: false,
    ));
    await settle(tester);
    expect(find.byType(Text), findsNWidgets(2));
    expect(find.text('This period'), findsOneWidget);
    expect(find.text('Before'), findsOneWidget);
  });

  testWidgets('CompareBars with values and the change chip', (tester) async {
    await pump(tester, const CompareBars(aLabel: 'A', aValue: 60, bLabel: 'B', bValue: 70, change: '-14%'));
    await settle(tester);
    expect(find.text('60.00 JD'), findsOneWidget);
    expect(find.text('70.00 JD'), findsOneWidget);
    expect(find.text('−14%'), findsOneWidget);
    expect(compareChangeText('new'), 'New');
    expect(compareChangeText('+12%'), '+12%');
  });

  testWidgets('ChatChartView: 25 columns in an 80% bubble on a 375 px screen do not overflow', (tester) async {
    final chart = ChatChart(kind: ChartKind.columns, title: 'Monthly spending', unit: ChartUnit.jd, items: [
      for (var i = 0; i < 25; i++) ChartItem('Nov ${24 + i ~/ 12}', i == 24 ? 9999.999 : 100.0 * i),
    ]);
    await pump(tester, Builder(builder: (context) => Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [ChatChartView(chart: chart)]),
        ),
      ),
    )), width: 375);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('chat-chart')), findsOneWidget);
  });

  testWidgets('ChatChartView: unit items prints 12 pcs, 1.5 pcs, 0.125 pcs', (tester) async {
    const chart = ChatChart(kind: ChartKind.bars, title: 'Most bought by quantity', unit: ChartUnit.items, items: [
      ChartItem('Eggs', 12), ChartItem('Milk', 1.5), ChartItem('Saffron', 0.125),
    ]);
    await pump(tester, const ChatChartView(chart: chart));
    await settle(tester);
    for (final t in ['12 pcs', '1.5 pcs', '0.125 pcs']) {
      expect(find.text(t), findsOneWidget);
    }
    expect(formatQty(2), '2');
    expect(formatQty(0.1), '0.1');
  });
}
