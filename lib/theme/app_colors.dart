import 'package:flutter/material.dart';

/// Design system colors for ET_partners.
/// Based on the new design: Apple HIG + Industrial Black + Primary Green.
class AppColors {
  AppColors._();

  // ─── Primary (Deep Green) ────────────────────────────────────
  static const Color primary = Color(0xFF064E3B);
  static const Color primaryDim = Color(0xFF064E3B);
  static const Color primaryContainer = Color(0xFFECFDF5);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color onPrimaryContainer = Color(0xFF064E3B);

  // ─── Secondary (Horse Brown) ─────────────────────────────────
  static const Color secondary = Color(0xFF78350F);
  static const Color secondaryDim = Color(0xFF78350F);
  static const Color secondaryContainer = Color(0xFFFEF3C7);
  static const Color onSecondary = Color(0xFFFFFFFF);
  static const Color onSecondaryContainer = Color(0xFF78350F);

  // ─── Tertiary (Accent/Warm Brown) ────────────────────────────
  static const Color tertiary = Color(0xFF7C2D12);
  static const Color tertiaryFixed = Color(0xFF7C2D12);
  static const Color tertiaryContainer = Color(0xFFFFEDD5);
  static const Color onTertiary = Color(0xFFFFFFFF);

  // ─── Surface & Background (Cream) ────────────────────────────
  static const Color background = Color(0xFFF8F5EE);
  static const Color surface = Color(0xFFF8F5EE);
  static const Color surfaceBright = Color(0xFFF8F5EE);
  static const Color surfaceContainerLowest = Color(0xFFFDFCF9); // Warm Cream shade (replacing pure white)
  static const Color surfaceContainerLow = Color(0xFFF8F5EE);
  static const Color surfaceContainer = Color(0xFFF8F5EE);
  static const Color surfaceContainerHigh = Color(0xFFF1EDE4);
  static const Color surfaceContainerHighest = Color(0xFFE8E3D5);
  static const Color surfaceVariant = Color(0xFFF1EDE4);
  static const Color surfaceDim = Color(0xFFE2DCC9);

  // ─── On-Surface ──────────────────────────────────────────────
  static const Color onSurface = Color(0xFF1C1917);
  static const Color onSurfaceVariant = Color(0xFF57534E);
  static const Color onBackground = Color(0xFF1C1917);
  static const Color textSecondary = Color(0xFF57534E);

  // ─── Outline ─────────────────────────────────────────────────
  static const Color outline = Color(0xFFD6D3D1);
  static const Color outlineVariant = Color(0xFFE7E5E4);

  // ─── Inverse ─────────────────────────────────────────────────
  static const Color inverseSurface = Color(0xFF1C1917);
  static const Color inverseOnSurface = Color(0xFFF5F5F4);
  static const Color inversePrimary = Color(0xFFFFFFFF);

  // ─── Error ───────────────────────────────────────────────────
  static const Color error = Color(0xFFB91C1C);
  static const Color errorContainer = Color(0xFFFEE2E2);
  static const Color onError = Color(0xFFFFFFFF);

  // ─── Status ──────────────────────────────────────────────────
  static const Color statusSuccess = Color(0xFF064E3B);
  static const Color statusPending = Color(0xFFB45309);
  static const Color statusError = Color(0xFFB91C1C);

  // ─── Specific for Login ──────────────────────────────────────
  static const Color loginOnSurface = Color(0xFF1C1917);
  static const Color loginOnSurfaceVariant = Color(0xFF57534E);
}
