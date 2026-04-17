import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../core/auth_provider.dart';
import '../core/constants.dart';
import '../core/theme_provider.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _formKey = GlobalKey<FormState>();
  final _name     = TextEditingController();
  final _email    = TextEditingController();
  final _password = TextEditingController();

  bool _loading = false;
  String? _error;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _isRegister => _tabs.index == 1;

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _loading = true; _error = null; });
    final auth = context.read<AuthProvider>();
    try {
      if (_isRegister) {
        await auth.register(_name.text.trim(), _email.text.trim(), _password.text);
      } else {
        await auth.login(_email.text.trim(), _password.text);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDark;
    final bg      = isDark ? AppColors.bg      : AppColors.bgLight;
    final surface = isDark ? AppColors.surface : AppColors.surfaceLight;
    final border  = isDark ? AppColors.border  : AppColors.borderLight;
    final textPrimary = isDark ? AppColors.textPrimary : AppColors.textPrimaryLight;
    final textMuted   = isDark ? AppColors.textMuted   : AppColors.textMutedLight;
    final textDim     = isDark ? AppColors.textDim     : AppColors.textDimLight;

    return Scaffold(
      backgroundColor: bg,
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.5, -0.9),
            radius: 1.1,
            colors: [
              AppColors.gold.withValues(alpha: isDark ? 0.06 : 0.04),
              bg,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  children: [
                    const SizedBox(height: 32),

                    // Logo
                    ShaderMask(
                      shaderCallback: (b) => AppColors.goldGlow.createShader(b),
                      child: Text('NEXUS',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 38, fontWeight: FontWeight.w800,
                          color: Colors.white, letterSpacing: -1.5)),
                    ),
                    const SizedBox(height: 6),
                    Text('Smart Expense Tracking & Loyalty',
                      style: GoogleFonts.dmSans(
                        fontSize: 13, color: textMuted)),
                    const SizedBox(height: 36),

                    // Auth card
                    Container(
                      padding: const EdgeInsets.all(26),
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: border),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
                            blurRadius: 40, offset: const Offset(0, 16)),
                        ],
                      ),
                      child: Column(
                        children: [
                          // Tab bar
                          Container(
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.04)
                                  : Colors.black.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.all(4),
                            child: TabBar(
                              controller: _tabs,
                              indicator: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [AppColors.gold, AppColors.mint]),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              indicatorSize: TabBarIndicatorSize.tab,
                              labelColor: Colors.white,
                              unselectedLabelColor: textMuted,
                              labelStyle: GoogleFonts.spaceGrotesk(
                                fontWeight: FontWeight.w600, fontSize: 14),
                              dividerColor: Colors.transparent,
                              tabs: const [Tab(text: 'Sign In'), Tab(text: 'Register')],
                            ),
                          ),
                          const SizedBox(height: 24),

                          Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_isRegister) ...[
                                  _label('Full Name', textDim),
                                  _field(_name, 'Your full name',
                                    isDark: isDark, border: border,
                                    textPrimary: textPrimary, textMuted: textMuted,
                                    validator: (v) => (v?.trim().isEmpty ?? true)
                                        ? 'Name is required' : null),
                                  const SizedBox(height: 16),
                                ],
                                _label('Email', textDim),
                                _field(_email, 'you@example.com',
                                  keyboard: TextInputType.emailAddress,
                                  isDark: isDark, border: border,
                                  textPrimary: textPrimary, textMuted: textMuted,
                                  validator: (v) {
                                    if (v == null || v.isEmpty) return 'Email is required';
                                    if (!v.contains('@')) return 'Enter a valid email';
                                    return null;
                                  }),
                                const SizedBox(height: 16),
                                _label('Password', textDim),
                                _field(_password, '••••••••',
                                  obscure: _obscure,
                                  isDark: isDark, border: border,
                                  textPrimary: textPrimary, textMuted: textMuted,
                                  suffix: IconButton(
                                    icon: Icon(
                                      _obscure ? Icons.visibility_off : Icons.visibility,
                                      color: textMuted, size: 18),
                                    onPressed: () => setState(() => _obscure = !_obscure),
                                  ),
                                  validator: (v) {
                                    if (v == null || v.isEmpty) return 'Password is required';
                                    if (v.length < 6) return 'Minimum 6 characters';
                                    return null;
                                  }),

                                if (_error != null) ...[
                                  const SizedBox(height: 16),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: AppColors.alert.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: AppColors.alert.withValues(alpha: 0.3)),
                                    ),
                                    child: Row(children: [
                                      const Icon(Icons.error_outline,
                                        color: AppColors.alert, size: 16),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(_error!,
                                        style: GoogleFonts.dmSans(
                                          color: AppColors.alert, fontSize: 13))),
                                    ]),
                                  ),
                                ],

                                const SizedBox(height: 20),
                                SizedBox(
                                  width: double.infinity, height: 50,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: AppColors.goldGlow,
                                      borderRadius: BorderRadius.circular(14),
                                      boxShadow: [
                                        BoxShadow(
                                          color: AppColors.gold.withValues(alpha: 0.3),
                                          blurRadius: 16, offset: const Offset(0, 6)),
                                      ],
                                    ),
                                    child: ElevatedButton(
                                      onPressed: _loading ? null : _submit,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.transparent,
                                        shadowColor: Colors.transparent,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(14)),
                                      ),
                                      child: _loading
                                          ? const SizedBox(width: 20, height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2, color: Colors.white))
                                          : Text(
                                              _isRegister ? 'Create Account' : 'Sign In',
                                              style: GoogleFonts.spaceGrotesk(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 15, color: Colors.white)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: GoogleFonts.dmSans(
      fontSize: 13, fontWeight: FontWeight.w500, color: color)),
  );

  Widget _field(
    TextEditingController ctrl,
    String hint, {
    required bool isDark,
    required Color border,
    required Color textPrimary,
    required Color textMuted,
    TextInputType keyboard = TextInputType.text,
    bool obscure = false,
    Widget? suffix,
    String? Function(String?)? validator,
  }) =>
    TextFormField(
      controller: ctrl,
      obscureText: obscure,
      keyboardType: keyboard,
      validator: validator,
      style: GoogleFonts.dmSans(color: textPrimary, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.dmSans(color: textMuted),
        suffixIcon: suffix,
        filled: true,
        fillColor: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.gold.withValues(alpha: 0.6)),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.alert.withValues(alpha: 0.5)),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.alert.withValues(alpha: 0.7)),
        ),
        errorStyle: GoogleFonts.dmSans(color: AppColors.alert),
      ),
    );
}
