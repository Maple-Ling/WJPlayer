import 'dart:io';
import 'package:flutter/foundation.dart';

bool get isDesktopPlatform {
  if (kIsWeb) return false;

  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// 检测是否为 TV 平台（Android TV 或 Apple TV）
/// 通过环境变量或构建标志检测，可在编译时指定
bool get isTvPlatform {
  // 优先通过环境变量检测（构建时指定）
  const tvFlavor = String.fromEnvironment('FLAVOR', defaultValue: '');
  if (tvFlavor.toLowerCase().contains('tv')) {
    return true;
  }

  // 运行时检测（备用方案）
  // 检测是否有 Leanback 特征（Android TV）
  if (Platform.isAndroid) {
    // 检查是否有 com.google.android.tv 特征
    // 实际检测需要在 Android 原生层进行
    // 这里使用简化的检测逻辑
    return false; // 默认不启用，需通过构建标志指定
  }

  // Apple TV 检测（tvOS）
  // 通过 TargetPlatform 和编译标志检测
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    // 检查是否为 tvOS 构建
    // 实际检测需要在 iOS 原生层进行
    return false; // 默认不启用，需通过构建标志指定
  }

  return false;
}
