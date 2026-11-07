import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'core/auth_provider.dart';
import 'core/constants.dart';
import 'core/theme_provider.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/archive_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/verify_email_screen.dart';
import 'widgets/bottom_nav.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const NexusApp(),
    ),
  );
}

// ── App ──────────────────────────────────────────────────────────────────────

class NexusApp extends StatelessWidget {
  const NexusApp({super.key});

  static ThemeData _buildTheme({required bool dark}) {
    final base = dark ? ThemeData.dark() : ThemeData.light();
    return base.copyWith(
      scaffoldBackgroundColor: dark ? AppColors.bg : AppColors.bgLight,
      colorScheme: dark
          ? const ColorScheme.dark(
              surface: AppColors.surface,
              primary: AppColors.blue,
              secondary: AppColors.violet,
              error: AppColors.red,
            )
          : const ColorScheme.light(
              surface: AppColors.surfaceLight,
              primary: AppColors.blue,
              secondary: AppColors.violet,
              error: AppColors.red,
            ),
      textTheme: GoogleFonts.dmSansTextTheme(base.textTheme).apply(
        bodyColor: dark ? AppColors.textPrimary : AppColors.textPrimaryLight,
        displayColor: dark ? AppColors.textPrimary : AppColors.textPrimaryLight,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<ThemeProvider>().themeMode;
    return MaterialApp(
      title: 'Nexus',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: _buildTheme(dark: false),
      darkTheme: _buildTheme(dark: true),
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

  // Background glow
  late final Animation<double> _glowOpacity;
  late final Animation<double> _glowScale;

  // Ripple ring that expands outward
  late final Animation<double> _rippleScale;
  late final Animation<double> _rippleOpacity;

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

    _glowOpacity   = Tween(begin: 0.0, end: 1.0).animate(curved(0.00, 0.18, Curves.easeOut));
    _glowScale     = Tween(begin: 0.1, end: 1.6).animate(curved(0.00, 0.42, Curves.easeOut));
    _rippleScale   = Tween(begin: 0.6, end: 2.2).animate(curved(0.16, 0.54, Curves.easeOut));
    _rippleOpacity = Tween(begin: 0.6, end: 0.0).animate(curved(0.16, 0.54, Curves.easeOut));
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
    final bg         = isDark ? AppColors.bg      : AppColors.bgLight;
    final textMuted  = isDark ? AppColors.textMuted : AppColors.textMutedLight;
    final borderCol  = isDark ? AppColors.border  : AppColors.borderLight;

    return Scaffold(
      backgroundColor: bg,
      body: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Opacity(
            opacity: _exitOpacity.value,
            child: Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [

                // ── Background radial glow ───────────────────────────────
                Opacity(
                  opacity: _glowOpacity.value,
                  child: Transform.scale(
                    scale: _glowScale.value,
                    child: Container(
                      width: 380, height: 380,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            isDark
                              ? const Color(0x70D6A046)
                              : const Color(0x50D6A046),
                            isDark
                              ? const Color(0x2863D0C3)
                              : const Color(0x1863D0C3),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),

                // ── Ripple ring ──────────────────────────────────────────
                Opacity(
                  opacity: _rippleOpacity.value,
                  child: Transform.scale(
                    scale: _rippleScale.value,
                    child: Container(
                      width: 200, height: 200,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.gold, width: 1.5),
                      ),
                    ),
                  ),
                ),

                // ── Logo + subtitle ──────────────────────────────────────
                Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // NEXUS wordmark
                    Opacity(
                      opacity: _logoOpacity.value,
                      child: Transform.scale(
                        scale: _logoScale.value,
                        child: ShaderMask(
                          shaderCallback: (b) => AppColors.goldGlow.createShader(b),
                          child: Text('NEXUS',
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 60, fontWeight: FontWeight.w800,
                              color: Colors.white, letterSpacing: -2.5,
                              height: 1)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Subtitle
                    SlideTransition(
                      position: _subtitleSlide,
                      child: Opacity(
                        opacity: _subtitleOpacity.value,
                        child: Text('SMART EXPENSE TRACKING & LOYALTY',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 9, fontWeight: FontWeight.w600,
                            color: textMuted, letterSpacing: 3)),
                      ),
                    ),
                  ],
                ),
                ), // Center

                // ── Progress bar at bottom ───────────────────────────────
                Positioned(
                  bottom: 64,
                  left: 48,
                  right: 48,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Track
                      Container(
                        height: 2,
                        decoration: BoxDecoration(
                          color: borderCol,
                          borderRadius: BorderRadius.circular(1)),
                        child: FractionallySizedBox(
                          widthFactor: _progress.value,
                          alignment: Alignment.centerLeft,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: AppColors.goldGlow,
                              borderRadius: BorderRadius.circular(1),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.gold.withValues(alpha: 0.6),
                                  blurRadius: 6, spreadRadius: 1),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
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
    final auth  = context.watch<AuthProvider>();
    final isDark = context.watch<ThemeProvider>().isDark;
    final bg    = isDark ? AppColors.bg : AppColors.bgLight;

    if (auth.loading) {
      return Scaffold(
        backgroundColor: bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ShaderMask(
                shaderCallback: (b) => AppColors.goldGlow.createShader(b),
                child: Text('NEXUS',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 34, fontWeight: FontWeight.w800,
                    color: Colors.white, letterSpacing: -1)),
              ),
              const SizedBox(height: 28),
              const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.gold)),
            ],
          ),
        ),
      );
    }

    if (!auth.isLoggedIn) return const AuthScreen();
    return const _MainShell();
  }
}

// ── Main shell with 3 tabs + floating QR button ──────────────────────────────

class _MainShell extends StatefulWidget {
  const _MainShell();
  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Right after registering, go straight to email verification
    // (the backend has already sent the code).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthProvider>();
      if (auth.consumeJustRegistered() && !(auth.user?.emailVerified ?? true)) {
        VerifyEmailScreen.open(context, sendOnOpen: false);
      }
    });
  }

  static const _screens = [
    DashboardScreen(),
    ArchiveScreen(),
    ProfileScreen(),
  ];

  void _showQrModal() {
    final user = context.read<AuthProvider>().user;
    if (user == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _QrSheet(
        qrData: 'NEXUS:${user.serialNumber}:${user.id}',
        serial: user.serialNumber,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    return Scaffold(
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
    final isDark = context.watch<ThemeProvider>().isDark;
    final surface = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border  = isDark ? AppColors.border  : AppColors.borderLight;
    final textMuted = isDark ? AppColors.textMuted : AppColors.textMutedLight;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: textMuted.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),
          ShaderMask(
            shaderCallback: (b) => AppColors.goldGlow.createShader(b),
            child: Text('CHECKOUT QR',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: Colors.white, letterSpacing: 2.5)),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: AppColors.gold.withValues(alpha: 0.35),
                  blurRadius: 36, spreadRadius: 6),
              ],
            ),
            child: QrImageView(
              data: widget.qrData,
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.H,
            ),
          ),
          const SizedBox(height: 16),

          // Serial + copy button row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(widget.serial,
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 16, fontWeight: FontWeight.w600,
                  color: AppColors.gold, letterSpacing: 2.5)),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _copy,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _copied
                        ? AppColors.mint.withValues(alpha: 0.15)
                        : AppColors.gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: _copied
                          ? AppColors.mint.withValues(alpha: 0.5)
                          : AppColors.gold.withValues(alpha: 0.35)),
                  ),
                  child: Text(
                    _copied ? '✓ Copied' : 'Copy',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 11, fontWeight: FontWeight.w700,
                      color: _copied ? AppColors.mint : AppColors.gold)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('Present at any Nexus-enabled store',
            style: GoogleFonts.dmSans(
              fontSize: 12, color: textMuted)),
        ],
      ),
    );
  }
}
