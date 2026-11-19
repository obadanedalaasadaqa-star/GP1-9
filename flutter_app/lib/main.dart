import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'core/ai_chat_session.dart';
import 'core/api_client.dart';
import 'core/app_lock.dart';
import 'core/auth_provider.dart';
import 'core/budget_models.dart';
import 'core/constants.dart';
import 'core/design.dart';
import 'core/realtime_service.dart';
import 'core/receipt_event.dart';
import 'core/theme_provider.dart';
import 'screens/auth_screen.dart';
import 'screens/budgets_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/archive_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/trends_screen.dart';
import 'screens/verify_email_screen.dart';
import 'widgets/app_lock_overlay.dart';
import 'widgets/biometric_offer_sheet.dart';
import 'widgets/bottom_nav.dart';
import 'widgets/dismiss_keyboard.dart';
import 'widgets/live_sheets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  // One AuthProvider (S23): the same object AppLock locks and the app reads.
  final auth = AuthProvider();
  final appLock = AppLock(auth: auth);
  // Before runApp, so it handles `resumed` before any RealtimeService does.
  WidgetsBinding.instance.addObserver(appLock);
  runApp(buildNexusRoot(auth: auth, theme: ThemeProvider(), appLock: appLock));
}

/// The app with its providers. Tests build it with the same [auth] they hand
/// to [AppLock], exactly like [main].
Widget buildNexusRoot({required AuthProvider auth, required ThemeProvider theme, AppLock? appLock}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<ThemeProvider>.value(value: theme),
        Provider<AppLock?>.value(value: appLock),
      ],
      child: const NexusApp(),
    );

// ── App ──────────────────────────────────────────────────────────────────────

class NexusApp extends StatelessWidget {
  const NexusApp({super.key});

  static ThemeData _buildTheme({required bool dark}) {
    final base = dark ? ThemeData.dark() : ThemeData.light();
    final text  = dark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final muted = dark ? AppColors.textMuted : AppColors.textMutedLight;
    final card  = dark ? AppColors.surface : Colors.white;
    final accent = dark ? AppColors.lime : AppColors.cobalt;
    return base.copyWith(
      scaffoldBackgroundColor: dark ? AppColors.bg : AppColors.bgLight,
      colorScheme: dark
          ? const ColorScheme.dark(
              surface: AppColors.surface,
              primary: AppColors.lime,
              onPrimary: AppColors.ink,
              secondary: AppColors.cobaltLight,
              error: AppColors.coral,
            )
          : const ColorScheme.light(
              surface: Colors.white,
              primary: AppColors.cobalt,
              onPrimary: Colors.white,
              secondary: AppColors.ink,
              error: AppColors.danger,
            ),
      textTheme: GoogleFonts.instrumentSansTextTheme(base.textTheme).apply(
        bodyColor: text,
        displayColor: text,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.3),
        selectionHandleColor: accent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: dark ? AppColors.border : AppColors.ink, width: 2)),
        titleTextStyle: GoogleFonts.bricolageGrotesque(
          fontSize: 20, fontWeight: FontWeight.w800, color: text),
        contentTextStyle: GoogleFonts.instrumentSans(
          fontSize: 14, color: muted, height: 1.45),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark ? AppColors.lime : AppColors.ink,
        contentTextStyle: GoogleFonts.instrumentSans(
          fontSize: 14, fontWeight: FontWeight.w600,
          color: dark ? AppColors.ink : Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? (dark ? AppColors.ink : AppColors.lime)
                : (dark ? AppColors.textMuted : AppColors.ink)),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? (dark ? AppColors.lime : AppColors.ink)
                : (dark ? AppColors.raised : Colors.white)),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
            dark ? (s.contains(WidgetState.selected) ? AppColors.lime : AppColors.textMuted)
                 : AppColors.ink),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: GoogleFonts.instrumentSans(
            fontSize: 14, fontWeight: FontWeight.w700)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  /// Sits above the Navigator: a tap outside any field closes the keyboard on
  /// every screen, dialog and sheet, and the Face ID lock covers them all.
  static Widget appBuilder(BuildContext context, Widget? child) =>
      DismissKeyboard(child: AppLockGate(child: child ?? const SizedBox.shrink()));

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<ThemeProvider>().themeMode;
    return MaterialApp(
      title: 'Nexus',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: _buildTheme(dark: false),
      darkTheme: _buildTheme(dark: true),
      builder: appBuilder,
      home: const _SplashScreen(),
    );
  }
}

// ── Splash screen ────────────────────────────────────────────────────────────

class _SplashScreen extends StatefulWidget {
  const _SplashScreen();
  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  // NEXUS wordmark
  late final Animation<double> _logoOpacity;
  late final Animation<double> _logoScale;

  // Subtitle text
  late final Animation<double> _subtitleOpacity;
  late final Animation<Offset> _subtitleSlide;

  // Bottom progress bar
  late final Animation<double> _progress;

  // Exit fade
  late final Animation<double> _exitOpacity;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );

    Animation<double> curved(double start, double end, Curve curve) =>
        CurvedAnimation(parent: _ctrl,
          curve: Interval(start, end, curve: curve));

    _logoOpacity   = Tween(begin: 0.0, end: 1.0).animate(curved(0.20, 0.48, Curves.easeOut));
    _logoScale     = Tween(begin: 0.72, end: 1.0).animate(curved(0.20, 0.52, Curves.easeOut));
    _subtitleOpacity = Tween(begin: 0.0, end: 1.0).animate(curved(0.36, 0.58, Curves.easeOut));
    _subtitleSlide   = Tween(begin: const Offset(0, 0.8), end: Offset.zero)
        .animate(curved(0.36, 0.58, Curves.easeOut));
    _progress      = Tween(begin: 0.0, end: 1.0).animate(curved(0.50, 0.84, Curves.easeInOut));
    _exitOpacity   = Tween(begin: 1.0, end: 0.0).animate(curved(0.87, 1.00, Curves.easeIn));

    _ctrl.forward();

    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 400),
            opaque: false,
            pageBuilder: (context, animation, secondaryAnimation) =>
                const _Root(),
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) =>
                    FadeTransition(opacity: animation, child: child),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    final bg = isDark ? AppColors.ink : AppColors.cobalt;

    return Scaffold(
      backgroundColor: bg,
      body: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Opacity(
            opacity: _exitOpacity.value,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Wordmark with a points stamp landing on it ───────────
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Opacity(
                            opacity: _logoOpacity.value,
                            child: Transform.scale(
                              scale: _logoScale.value,
                              child: Text('Nexus',
                                style: NxType.display(76, color: Colors.white,
                                  letterSpacing: -4, height: 1)),
                            ),
                          ),
                          Positioned(
                            right: -46, top: -18,
                            child: Opacity(
                              opacity: _subtitleOpacity.value,
                              child: Transform.scale(
                                scale: 1.8 - 0.8 * _subtitleOpacity.value,
                                child: const NxStamp(
                                  value: '+12', caption: 'POINTS',
                                  color: AppColors.ink, fill: AppColors.lime,
                                  size: 64, tilt: -12),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SlideTransition(
                        position: _subtitleSlide,
                        child: Opacity(
                          opacity: _subtitleOpacity.value,
                          child: Text('Every receipt, without the paper.',
                            style: NxType.body(17, color: AppColors.lime,
                              weight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Progress: a till slip printing ───────────────────────
                Positioned(
                  bottom: 72, left: 64, right: 64,
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(3)),
                    child: FractionallySizedBox(
                      widthFactor: _progress.value,
                      alignment: Alignment.centerLeft,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.lime,
                          borderRadius: BorderRadius.circular(3)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Auth gate ────────────────────────────────────────────────────────────────

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (auth.loading) {
      return _Splash(message: auth.wakingServer ? 'Waking up the server...' : null);
    }
    if (auth.startupError != null) {
      return _Splash(error: auth.startupError, onRetry: auth.retry);
    }

    if (!auth.isLoggedIn) return const AuthScreen();
    return const _MainShell();
  }
}

// ── Startup splash: loading, or "server unreachable" with Retry ─────────────

class _Splash extends StatelessWidget {
  final String? message;
  final String? error;
  final VoidCallback? onRetry;
  const _Splash({this.message, this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final nx = Nx.of(context);

    return Scaffold(
      backgroundColor: nx.bg,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Nexus',
                style: NxType.display(44, color: nx.text, letterSpacing: -2)),
              const SizedBox(height: 28),
              if (error == null) ...[
                SizedBox(width: 22, height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: nx.accent)),
                if (message != null) ...[
                  const SizedBox(height: 16),
                  Text(message!,
                    style: NxType.mono(12.5, color: nx.muted)),
                ],
              ] else ...[
                Text(error!,
                  textAlign: TextAlign.center,
                  style: NxType.body(15, color: nx.muted, height: 1.5)),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onRetry,
                    style: NxButtonStyle.solid(nx),
                    child: const Text('Retry'),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => context.read<AuthProvider>().logout(),
                  child: Text('Sign in with a different account',
                    style: NxType.body(13, color: nx.muted,
                      weight: FontWeight.w600)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Main shell with 4 tabs + floating QR button ──────────────────────────────

class _MainShell extends StatefulWidget {
  const _MainShell();
  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> with LiveSheets<_MainShell> {
  int _index = 0;

  // Live receipts. Created per shell, so logout (which replaces the shell
  // with AuthScreen) closes the socket.
  late final RealtimeService _realtime;
  final List<StreamSubscription<void>> _subs = [];

  // Ask AI chat for this login session (in memory only, gone after logout).
  late final AiChatSession _chat = AiChatSession();

  // The open QR / "New receipt" / budget alert sheets live in LiveSheets.
  bool _expiring = false;

  // Face ID re-lock (null in tests that build the shell without main()).
  AppLock? _appLock;
  late final LockHooks _lockHooks = LockHooks(
    onLock: _realtime.stop,
    onUnlocked: () {
      // Points and lists refresh once connected.
      _realtime.syncOnFirstConnect = true;
      _realtime.start();
    },
    onPasswordRequested: () {
      closeLiveSheets();
      Navigator.of(context).popUntil((r) => r.isFirst);
      context.read<AuthProvider>().logout();
    },
  );

  @override
  void initState() {
    super.initState();
    _realtime = RealtimeService();
    _appLock = context.read<AppLock?>();
    _appLock?.hooks = _lockHooks;
    _subs.addAll([
      _realtime.receipts.listen(_onReceipt),
      _realtime.budgetAlerts.listen(_onBudgetAlert),
      _realtime.syncs.listen((_) => _onSync()),
      _realtime.unauthorized.listen((_) => _onSessionExpired()),
    ]);
    // Opened offline with the saved profile: refresh everything once connected.
    _realtime.syncOnFirstConnect = context.read<AuthProvider>().offline;
    _realtime.start();

    // Right after registering, go straight to email verification
    // (the backend has already sent the code).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (auth.consumeJustRegistered() && !(auth.user?.emailVerified ?? true)) {
        VerifyEmailScreen.open(context, sendOnOpen: false);
      } else if (auth.consumeBiometricOffer()) {
        // After a password sign-in: "Use Face ID next time?"
        BiometricOfferSheet.show(context);
      }
    });
  }

  @override
  void dispose() {
    if (identical(_appLock?.hooks, _lockHooks)) _appLock?.hooks = null;
    for (final sub in _subs) {
      sub.cancel();
    }
    _realtime.dispose();
    _chat.dispose();
    super.dispose();
  }

  late final List<Widget> _screens = [
    DashboardScreen(onOpenArchive: () => setState(() => _index = 1)),
    const ArchiveScreen(),
    const TrendsScreen(),
    const ProfileScreen(),
  ];

  void _showQrModal() {
    final user = context.read<AuthProvider>().user;
    if (user == null) return;
    showQrSheet((_) => _QrSheet(
      qrData: 'NEXUS:${user.serialNumber}:${user.id}',
      serial: user.serialNumber,
    ));
  }

  // A store sent a receipt: update the points, swap any open sheet for the
  // "New receipt" sheet. Dashboard/Archive reload through refreshTick.
  void _onReceipt(ReceiptEvent e) {
    if (!mounted || _expiring) return;
    final auth = context.read<AuthProvider>();
    if (auth.locked) return; // nothing shows while locked (S8)
    final user = auth.user;
    if (user != null) auth.updateUser(user.copyWith(loyaltyPoints: e.loyaltyPoints));

    showReceiptSheet(e, onViewArchive: () {
      if (mounted) setState(() => _index = 1);
    });
  }

  // A store receipt reached 80% / 100% of a budget: a banner in its "New
  // receipt" sheet, or a budget alert sheet. The Budgets screen gets the
  // shell's RealtimeService directly (the provider is below this context).
  void _onBudgetAlert(BudgetAlert alert) {
    if (!mounted || _expiring || context.read<AuthProvider>().locked) return;
    showBudgetAlert(alert, onViewBudgets: () {
      if (mounted) BudgetsScreen.open(context, realtime: _realtime);
    });
  }

  // Reconnect or resume: refresh the user (points). A 401 means the session ended.
  // Locked: ignored, and a locked app is never signed out by a late 401 (S9).
  Future<void> _onSync() async {
    final auth = context.read<AuthProvider>();
    if (auth.locked) return;
    try {
      await auth.refreshUser();
    } on ApiException catch (e) {
      if (e.statusCode == 401 && mounted && !auth.locked) _onSessionExpired();
    } catch (_) {
      // Offline or server down: the next sync retries.
    }
  }

  // Token refused (socket) or 401 (sync): close everything and log out once.
  void _onSessionExpired() {
    if (!mounted || _expiring || context.read<AuthProvider>().locked) return;
    _expiring = true;
    closeLiveSheets();
    Navigator.of(context).popUntil((r) => r.isFirst);
    // The root ScaffoldMessenger (MaterialApp) keeps it visible on AuthScreen.
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Your session expired. Please log in again.')));
    context.read<AuthProvider>().logout();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<RealtimeService>.value(value: _realtime),
        ChangeNotifierProvider<AiChatSession>.value(value: _chat),
      ],
      child: Scaffold(
        extendBody: true,
        backgroundColor: isDark ? AppColors.bg : AppColors.bgLight,
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: KeyedSubtree(
            key: ValueKey(_index),
            child: _screens[_index],
          ),
        ),
        bottomNavigationBar: NexusBottomNav(
          currentIndex: _index,
          onTap: (i) => setState(() => _index = i),
          onQrTap: _showQrModal,
        ),
      ),
    );
  }
}

// ── Quick-look QR bottom sheet ───────────────────────────────────────────────

class _QrSheet extends StatefulWidget {
  final String qrData;
  final String serial;
  const _QrSheet({required this.qrData, required this.serial});

  @override
  State<_QrSheet> createState() => _QrSheetState();
}

class _QrSheetState extends State<_QrSheet> {
  bool _copied = false;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.serial));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    String cap(String v) => v.isEmpty ? v : v[0].toUpperCase() + v.substring(1);
    final name = user == null
        ? ''
        : (user.lastName.isEmpty
            ? cap(user.firstName)
            : '${cap(user.firstName)} ${user.lastName[0].toUpperCase()}.');

    return Container(
      padding: EdgeInsets.fromLTRB(
          24, 14, 24, 24 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: AppColors.lime,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 44, height: 5,
              decoration: BoxDecoration(
                color: AppColors.ink.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(3))),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              NxBackButton(icon: Icons.close_rounded, tooltip: 'Close',
                onTap: () => Navigator.of(context).maybePop()),
              const Spacer(),
              Text('NO PAPER NEEDED',
                style: NxType.label(AppColors.ink)),
            ],
          ),
          const SizedBox(height: 16),
          Text('Show this\nat the till.',
            style: NxType.display(40, color: AppColors.ink, height: 0.98,
              letterSpacing: -1.8)),
          const SizedBox(height: 20),

          // ── The code, printed on a slip ───────────────────────────────
          Center(
            child: Transform.rotate(
              angle: -0.035,
              child: Container(
                width: 290,
                decoration: const BoxDecoration(boxShadow: [
                  BoxShadow(color: AppColors.ink, offset: Offset(6, 8)),
                ]),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ReceiptEdge(color: Colors.white, up: true),
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: QrImageView(
                              data: widget.qrData,
                              version: QrVersions.auto,
                              size: 200,
                              backgroundColor: Colors.white,
                              eyeStyle: const QrEyeStyle(
                                eyeShape: QrEyeShape.square,
                                color: AppColors.ink),
                              dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.square,
                                color: AppColors.ink),
                              errorCorrectionLevel: QrErrorCorrectLevel.H,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const DashedRule(color: AppColors.ink),
                          const SizedBox(height: 10),
                          Text('MEMBER',
                            style: NxType.label(AppColors.textMutedLight)),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Expanded(
                                child: Text(name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: NxType.display(17,
                                    color: AppColors.ink)),
                              ),
                              GestureDetector(
                                onTap: _copy,
                                child: Text(
                                  _copied ? 'Copied' : widget.serial,
                                  style: NxType.mono(12.5,
                                    color: _copied
                                        ? AppColors.teal : AppColors.ink,
                                    weight: FontWeight.w500)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const ReceiptEdge(color: Colors.white),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          Center(
            child: Pressable(
              onTap: _copy,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  borderRadius: BorderRadius.circular(22)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10, height: 10,
                      decoration: const BoxDecoration(
                        color: AppColors.lime, shape: BoxShape.circle)),
                    const SizedBox(width: 10),
                    Text(_copied ? 'Code copied' : 'Copy my code',
                      style: NxType.body(14, color: Colors.white,
                        weight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _QrStep(n: '01', text: 'Cashier scans your code')),
              SizedBox(width: 10),
              Expanded(child: _QrStep(n: '02', text: 'Receipt lands in the app')),
              SizedBox(width: 10),
              Expanded(child: _QrStep(n: '03', text: 'Points stamp your card')),
            ],
          ),
        ],
      ),
    );
  }
}

class _QrStep extends StatelessWidget {
  final String n;
  final String text;
  const _QrStep({required this.n, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.only(top: 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.ink, width: 2))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(n, style: NxType.mono(12, color: AppColors.ink)),
            const SizedBox(height: 4),
            Text(text, style: NxType.body(13, color: AppColors.ink,
              weight: FontWeight.w700, height: 1.2)),
          ],
        ),
      );
}
