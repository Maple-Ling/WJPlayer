// lib/ui/screens/settings/settings_config_sync.dart
// 局域网配置同步页（import 进 settings_screen.dart）：
//   · 接收端：启动本地 HTTP 服务 → 显示二维码（IP/端口/token）→
//     对方扫码后全量配置（服务器+弹幕源）自动写入。（TV 与手机均可用）
//   · 发送端：扫码（mobile_scanner）→ 收集本机配置 → 局域网推送。
//   · 手机入口页：二选一（同步到其它设备=扫码 / 从其它设备接收=二维码）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_interfaces.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/services/config_sync.dart';
import '../../../core/services/config_transfer.dart';
import '../../../core/utils/platform_utils.dart';

// ─── TV 接收端：显示二维码等待手机同步 ───

class ConfigSyncReceiverScreen extends ConsumerStatefulWidget {
  const ConfigSyncReceiverScreen({super.key});

  @override
  ConsumerState<ConfigSyncReceiverScreen> createState() =>
      _ConfigSyncReceiverScreenState();
}

class _ConfigSyncReceiverScreenState
    extends ConsumerState<ConfigSyncReceiverScreen> {
  String? _qrContent;
  String _status = '准备中…';
  ConfigSyncResult? _result;
  StreamSubscription<ConfigSyncResult>? _sub;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    // 注册配置应用回调（写服务器列表 + 弹幕源）。
    ConfigSyncService.onReceive = _applyConfig;
    _start();
  }

  Future<void> _start() async {
    setState(() => _status = '正在启动接收服务…');
    try {
      _qrContent = await ConfigSyncService.startReceiver();
      if (!mounted) return;
      setState(() => _status = '等待手机扫码同步…');
      _sub = ConfigSyncService.results.listen((result) {
        if (!mounted) return;
        setState(() {
          _result = result;
          _status = result.ok
              ? '同步成功：${result.serverCount} 台服务器、${result.danmakuCount} 个弹幕源'
              : '同步失败：${result.error ?? '未知错误'}';
        });
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '启动失败：$e');
    }
  }

  /// 应用手机同步来的配置：服务器（merge 合并）+ 弹幕源（SharedPreferences）。
  Future<void> _applyConfig(List<Object?> servers, String? danmakuJson) async {
    if (_applying) return;
    _applying = true;
    try {
      final incoming = servers.cast<ServerConfig>();
      final existing = ref.read(serverListProvider);
      final merged = ConfigTransfer.merge(existing, incoming);
      ref.read(serverListProvider.notifier).replaceServers(merged);
      if (danmakuJson != null && danmakuJson.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('danmaku_custom_sources', danmakuJson);
      }
    } finally {
      _applying = false;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    ConfigSyncService.onReceive = null;
    unawaited(ConfigSyncService.stopReceiver());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('接收配置同步')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '让其它设备把服务器与弹幕配置同步到本机',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                '对方设备打开「配置同步 → 同步到其它设备」扫此二维码',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              if (_qrContent != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: _qrContent!,
                    size: 260,
                    version: QrVersions.auto,
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(),
                ),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_result == null)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    )
                  else
                    Icon(
                      _result!.ok
                          ? Icons.check_circle_rounded
                          : Icons.error_rounded,
                      color: _result!.ok
                          ? const Color(0xFF34C759)
                          : const Color(0xFFE53935),
                      size: 18,
                    ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '同一局域网内有效；二维码含一次性令牌，同步一次后自动失效',
                style: TextStyle(
                    fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 手机发送端：扫码 TV 二维码 → 局域网推送配置 ───

class ConfigSyncSenderScreen extends ConsumerStatefulWidget {
  const ConfigSyncSenderScreen({super.key});

  @override
  ConsumerState<ConfigSyncSenderScreen> createState() =>
      _ConfigSyncSenderScreenState();
}

class _ConfigSyncSenderScreenState extends ConsumerState<ConfigSyncSenderScreen> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _pushing = false;
  String? _status;
  ConfigSyncResult? _result;

  @override
  void dispose() {
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_pushing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || !raw.startsWith(ConfigSyncService.qrPrefix)) {
      return; // 非本 App 同步二维码：忽略，继续扫。
    }
    _pushing = true;
    unawaited(_push(raw));
  }

  Future<void> _push(String qrContent) async {
    setState(() {
      _status = '正在同步到对方设备…';
      _result = null;
    });
    final result = await ConfigSyncService.sendToTv(
      qrContent,
      collectServers: () async {
        final servers = ref.read(serverListProvider);
        return ConfigTransfer.encode(servers);
      },
      collectDanmaku: () async {
        final prefs = await SharedPreferences.getInstance();
        return prefs.getString('danmaku_custom_sources');
      },
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _status = result.ok
          ? '同步成功：${result.serverCount} 台服务器、${result.danmakuCount} 个弹幕源已发送到对方设备'
          : '同步失败：${result.error ?? '未知错误'}';
      _pushing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('同步到其它设备')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _scannerController,
                  onDetect: _onDetect,
                ),
                // 取景框提示。
                IgnorePointer(
                  child: Center(
                    child: Container(
                      width: 240,
                      height: 240,
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.85),
                            width: 3),
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                if (_status != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            if (_result == null && _pushing)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white),
                              )
                            else if (_result != null)
                              Icon(
                                _result!.ok
                                    ? Icons.check_circle_rounded
                                    : Icons.error_rounded,
                                color: _result!.ok
                                    ? const Color(0xFF34C759)
                                    : const Color(0xFFE53935),
                                size: 22,
                              ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _status!,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '扫描对方设备显示的二维码，将本机服务器与弹幕配置同步过去',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 手机端入口：二选一（扫码发送 / 显示二维码接收）───

class ConfigSyncChoiceScreen extends StatelessWidget {
  const ConfigSyncChoiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('配置同步')),
      body: TvListArea(
        id: 'config_sync_choice',
        onBoundary: (_) => Navigator.of(context).pop(),
        child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '在手机之间或手机↔电视之间传输服务器与弹幕配置。\n'
            '发送方扫码，接收方显示二维码。',
            style: TextStyle(
                fontSize: 13, color: scheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 16),
          _SyncChoiceCard(
            icon: Icons.qr_code_scanner,
            title: '同步到其它设备（扫码）',
            subtitle: '扫描对方设备显示的二维码，把本机服务器与弹幕配置发送过去',
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                  builder: (_) => const ConfigSyncSenderScreen()),
            ),
          ),
          const SizedBox(height: 12),
          _SyncChoiceCard(
            icon: Icons.qr_code_2,
            title: '从其它设备接收（二维码）',
            subtitle: '本机显示二维码，让对方设备扫码把配置同步到本机',
            onTap: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                  builder: (_) => const ConfigSyncReceiverScreen()),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _SyncChoiceCard extends StatelessWidget {
  const _SyncChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: TvListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        leading: Icon(icon, size: 30, color: scheme.primary),
        title:
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
