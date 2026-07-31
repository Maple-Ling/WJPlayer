import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/services/config_transfer.dart';
import '../../../core/utils/platform_utils.dart';

/// 配置迁移入口:本机出示二维码 / 扫码从其他设备导入。
/// 用户点名的形态——移动端扫码、TV/PC 出码;这里三端共用(桌面同样是 Material 设置)。
class ConfigMigrationScreen extends ConsumerWidget {
  const ConfigMigrationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(serverListProvider).length;
    return Scaffold(
      appBar: AppBar(title: const Text('配置迁移')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '在两台设备间搬服务器配置(含登录凭据)。出码端生成二维码,另一台扫一下即可,'
              '全程离线、不经过任何服务器。',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.qr_code_2, color: Color(0xFF5B8DEF)),
              title: const Text('出示二维码'),
              subtitle: Text('把本机 $count 个服务器打包成二维码,供新设备扫描'),
              trailing: const Icon(Icons.chevron_right),
              onTap: count == 0
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const ConfigQrExportScreen()),
                      ),
            ),
          ),
          // 相机扫码仅移动端(Android/iOS)可用；桌面只出码不扫码。
          if (!isDesktopPlatform) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading:
                    const Icon(Icons.qr_code_scanner, color: Color(0xFF5B8DEF)),
                title: const Text('扫码导入'),
                subtitle: const Text('扫描其他设备的二维码,导入其服务器配置'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ConfigQrScanScreen()),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 出码:把本机服务器打包成二维码。载荷过大(服务器过多)时提示改用文件备份。
class ConfigQrExportScreen extends ConsumerStatefulWidget {
  const ConfigQrExportScreen({super.key});

  @override
  ConsumerState<ConfigQrExportScreen> createState() =>
      _ConfigQrExportScreenState();
}

class _ConfigQrExportScreenState extends ConsumerState<ConfigQrExportScreen> {
  String? _payload;
  String? _error;

  @override
  void initState() {
    super.initState();
    _build();
  }

  Future<void> _build() async {
    try {
      final payload =
          await ConfigTransfer.encode(ref.read(serverListProvider));
      if (!mounted) return;
      if (payload.length > ConfigTransfer.maxQrChars) {
        setState(() => _error =
            '服务器较多,单个二维码放不下。请改用「设置 → 备份与恢复 → 导出备份」用文件迁移。');
      } else {
        setState(() => _payload = payload);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '生成失败:$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('出示二维码')),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(32),
                child: Text(_error!, textAlign: TextAlign.center),
              )
            : _payload == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(16),
                        color: Colors.white,
                        child: QrImageView(
                          data: _payload!,
                          version: QrVersions.auto,
                          size: 280,
                          errorCorrectionLevel: QrErrorCorrectLevel.M,
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          '在另一台设备打开「配置迁移 → 扫码导入」对准此码。'
                          '二维码含账号凭据,请勿外传或截图分享。',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

/// 扫码导入:相机扫到本 App 配置二维码 → 解码 → 合并进本机服务器列表 → 复活会话。
class ConfigQrScanScreen extends ConsumerStatefulWidget {
  const ConfigQrScanScreen({super.key});

  @override
  ConsumerState<ConfigQrScanScreen> createState() => _ConfigQrScanScreenState();
}

class _ConfigQrScanScreenState extends ConsumerState<ConfigQrScanScreen> {
  bool _handled = false;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    final raw = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (raw == null || !raw.startsWith('LPSYNC1:')) return; // 忽略无关二维码,继续扫
    _handled = true;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final incoming = await ConfigTransfer.decode(raw);
      if (incoming.isEmpty) throw const FormatException('二维码里没有可用的服务器');
      final merged =
          ConfigTransfer.merge(ref.read(serverListProvider), incoming);
      ref.read(serverListProvider.notifier).replaceServers(merged);
      await ref.read(currentServerProvider.notifier).loadFromSaved(
            merged,
            preferredServerId:
                ref.read(currentServerProvider)?.id ?? incoming.first.id,
          );
      ref.read(authStateProvider.notifier).state =
          serverHasUsableAuth(ref.read(currentServerProvider))
              ? AuthState.authenticated
              : AuthState.unauthenticated;
      messenger.showSnackBar(
        SnackBar(content: Text('已导入 ${incoming.length} 个服务器')),
      );
      navigator.pop();
    } catch (e) {
      _handled = false; // 允许重扫
      messenger.showSnackBar(SnackBar(content: Text('导入失败:$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码导入')),
      body: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          MobileScanner(onDetect: _onDetect),
          const Padding(
            padding: EdgeInsets.only(bottom: 48),
            child: Text(
              '将相机对准另一台设备上的配置二维码',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
