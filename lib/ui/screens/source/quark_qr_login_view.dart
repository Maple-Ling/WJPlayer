import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/providers/server_providers.dart';
import '../../../core/sources/quark_qr_login.dart';

/// 夸克扫码登录视图（三端共用）。自管 [QuarkQrLogin] 状态机，成功时回调
/// [onSuccess] 把构造好的 [ServerConfig] 交给上层落库 + 跳转。
class QuarkQrLoginView extends StatefulWidget {
  /// 取当前备注名（扫码成功时用）。
  final ValueGetter<String> currentName;
  final ValueChanged<ServerConfig> onSuccess;

  /// 非空表示「重新登录」：扫码成功后把凭据写回该既有 server id，不新建服务器。
  final String? existingServerId;

  const QuarkQrLoginView({
    super.key,
    required this.currentName,
    required this.onSuccess,
    this.existingServerId,
  });

  @override
  State<QuarkQrLoginView> createState() => _QuarkQrLoginViewState();
}

class _QuarkQrLoginViewState extends State<QuarkQrLoginView> {
  QuarkQrLogin? _login;
  bool _delivered = false;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  void _restart() {
    _login?.removeListener(_onChanged);
    _login?.dispose();
    final login = QuarkQrLogin(
      name: widget.currentName(),
      existingServerId: widget.existingServerId,
    );
    login.addListener(_onChanged);
    _login = login;
    login.start();
  }

  void _onChanged() {
    if (!mounted) return;
    final login = _login;
    if (login != null &&
        login.state == QuarkQrState.success &&
        login.server != null &&
        !_delivered) {
      _delivered = true;
      final server = login.server!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSuccess(server);
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _login?.removeListener(_onChanged);
    _login?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final login = _login;
    if (login == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 220,
          height: 220,
          child: Center(child: _buildQrArea(login)),
        ),
        const SizedBox(height: 16),
        Text(
          _statusText(login.state),
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
        ),
        if (login.state == QuarkQrState.error && login.errorMessage != null) ...[
          const SizedBox(height: 6),
          Text(login.errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        if (login.state == QuarkQrState.expired ||
            login.state == QuarkQrState.error) ...[
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () {
              _delivered = false;
              _restart();
            },
            child: const Text('重新获取二维码'),
          ),
        ],
      ],
    );
  }

  Widget _buildQrArea(QuarkQrLogin login) {
    switch (login.state) {
      case QuarkQrState.waiting:
        return Container(
          padding: const EdgeInsets.all(8),
          color: Colors.white,
          child: _qrContent(login.qrData ?? ''),
        );
      case QuarkQrState.success:
        return const Icon(Icons.check_circle, color: Colors.green, size: 64);
      case QuarkQrState.expired:
        return const Icon(Icons.timer_off, color: Colors.grey, size: 64);
      case QuarkQrState.error:
        return const Icon(Icons.error_outline, color: Colors.grey, size: 64);
      case QuarkQrState.loading:
        return const CircularProgressIndicator();
    }
  }

  /// 夸克 TV 的 `qr_data` 实际是**二维码 PNG 图片的 base64**（或 data URI），
  /// 不是待编码文本——直接当图片显示；只有在确实是普通文本/URL 时才回退 [QrImageView]。
  Widget _qrContent(String qrData) {
    final bytes = _tryDecodeImage(qrData);
    if (bytes != null) {
      return Image.memory(
        bytes,
        width: 200,
        height: 200,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _qrFromText(qrData),
      );
    }
    return _qrFromText(qrData);
  }

  Widget _qrFromText(String text) => QrImageView(
        data: text,
        version: QrVersions.auto,
        size: 200,
        backgroundColor: Colors.white,
      );

  /// 尝试把 [qrData] 解析为图片字节（data URI 前缀或裸 base64 的 PNG/JPEG/GIF）。
  /// 解析不出图片签名则返回 null（说明是普通文本/URL）。
  Uint8List? _tryDecodeImage(String qrData) {
    var s = qrData.trim();
    if (s.isEmpty) return null;
    final comma = s.indexOf(',');
    if (s.startsWith('data:image') && comma > 0) {
      s = s.substring(comma + 1);
    }
    try {
      final bytes = base64.decode(base64.normalize(s));
      if (_looksLikeImage(bytes)) return bytes;
    } catch (_) {}
    return null;
  }

  bool _looksLikeImage(Uint8List b) {
    if (b.length < 4) return false;
    // PNG 89 50 4E 47
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true;
    // JPEG FF D8 FF
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
    // GIF 47 49 46
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;
    return false;
  }

  String _statusText(QuarkQrState state) {
    switch (state) {
      case QuarkQrState.loading:
        return '正在获取二维码…';
      case QuarkQrState.waiting:
        return '请用手机夸克 App 扫码并确认登录';
      case QuarkQrState.success:
        return '登录成功，正在进入…';
      case QuarkQrState.expired:
        return '二维码已过期';
      case QuarkQrState.error:
        return '登录失败';
    }
  }
}
