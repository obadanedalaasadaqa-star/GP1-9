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
  // Indigo Tide palette: navy ink, indigo hero, pale sky-blue action.
  // Names kept from the old theme so every screen still compiles; the
  // values are the new ones.
  static const ink      = Color(0xFF242649);
  static const paper    = Color(0xFFF1F1F1);
  static const lime     = Color(0xFFB2D3EB); // the action colour (sky blue)
  static const cobalt   = Color(0xFF263B84); // hero indigo
  static const lavender = Color(0xFF364989);
  static const pink     = Color(0xFFB2D3EB);
  static const cobaltSoft  = Color(0xFFCDDFEF); // text on cobalt
  static const cobaltLight = Color(0xFF65A7D3); // cobalt on ink
  static const dotted   = Color(0xFFA9AAB6);    // dotted leaders, tracks

  // Status colours stay warm so errors and warnings still stand out.
  static const coral    = Color(0xFFFF5A3C);    // error
  static const amber    = Color(0xFFFFB627);    // warning
  static const teal     = Color(0xFF19B39A);    // success
  static const danger   = Color(0xFFC93A1E);    // coral readable as text
  static const coralText = Color(0xFFFF8F7A);   // coral readable as text on ink

  // Indigo Tide blues for categories and page backgrounds.
  static const tide1 = Color(0xFF386CAF);
  static const tide2 = Color(0xFF65A7D3);
  static const tide3 = Color(0xFF364989);
  static const tide4 = Color(0xFFB2D3EB);
  static const tide5 = Color(0xFFCDDFEF);
  static const pageAi      = tide4;
  static const pageBudgets = tide5;
  static const pageVerify  = tide2;

  // Dark mode (ink)
  static const bg      = ink;
  static const surface = Color(0xFF404261); // sheets, cards
  static const border  = Color(0xFF545671); // rows, hairlines
  static const raised  = Color(0xFF545671);

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
  static const textMuted   = Color(0xFFC2C2CC);
  static const textDim     = Color(0xFFD8D8DE);

  // Light mode (paper)
  static const bgLight          = paper;
  static const surfaceLight     = Color(0xFFFFFFFF);
  static const borderLight      = Color(0xFFC8C8CF);
  static const textPrimaryLight = ink;
  static const textMutedLight   = Color(0xFF66677F);
  static const textDimLight     = Color(0xFF3D3E5D);

  // Kept for old call sites: a flat fill (no gradient in this design).
  static const goldGlow = LinearGradient(colors: [lime, lime]);
}

/// Colour for each receipt category, shared by every screen.
class CategoryColors {
  static const map = {
    'Supermarket': AppColors.tide1,
    'Food':        AppColors.tide2,
    'Pharmacy':    AppColors.tide3,
    'Clothing':    AppColors.tide4,
    'Electronics': AppColors.tide5,
  };

  /// Colour for [category], muted for unknown ones.
  static Color of(String category) => map[category] ?? AppColors.textMuted;
}
