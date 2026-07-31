import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Anime4K 超分档位 → GLSL shader 链的单一事实来源。
///
/// media_kit 内核（桌面/iOS）与 Android 原生 mpv 内核都从这里取档位对应的
/// shader 列表，并把打包在 assets 里的 .glsl 落地成真实文件路径喂给 mpv
/// （mpv 只能从文件系统读 shader）。以前档位映射只写在 media_kit 适配器里，
/// 原生 mpv 适配器拿不到映射 → Android 超分完全不生效，抽到这里两端共用。
///
/// 两档 = **AMD FSR / CAS 轻量实时算法**（解析型，非 CNN，游戏里 4K120 都能跑）。
/// ⚠️历史教训（2026-07 血泪）：曾用 Anime4K 去噪链 / ArtCNN（CNN，200KB+），在 media_kit 的
/// ANGLE 后端**又卡又蓝屏**（compute 版直接击穿驱动 BSOD，重片段版 GPU 超时 TDR）。真相是——
/// 别的播放器的「mpv 超分」用的就是 FSR/CAS 这类**轻量解析算法**（10KB/2KB），非重型 ML 超分。
///   - modeA（锐化·最安全）：CAS 对比度自适应锐化，**源分辨率就能跑**（无需抬渲染尺寸）、featherweight。
///   - modeAA（放大+锐化）：FSR1 EASU 边缘自适应放大 + RCAS 锐化；EASU 需「输出>源」才放大，
///     故配合适配器把渲染尺寸抬到窗口分辨率（见 [MpvPlayerAdapter._applyMpvRenderSizeForShaders]）。
/// 全部 `//!COMPUTE` 为 0（片段，ANGLE 安全，不蓝屏）。'off'/未知档位返回空列表(=关超分)。
/// 键名沿用 modeA/modeAA（持久化兼容），旧键自然落 off。
/// **Anime4K Medium 官方 A/B/C 六档**（用户指定，也是最常用的一套）。全部**片段着色器**
/// （HOOK MAIN，COMPUTE=0）→ ANGLE 安全不蓝屏；Anime4K 内部先 2x 放大再 AutoDownscalePre 降回
/// 渲染目标 → **无需 setSize 抬渲染尺寸**（setSize 在此机 dxva2-egl 坏 → 蓝屏，已彻底弃用），
/// 在源分辨率就能施加 CNN 细节增强、肉眼变清晰。六档为官方 Mode A/B/C 及其叠加组合：
///   A=Restore  B=Restore Soft  C=Upscale+Denoise  AA=A叠加  BB=B叠加  AC=C+A 组合。
const Map<String, List<String>> kAnime4KShaderPresets = {
  // Mode A：Restore_CNN_M
  'modeA': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
  // Mode B：Restore_CNN_Soft_M
  'modeB': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_Soft_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
  // Mode C：Upscale_Denoise
  'modeC': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
  // Mode A+A：双 Restore
  'modeAA': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
  // Mode B+B：双 Restore Soft
  'modeBB': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_Soft_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_Restore_CNN_Soft_M.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
  // Mode C+A：Upscale_Denoise + Restore
  'modeAC': [
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
  ],
};

/// [level] 是否为一个开启超分的有效档位（非 off / 非未知）。
bool isAnime4KLevelEnabled(String? level) =>
    level != null && kAnime4KShaderPresets.containsKey(level);

String _shaderFileName(String shaderRef) {
  final normalized = shaderRef.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash >= 0 ? normalized.substring(slash + 1) : normalized;
}

/// 把打包的 shader asset 落地成真实文件，返回其（正斜杠）路径。
/// 已存在且大小一致则跳过写入。
Future<String> _ensureShaderAssetFile(String shaderRef) async {
  final fileName = _shaderFileName(shaderRef);
  final assetPath = 'assets/mpv/shaders/$fileName';
  final supportDir = await getApplicationSupportDirectory();
  final shaderDir = Directory('${supportDir.path}/shaders');
  if (!shaderDir.existsSync()) {
    shaderDir.createSync(recursive: true);
  }

  final shaderFile = File('${shaderDir.path}/$fileName');
  final shaderData = await rootBundle.load(assetPath);
  final bytes = shaderData.buffer.asUint8List(
    shaderData.offsetInBytes,
    shaderData.lengthInBytes,
  );
  if (!shaderFile.existsSync() || await shaderFile.length() != bytes.length) {
    await shaderFile.writeAsBytes(bytes, flush: true);
  }
  return shaderFile.path.replaceAll('\\', '/');
}

/// 解析档位 → 已落地的 shader 文件路径列表。
/// 关闭 / 未知档位返回空列表。缺资源时抛出，让调用方回退提示。
Future<List<String>> resolveAnime4KShaderPaths(String? level,
    {bool native = false}) async {
  // native 参数已废弃（不再分 compute/片段两套；FSR/CAS 全片段、通吃）——保留形参兼容旧调用。
  final refs = level == null ? null : kAnime4KShaderPresets[level];
  if (refs == null || refs.isEmpty) return const [];
  final paths = <String>[];
  for (final ref in refs) {
    paths.add(await _ensureShaderAssetFile(ref));
  }
  return paths;
}
