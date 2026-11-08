import 'package:flutter/material.dart';

class AppConfig {
  // Online server (Render, HTTPS) by default. For local work run:
  //   flutter run --dart-define=API_BASE_URL=http://<your-LAN-IP>:3001/api
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://nexus-backend-e0di.onrender.com/api',
  );

  /// Socket.IO server (live receipts): the same host as [baseUrl], without /api.
  static String get socketUrl => baseUrl.endsWith('/api')
      ? baseUrl.substring(0, baseUrl.length - '/api'.length)
      : baseUrl;
}

class AppColors {
  // Dark palette (LedgerFlow-inspired navy)
  static const bg = Color(0xFF08111E);
  static const surface = Color(0xFF111D31);
  static const border = Color(0xFF1A2940);

  // Accent palette
  static const blue = Color(0xFF3B82F6);
  static const blueLight = Color(0xFF60A5FA);
  static const violet = Color(0xFF8C79FF);
  static const mint = Color(0xFF63D0C3);
  static const gold = Color(0xFFD6A046);
  static const green = Color(0xFF10B981);
  static const red = Color(0xFFEF4444);
  static const alert = Color(0xFFF06A63);

  // Text
  static const textPrimary = Color(0xFFF7F9FC);
  static const textMuted = Color(0xFFA6B5C6);
  static const textDim = Color(0xFFCBD5E1);

  // Light mode overrides
  static const bgLight = Color(0xFFF0F4FA);
  static const surfaceLight = Color(0xFFFFFFFF);
  static const borderLight = Color(0xFFDDE5F0);
  static const textPrimaryLight = Color(0xFF0F1A2E);
  static const textMutedLight = Color(0xFF64748B);
  static const textDimLight = Color(0xFF475569);

  // Gold → Mint gradient used on the center QR button and key accents
  static const goldGlow = LinearGradient(
    colors: [gold, mint],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

/// Colour for each receipt category, shared by every screen.
class CategoryColors {
  static const map = {
    'Supermarket': AppColors.blue,
    'Food':        AppColors.mint,
    'Pharmacy':    AppColors.violet,
    'Clothing':    AppColors.gold,
    'Electronics': AppColors.blueLight,
  };

  /// Colour for [category], muted for unknown ones.
  static Color of(String category) => map[category] ?? AppColors.textMuted;
}
