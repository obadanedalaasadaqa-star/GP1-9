import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/budget_models.dart';
import '../core/constants.dart';
import '../core/design.dart';
import '../core/money.dart';
import '../core/realtime_service.dart';
import '../widgets/budget_bar.dart';
import '../widgets/offline_banner.dart';

/// Monthly budgets per category: the bars for this month, add/edit/remove.
/// Pushed from Profile, the Trends budgets card or a budget alert.
class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({super.key});

  /// Push the screen. A pushed route doesn't see the shell's providers, so the
  /// RealtimeService is passed on (live receipts reload the bars). [realtime]
  /// overrides the lookup, for callers outside the shell's provider (the
  /// shell itself, from a budget alert sheet).
  static Future<void> open(BuildContext context, {RealtimeService? realtime}) {
    final live = realtime ?? context.read<RealtimeService?>();
    final route = MaterialPageRoute<void>(
      builder: (_) => live == null
          ? const BudgetsScreen()
          : ChangeNotifierProvider<RealtimeService>.value(value: live, child: const BudgetsScreen()),
    );
    return Navigator.of(context).push(route);
  }

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  BudgetList? _list;
  bool _loading = true;
  bool _offline = false;
  DateTime? _savedAt;
  String? _error;
  int _requestId = 0;
  ValueListenable<int>? _refreshTick;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_refreshTick == null) {
      _refreshTick = context.read<RealtimeService?>()?.refreshTick;
      _refreshTick?.addListener(_silentLoad);
    }
  }

  @override
  void dispose() {
    _refreshTick?.removeListener(_silentLoad);
    super.dispose();
  }

  void _silentLoad() => _load(silent: true);

  /// [silent]: a live receipt or reconnect. No spinner, failures keep the screen.
  Future<void> _load({bool silent = false}) async {
    final id = ++_requestId;
    if (!silent && _list == null) setState(() { _loading = true; _error = null; });
    try {
      final result = await ApiClient.loadBudgets();
      if (!mounted || id != _requestId) return;
      setState(() {
        _list = result.list;
        _offline = result.offline;
        _savedAt = result.savedAt;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      if (_list == null) {
        setState(() { _error = e.toString(); _loading = false; });
      } else if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _openSheet({BudgetStatus? edit}) async {
    final list = _list;
    if (list == null || _offline) return;
    final updated = await showModalBottomSheet<BudgetList>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BudgetEditSheet(
        categories: edit == null ? list.unbudgeted : [edit.category],
        initialLimit: edit?.limit,
        editing: edit != null,
      ),
    );
    if (updated != null && mounted) {
      setState(() { _list = updated; _offline = false; _savedAt = null; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final pageBg = nx.dark ? AppColors.ink : AppColors.pageBudgets;
    final onPage = nx.dark ? Colors.white : AppColors.ink;
    final list = _list;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
      backgroundColor: pageBg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
          children: [
            Row(
              children: [
                const NxBackButton(),
                const Spacer(),
                if (list != null)
                  Text(list.label,
                    style: NxType.mono(13, color: onPage,
                      weight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 18),
            Text('Monthly budgets',
              style: NxType.display(36, color: onPage, letterSpacing: -1.5,
                height: 1)),
            const SizedBox(height: 6),
            Text("We'll alert you at 80% and 100%.",
              style: NxType.body(14, color: onPage, weight: FontWeight.w600)),
            const SizedBox(height: 18),
            if (_offline && list != null) ...[
              OfflineBanner(savedAt: _savedAt, what: 'budgets'),
              const SizedBox(height: 14),
            ],
            if (_loading)
              Padding(
                padding: const EdgeInsets.only(top: 60),
                child: Center(
                  child: SizedBox(width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: onPage))),
              )
            else if (list == null)
              _buildError(nx, onPage)
            else if (list.budgets.isEmpty)
              _buildEmpty(nx, onPage)
            else
              _buildList(list, nx),
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildList(BudgetList list, Nx nx) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final b in list.budgets)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: NxCard(
            shadow: 0,
            color: nx.card,
            borderColor: nx.dark ? AppColors.border : AppColors.ink,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: BudgetBar(
              key: ValueKey('budget-${b.category}'),
              status: b,
              onTap: _offline ? null : () => _openSheet(edit: b)),
          ),
        ),
      if (list.unbudgeted.isNotEmpty) ...[
        const SizedBox(height: 8),
        _addButton(nx),
      ],
    ],
  );

  Widget _addButton(Nx nx, {String label = 'Add budget'}) => SizedBox(
    height: 54,
    child: OutlinedButton.icon(
      key: const ValueKey('budget-add'),
      onPressed: _offline ? null : () => _openSheet(),
      icon: const Icon(Icons.add_rounded, size: 20),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        backgroundColor: nx.dark ? AppColors.lime : AppColors.ink,
        foregroundColor: nx.dark ? AppColors.ink : Colors.white,
        disabledBackgroundColor: (nx.dark ? AppColors.lime : AppColors.ink)
            .withValues(alpha: 0.35),
        side: BorderSide.none,
        textStyle: NxType.body(15, weight: FontWeight.w700),
        shape: const StadiumBorder()),
    ),
  );

  Widget _buildEmpty(Nx nx, Color onPage) => Padding(
    padding: const EdgeInsets.only(top: 30),
    child: Column(
      children: [
        NxIconTile(icon: Icons.savings_outlined,
          color: nx.dark ? AppColors.amber : Colors.white, size: 64, tilt: -6),
        const SizedBox(height: 18),
        Text('No budgets yet',
          style: NxType.display(22, color: onPage)),
        const SizedBox(height: 8),
        Text('Set a monthly amount for a category and see how much is left.',
          textAlign: TextAlign.center,
          style: NxType.body(14, color: onPage, height: 1.5)),
        const SizedBox(height: 22),
        _addButton(nx, label: 'Add a budget'),
      ],
    ),
  );

  Widget _buildError(Nx nx, Color onPage) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 40, 12, 32),
    child: Column(
      children: [
        Icon(Icons.wifi_off_rounded, color: onPage, size: 40),
        const SizedBox(height: 16),
        Text('Could not load budgets',
          style: NxType.display(20, color: onPage)),
        const SizedBox(height: 8),
        Text(_error ?? '', textAlign: TextAlign.center,
          style: NxType.body(13, color: onPage)),
        const SizedBox(height: 20),
        TextButton(
          onPressed: _load,
          child: Text('Retry',
            style: NxType.body(15, weight: FontWeight.w700, color: onPage)
              .copyWith(decoration: TextDecoration.underline,
                decorationColor: onPage))),
      ],
    ),
  );
}

/// The typed amount with a decimal comma ("12,5", what the iPhone keypad
/// types in comma locales) or the Arabic decimal sign "٫" turned into ".",
/// and Arabic-Indic / Persian digits turned into 0-9. Amounts never have
/// thousands separators here, so a comma is always the decimal point.
String normalizeBudgetAmount(String raw) {
  final b = StringBuffer();
  for (final r in raw.trim().runes) {
    if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660); // ٠-٩
    } else if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0); // ۰-۹
    } else if (r == 0x2C || r == 0x066B) {
      b.write('.');                       // , and ٫
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

/// Amount typed in the app: 1 to 100000 JD with at most 2 decimals.
/// Returns the error text, or null when valid.
String? budgetAmountError(String raw) {
  final s = normalizeBudgetAmount(raw);
  if (s.isEmpty) return 'Enter an amount.';
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return 'Enter a number, like 50 or 12.50.';
  if (RegExp(r'\.\d{3,}$').hasMatch(s)) return 'Use at most 2 decimals.';
  final v = double.parse(s);
  if (v < 1 || v > 100000) return 'Enter an amount between 1 and 100000 JD.';
  return null;
}

/// Add (pick a category) or edit (one category, with "Remove budget") sheet.
/// Pops with the fresh [BudgetList] after a save or removal.
class BudgetEditSheet extends StatefulWidget {
  final List<String> categories;
  final double? initialLimit;
  final bool editing;

  const BudgetEditSheet({
    super.key,
    required this.categories,
    this.initialLimit,
    this.editing = false,
  });

  @override
  State<BudgetEditSheet> createState() => _BudgetEditSheetState();
}

class _BudgetEditSheetState extends State<BudgetEditSheet> {
  late final TextEditingController _amount;
  String? _category;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _category = widget.categories.isEmpty ? null : widget.categories.first;
    final initial = widget.initialLimit;
    _amount = TextEditingController(
      text: initial == null ? '' : formatJd(initial).replaceFirst(RegExp(r'\.00$'), ''));
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _run(Future<BudgetList> Function() call) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final list = await call();
      if (mounted) Navigator.of(context).pop(list);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.fromServer && e.statusCode == 400) {
        setState(() => _error = e.message);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    final category = _category;
    if (category == null) return;
    final problem = budgetAmountError(_amount.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final limit = double.parse(normalizeBudgetAmount(_amount.text));
    _run(() => ApiClient.saveBudget(category, limit));
  }

  Future<void> _remove() async {
    final category = _category;
    if (category == null || _busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove the $category budget?'),
        content: const Text('Its alerts for this month are reset too.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('budget-remove-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove', style: TextStyle(color: AppColors.coral))),
        ],
      ),
    );
    if (ok == true) _run(() => ApiClient.deleteBudget(category));
  }

  /// The +/- buttons: whole JD steps of 5 (the field still takes any amount).
  void _step(int delta) {
    final current = double.tryParse(normalizeBudgetAmount(_amount.text)) ?? 0;
    final next = ((current / 5).round() * 5 + delta).clamp(5, 100000);
    setState(() {
      _amount.text = next.toString();
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);
    final sheetBg = nx.dark ? AppColors.surface : Colors.white;

    Widget stepButton(IconData icon, int delta, String tip) => Tooltip(
      message: tip,
      child: Pressable(
        onTap: _busy ? null : () => _step(delta),
        child: Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: nx.line, width: 2)),
          child: Icon(icon, color: nx.text, size: 26),
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: EdgeInsets.fromLTRB(
          22, 12, 22, 20 + MediaQuery.of(context).padding.bottom),
        decoration: BoxDecoration(
          color: sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: nx.line, width: 2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44, height: 5,
                decoration: BoxDecoration(
                  color: nx.line,
                  borderRadius: BorderRadius.circular(3))),
            ),
            const SizedBox(height: 18),
            Text(widget.editing ? '${_category ?? ''} budget' : 'Add a budget',
              style: NxType.display(26, color: nx.text, letterSpacing: -0.8)),
            const SizedBox(height: 16),
            if (!widget.editing && widget.categories.isNotEmpty) ...[
              Text('CATEGORY', style: NxType.label(nx.muted)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('budget-category'),
                initialValue: _category,
                decoration: nxInput(nx),
                dropdownColor: sheetBg,
                borderRadius: BorderRadius.circular(14),
                style: NxType.body(15.5, color: nx.text, weight: FontWeight.w700),
                items: [
                  for (final c in widget.categories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: _busy ? null : (v) => setState(() => _category = v),
              ),
              const SizedBox(height: 16),
            ],
            Text('MONTHLY AMOUNT', style: NxType.label(nx.muted)),
            const SizedBox(height: 8),
            Row(
              children: [
                stepButton(Icons.remove_rounded, -5, 'Less'),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('budget-amount'),
                    controller: _amount,
                    enabled: !_busy,
                    autofocus: !widget.editing,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: NxType.display(40, color: nx.text, letterSpacing: -1.5),
                    decoration: InputDecoration(
                      hintText: '50',
                      hintStyle: NxType.display(40, color: nx.muted.withValues(alpha: 0.5),
                        letterSpacing: -1.5),
                      suffixText: 'JD',
                      suffixStyle: NxType.display(18, color: nx.text,
                        weight: FontWeight.w700),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: nx.line, width: 2)),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: nx.accent, width: 3)),
                      disabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: nx.hairline, width: 2)),
                    ),
                    onSubmitted: (_) => _save(),
                  ),
                ),
                const SizedBox(width: 12),
                stepButton(Icons.add_rounded, 5, 'More'),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                key: const ValueKey('budget-error'),
                textAlign: TextAlign.center,
                style: NxType.body(13, color: nx.danger, weight: FontWeight.w600)),
            ],
            const SizedBox(height: 20),
            ElevatedButton(
              key: const ValueKey('budget-save'),
              onPressed: _busy || _category == null ? null : _save,
              style: NxButtonStyle.solid(nx),
              child: _busy
                  ? SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: nx.onButton))
                  : const Text('Save'),
            ),
            if (widget.editing) ...[
              const SizedBox(height: 6),
              TextButton(
                key: const ValueKey('budget-remove'),
                onPressed: _busy ? null : _remove,
                child: Text('Remove budget',
                  style: NxType.body(14, color: nx.danger, weight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
