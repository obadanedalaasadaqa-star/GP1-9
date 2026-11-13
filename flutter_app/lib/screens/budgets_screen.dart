import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/api_client.dart';
import '../core/budget_models.dart';
import '../core/constants.dart';
import '../core/money.dart';
import '../core/realtime_service.dart';
import '../core/theme_provider.dart';
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
    final isDark      = context.watch<ThemeProvider>().isDark;
    final bg          = isDark ? AppColors.bg      : AppColors.bgLight;
    final surface     = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border      = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;
    final list = _list;

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.arrow_back_rounded, color: textPrimary)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('Monthly budgets',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 24, fontWeight: FontWeight.w800,
                      color: textPrimary, letterSpacing: -0.5)),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (list != null)
                    Text(list.label,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.gold)),
                  const SizedBox(height: 2),
                  Text("We'll alert you at 80% and 100%.",
                    style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
                ],
              ),
            ),
            if (_offline && list != null) ...[
              OfflineBanner(savedAt: _savedAt, what: 'budgets'),
              const SizedBox(height: 14),
            ],
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 60),
                child: Center(
                  child: SizedBox(width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold))),
              )
            else if (list == null)
              _buildError(textPrimary, textMuted)
            else if (list.budgets.isEmpty)
              _buildEmpty(surface, border, textPrimary, textMuted)
            else
              _buildList(list, surface, border),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BudgetList list, Color surface, Color border) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border),
        ),
        child: Column(
          children: [
            for (final b in list.budgets)
              BudgetBar(
                key: ValueKey('budget-${b.category}'),
                status: b,
                onTap: _offline ? null : () => _openSheet(edit: b)),
          ],
        ),
      ),
      if (list.unbudgeted.isNotEmpty) ...[
        const SizedBox(height: 16),
        _addButton(),
      ],
    ],
  );

  Widget _addButton({String label = 'Add budget'}) => SizedBox(
    height: 48,
    child: OutlinedButton.icon(
      key: const ValueKey('budget-add'),
      onPressed: _offline ? null : () => _openSheet(),
      icon: const Icon(Icons.add_rounded, size: 18),
      label: Text(label,
        style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700, fontSize: 14)),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.gold,
        side: BorderSide(color: AppColors.gold.withValues(alpha: _offline ? 0.2 : 0.5)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
  );

  Widget _buildEmpty(Color surface, Color border, Color textPrimary, Color textMuted) => Padding(
    padding: const EdgeInsets.only(top: 30),
    child: Column(
      children: [
        ShaderMask(
          shaderCallback: (b) => AppColors.goldGlow.createShader(b),
          child: const Icon(Icons.savings_rounded, size: 48, color: Colors.white),
        ),
        const SizedBox(height: 16),
        Text('No budgets yet',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 18, fontWeight: FontWeight.w700, color: textPrimary)),
        const SizedBox(height: 8),
        Text('Set a monthly amount for a category and see how much is left.',
          textAlign: TextAlign.center,
          style: GoogleFonts.dmSans(fontSize: 13, color: textMuted, height: 1.6)),
        const SizedBox(height: 20),
        _addButton(label: 'Add a budget'),
      ],
    ),
  );

  Widget _buildError(Color textPrimary, Color textMuted) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 40, 12, 32),
    child: Column(
      children: [
        const Icon(Icons.wifi_off_rounded, color: AppColors.alert, size: 40),
        const SizedBox(height: 16),
        Text('Could not load budgets',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 16, fontWeight: FontWeight.w700, color: textPrimary)),
        const SizedBox(height: 8),
        Text(_error ?? '', textAlign: TextAlign.center,
          style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
        const SizedBox(height: 20),
        TextButton(
          onPressed: _load,
          child: Text('Retry',
            style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700, color: AppColors.gold))),
      ],
    ),
  );
}

/// Amount typed in the app: 1 to 100000 JD with at most 2 decimals.
/// Returns the error text, or null when valid.
String? budgetAmountError(String raw) {
  final s = raw.trim();
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
    final limit = double.parse(_amount.text.trim());
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
            child: const Text('Remove', style: TextStyle(color: AppColors.alert))),
        ],
      ),
    );
    if (ok == true) _run(() => ApiClient.deleteBudget(category));
  }

  @override
  Widget build(BuildContext context) {
    final isDark      = context.watch<ThemeProvider>().isDark;
    final surface     = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border      = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;

    final field = InputDecoration(
      filled: true,
      fillColor: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.03),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppColors.gold.withValues(alpha: 0.6))),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: textMuted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2))),
            ),
            const SizedBox(height: 18),
            Text(widget.editing ? '${_category ?? ''} budget' : 'Add a budget',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 18, fontWeight: FontWeight.w700, color: textPrimary)),
            const SizedBox(height: 16),
            if (!widget.editing && widget.categories.isNotEmpty) ...[
              Text('Category', style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                key: const ValueKey('budget-category'),
                initialValue: _category,
                decoration: field,
                dropdownColor: surface,
                style: GoogleFonts.dmSans(fontSize: 15, color: textPrimary),
                items: [
                  for (final c in widget.categories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: _busy ? null : (v) => setState(() => _category = v),
              ),
              const SizedBox(height: 14),
            ],
            Text('Monthly amount (JD)', style: GoogleFonts.dmSans(fontSize: 13, color: textMuted)),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('budget-amount'),
              controller: _amount,
              enabled: !_busy,
              autofocus: !widget.editing,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: GoogleFonts.spaceGrotesk(fontSize: 18, color: textPrimary),
              decoration: field.copyWith(hintText: '50', suffixText: 'JD'),
              onSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                key: const ValueKey('budget-error'),
                style: GoogleFonts.dmSans(fontSize: 12.5, color: AppColors.alert)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              height: 48,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AppColors.goldGlow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ElevatedButton(
                  key: const ValueKey('budget-save'),
                  onPressed: _busy || _category == null ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: _busy
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text('Save',
                          style: GoogleFonts.spaceGrotesk(
                            fontWeight: FontWeight.w700, fontSize: 14, color: Colors.white)),
                ),
              ),
            ),
            if (widget.editing) ...[
              const SizedBox(height: 6),
              TextButton(
                key: const ValueKey('budget-remove'),
                onPressed: _busy ? null : _remove,
                child: Text('Remove budget',
                  style: GoogleFonts.dmSans(fontSize: 14, color: AppColors.alert)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
