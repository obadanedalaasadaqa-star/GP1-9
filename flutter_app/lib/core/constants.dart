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
  // Fable "receipt" palette. Names kept from the old theme so every screen
  // still compiles; the values are the new ones.
  static const ink      = Color(0xFF17142B);
  static const paper    = Color(0xFFECE9E1);
  static const lime     = Color(0xFFD8F34A);
  static const cobalt   = Color(0xFF2D3BE6);
  static const coral    = Color(0xFFFF5A3C);
  static const pink     = Color(0xFFFF8FC7);
  static const teal     = Color(0xFF19B39A);
  static const amber    = Color(0xFFFFB627);
  static const lavender = Color(0xFF6E69B8);
  static const cobaltSoft  = Color(0xFFDDE0FF); // text on cobalt
  static const cobaltLight = Color(0xFF8E97FF); // cobalt on ink
  static const danger   = Color(0xFFC93A1E);    // coral readable as text
  static const coralText = Color(0xFFFF8F7A);   // coral readable as text on ink
  static const dotted   = Color(0xFFB9B5C9);    // dotted leaders, tracks

  // Dark mode (ink)
  static const bg      = ink;
  static const surface = Color(0xFF262148); // sheets, cards
  static const border  = Color(0xFF3A3466); // rows, hairlines
  static const raised  = Color(0xFF3A3466);

  // Accents (old names → new roles)
  static const blue      = cobalt;
  static const blueLight = cobaltLight;
  static const violet    = lavender;
  static const mint      = teal;
  static const gold      = lime;    // the action / highlight colour
  static const green     = teal;
  static const red       = coral;
  static const alert     = coral;

  // Text on ink
  static const textPrimary = Color(0xFFFFFFFF);
  static const textMuted   = Color(0xFFC9C6DA);
  static const textDim     = Color(0xFFD5D2E6);

  // Light mode (paper)
  static const bgLight          = paper;
  static const surfaceLight     = Color(0xFFFFFFFF);
  static const borderLight      = Color(0xFFD5D2E6);
  static const textPrimaryLight = ink;
  static const textMutedLight   = Color(0xFF5A5670);
  static const textDimLight     = Color(0xFF3A3466);

  // Kept for old call sites: a flat lime fill (no gradient in this design).
  static const goldGlow = LinearGradient(colors: [lime, lime]);
}

/// Colour for each receipt category, shared by every screen.
class CategoryColors {
  static const map = {
    'Supermarket': AppColors.cobalt,
    'Food':        AppColors.coral,
    'Pharmacy':    AppColors.teal,
    'Clothing':    AppColors.pink,
    'Electronics': AppColors.amber,
  };

  /// Colour for [category], muted for unknown ones.
  static Color of(String category) => map[category] ?? AppColors.textMuted;
}
