import 'package:flutter/material.dart';

/// 设计Token - 品牌色
class AppColors {
  AppColors._();
  
  // 品牌色: #5B8DEF (靛蓝)
  static const Color brand = Color(0xFF5B8DEF);
  static const Color brandLight = Color(0xFF8BB3F7);
  static const Color brandDark = Color(0xFF3B6FD0);
  
  // 浅色模式
  static const Color lightBackground = Color(0xFFF4F1EA);
  static const Color lightSurface = Color(0xFFFCFAF6);
  static const Color lightText = Color(0xFF1A1A1A);
  static const Color lightTextSecondary = Color(0xFF666666);
  static const Color lightDivider = Color(0xFFE0E0E0);
  
  // 深色模式
  static const Color darkBackground = Color(0xFF121212);
  static const Color darkSurface = Color(0xFF1E1E1E);
  static const Color darkText = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFFAAAAAA);
  static const Color darkDivider = Color(0xFF333333);
  
  // 功能色
  static const Color success = Color(0xFF4CAF50);
  static const Color warning = Color(0xFFFFA726);
  static const Color error = Color(0xFFEF5350);
  static const Color info = Color(0xFF42A5F5);
}
