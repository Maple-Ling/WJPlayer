import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdesign_flutter/tdesign_flutter.dart';

import 'app.dart';
import 'core/providers/app_providers.dart';
import 'core/providers/proxy_providers.dart';
import 'core/services/app_logger.dart';
import 'core/services/cache_service.dart';
import 'core/services/crash_diagnostics.dart';
import 'core/services/deep_link_service.dart';
import 'core/services/font_service.dart';
import 'core/services/secure_credential_store.dart';
import 'core/services/telemetry.dart';
import 'core/theme/app_motion.dart';
import 'core/providers/server_card_stats_provider.dart';
import 'plugins/plugin_system.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // WJPlayer 仅支持 Android 手机端，数据由 Android 应用沙箱管理。

  // 日志：尽早初始化文件落盘并捕获未处理异常，便于本地诊断。
  await AppLogger().init();
  AppLogger().installErrorHandlers();

  // 统一手机端动效基线（时长/曲线），见 core/theme/app_motion.dart
  AppMotion.applyGlobalDefaults();

  // TDesign 多主题：让 TDTheme.of(context) 从 Material 扩展按明暗取色（见 app_theme.dart）。
  TDTheme.needMultiTheme();

  // Android 使用原生 MPV（libplayer.so）与 ExoPlayer 平台通道。

  await initializeAppPreferences();

  // 服务器凭据安全存储：一次性把密码/Token 载入同步缓存并迁移旧明文。
  // 必须在 ProviderContainer 创建（服务器列表同步加载）之前完成。
  await SecureCredentialStore.instance.initialize();

  // 启动后台上报上次的原生崩溃回溯（Android），写入可导出的 App 日志便于定位。
  unawaited(CrashDiagnostics.reportRecentExits());

  // 自定义字体：按持久化路径重新加载（FontLoader 不跨进程，需每次启动重做），
  // 必须在构建 UI 前完成，确保首帧即用上用户字体。
  await FontService.initialize();

  // 代理：把持久化的自定义代理配置注入全局运行时（含 SOCKS 主机名预解析），
  // 必须在任何网络请求/客户端构建之前完成，确保首个请求即走代理。
  await initializeProxyRuntime();

  // Android 手机缓存策略（对内存较小的设备友好）：
  // - 内存只保留少量解码位图（~100MB/1000，LRU 回收），不常驻海量图。
  // - 磁盘持久化由 PersistentNetworkImageProvider 负责（图片 6GB 上限 + 14 天过期）。
  // - 视频播放缓存走 mpv 磁盘缓存（见 mpv 适配器），不占内存。
  CacheService.configureMemoryCache();
  // 启动清理放后台，不阻塞启动。
  unawaited(CacheService.runStartupCleanup());

  // 服务器卡片影视数量：每次冷启动清空内存缓存，进入服务器列表时重新
  // 拉取，保证打开软件即看到最新统计（会话内由 TTL 防抖，不频繁请求）。
  resetServerStatsCache();

  // 插件系统：共享同一个 ProviderContainer，便于插件 ctx 读取应用状态。
  final container = ProviderContainer();
  await initializePluginSystem(container);

  // Android 手机端是唯一应用入口。
  const Widget appWidget = WJPlayerApp();

  // 统一启动边界；二创版默认不连接任何第三方遥测服务。
  await Telemetry.runGuarded(() {
    runApp(
      UncontrolledProviderScope(
        container: container,
        child: appWidget,
      ),
    );

    // 手机端插件状态由插件管理流程恢复。

    // 自定义协议深链(wjplayer://add-server …)：唤起即自动登录并添加服务器。
    // 共用同一 container，跨三端生效；放 runApp 之后，确保插件通道已就绪。
    unawaited(DeepLinkService(container).init());
  });
}
