import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/emby_api.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/utils/server_batch_adder.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/server/protocol_address_field.dart';

/// 单条线路的编辑状态（控制器持有，避免 build 内重建丢失输入）。
class _LineField {
  _LineField({
    this.id,
    this.name = '',
    this.remark = '',
    this.protocol = ServerProtocol.https,
    this.path = '/',
    String? url,
  }) : nameController = TextEditingController(text: name),
       remarkController = TextEditingController(text: remark),
       pathController = TextEditingController(text: path),
       urlController = TextEditingController(text: url ?? '');

  final String? id;
  final String name;
  final String remark;
  final TextEditingController nameController;
  final TextEditingController remarkController;
  final TextEditingController pathController;
  final TextEditingController urlController;
  ServerProtocol protocol;
  String path;

  void dispose() {
    nameController.dispose();
    remarkController.dispose();
    pathController.dispose();
    urlController.dispose();
  }
}

/// 服务器 添加/编辑 共用表单：名称(可空自动获取)/备注/地址/路径/用户名/密码，
/// 连接并保存；下方加号可动态增删线路（每条：备注/地址(http·https)/路径，默认路径 /）。
class ServerEditorForm extends ConsumerStatefulWidget {
  const ServerEditorForm({
    super.key,
    this.existing,
    this.allowInsecureTls = false,
    this.hideMainUrl = false,
    this.autoAddLine = false,
    this.sourceKind = SourceKind.emby,
    this.onSaved,
  });

  /// 编辑模式传入现有服务器；新增模式为 null。
  final ServerConfig? existing;

  /// 服务器源类型：emby 走 Emby 登录；飞牛等走各自鉴权（懒登录）。
  final SourceKind sourceKind;

  /// 编辑模式下是否显示“信任自签名证书”开关。
  final bool allowInsecureTls;

  /// 编辑模式精简：隐藏主表单的 备注/服务器地址/路径（线路在下方统一编辑）。
  final bool hideMainUrl;

  /// 新增模式默认自动增加一条空线路。
  final bool autoAddLine;

  /// 保存成功回调（新增：携带新服务器；编辑：携带更新后的服务器）。
  final ValueChanged<ServerConfig>? onSaved;

  @override
  ConsumerState<ServerEditorForm> createState() => _ServerEditorFormState();
}

class _ServerEditorFormState extends ConsumerState<ServerEditorForm> {
  final _nameController = TextEditingController();
  final _remarkController = TextEditingController();
  final _urlController = TextEditingController();
  final _pathController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final List<_LineField> _lines = [];
  ServerProtocol _protocol = ServerProtocol.https;
  bool _isLoading = false;
  bool _allowInsecureTls = false;
  String? _errorMessage;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _allowInsecureTls = widget.allowInsecureTls;
    final s = widget.existing;
    if (s != null) {
      _nameController.text = s.name;
      _remarkController.text = s.remark ?? '';
      _pathController.text = s.activeLineUrl.isEmpty
          ? '/'
          : (Uri.tryParse(s.activeLineUrl)?.path ?? '/');
      _usernameController.text = s.username ?? '';
      _passwordController.text = s.password ?? '';
      for (final line in s.lines) {
        final uri = Uri.tryParse(line.url);
        final host = uri != null
            ? (uri.hasPort ? '${uri.host}:${uri.port}' : uri.host)
            : line.url;
        _lines.add(_LineField(
          id: line.id,
          name: line.name,
          remark: line.remark ?? '',
          protocol: uri != null && uri.scheme == 'http'
              ? ServerProtocol.http
              : ServerProtocol.https,
          path: (uri?.path.isEmpty == true ? '/' : uri?.path) ?? '/',
          url: host,
        ));
      }
    } else {
      _pathController.text = '/';
    }
    if (widget.autoAddLine && !_isEdit && _lines.isEmpty) {
      _lines.add(_LineField());
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _remarkController.dispose();
    _urlController.dispose();
    _pathController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _addLine() => setState(() => _lines.add(_LineField()));

  void _removeLine(int index) {
    setState(() => _lines.removeAt(index).dispose());
  }

  TextStyle get _labelStyle =>
      const TextStyle(fontSize: 14, fontWeight: FontWeight.w700);

  BoxDecoration get _cardDeco => BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(24),
      );

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: _labelStyle),
      );

  InputDecoration _fieldDeco({String? hint, required IconData icon}) =>
      InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        filled: true,
      );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16).copyWith(bottom: 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _fieldLabel('服务器名称'),
          TextField(
            controller: _nameController,
            decoration: _fieldDeco(hint: '留空则自动获取', icon: Icons.badge_outlined),
          ),
          const SizedBox(height: 14),
          if (!widget.hideMainUrl) ...[
            _fieldLabel('备注'),
            TextField(
              controller: _remarkController,
              decoration: _fieldDeco(hint: '选填', icon: Icons.notes),
            ),
            const SizedBox(height: 14),
            _fieldLabel('服务器地址'),
            ProtocolAddressField(
              controller: _urlController,
              label: '服务器地址',
              hint: 'example.com:8096',
              onProtocolChanged: (v) => _protocol = v,
            ),
            const SizedBox(height: 14),
            _fieldLabel('路径'),
            TextField(
              controller: _pathController,
              decoration: _fieldDeco(icon: Icons.folder),
            ),
            const SizedBox(height: 14),
          ],
          _fieldLabel('用户名'),
          TextField(
            controller: _usernameController,
            decoration: _fieldDeco(icon: Icons.person),
          ),
          const SizedBox(height: 14),
          _fieldLabel('密码'),
          TextField(
            controller: _passwordController,
            decoration: _fieldDeco(icon: Icons.lock),
            obscureText: true,
          ),
          if (_isEdit) ...[
            const SizedBox(height: 14),
            _fieldLabel('安全'),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('信任自签名证书'),
              subtitle: const Text('仅对自签名证书的服务器开启',
                  style: TextStyle(fontSize: 12)),
              value: _allowInsecureTls,
              onChanged: (v) => setState(() => _allowInsecureTls = v),
            ),
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                _errorMessage!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer),
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: _isLoading ? null : _saveAndConnect,
            child: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_isEdit ? '保存' : '连接并保存'),
          ),
          const SizedBox(height: 28),

          Row(children: [
            Text('服务器线路', style: _labelStyle),
            const SizedBox(width: 8),
            Expanded(
              child: Text('点 + 新增一行，无需单独保存',
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600)),
            ),
            IconButton(
              tooltip: '新增线路',
              onPressed: _addLine,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ]),
          if (_lines.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('暂无线路，点右上角 + 添加',
                  style: TextStyle(color: Colors.grey.shade500)),
            )
          else
            ...List.generate(_lines.length, (i) => _buildLineCard(i)),
        ],
      ),
    );
  }

  Widget _buildLineCard(int index) {
    final line = _lines[index];
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: _cardDeco,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text('线路 ${index + 1}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.delete_outline, color: Colors.red.shade300),
              onPressed: () => _removeLine(index),
            ),
          ]),
          TextField(
            controller: line.remarkController,
            decoration: _fieldDeco(hint: '线路备注', icon: Icons.notes),
          ),
          const SizedBox(height: 12),
          ProtocolAddressField(
            controller: line.urlController,
            label: '服务器地址',
            hint: 'example.com:8096',
            onProtocolChanged: (v) => line.protocol = v,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: line.pathController,
            decoration: _fieldDeco(icon: Icons.folder),
          ),
        ],
      ),
    );
  }

  /// 拼接完整地址：协议 + 主机 + 路径。
  String _fullUrl(String host, ServerProtocol protocol, String path) {
    final scheme = protocol == ServerProtocol.http ? 'http://' : 'https://';
    var full = '$scheme${host.trim()}';
    final p = path.trim();
    if (p.isNotEmpty && p != '/') {
      final clean = p.startsWith('/') ? p : '/$p';
      final base = full.endsWith('/') ? full.substring(0, full.length - 1) : full;
      if (!base.endsWith(clean)) full = '$base$clean';
    }
    return full;
  }

  List<ServerLine> _collectLines() {
    final result = <ServerLine>[];
    // 编辑模式隐藏了主地址：不重复添加默认线路，线路以下方列表为准。
    if (!widget.hideMainUrl) {
      final mainHost = _urlController.text.trim();
      if (mainHost.isNotEmpty) {
        result.add(ServerLine(
          id: 'default',
          name: _remarkController.text.trim().isEmpty
              ? '默认线路'
              : _remarkController.text.trim(),
          url: _fullUrl(mainHost, _protocol, _pathController.text),
          remark: _remarkController.text.trim().isEmpty
              ? null
              : _remarkController.text.trim(),
        ));
      }
    }
    for (final line in _lines) {
      final host = line.urlController.text.trim();
      if (host.isEmpty) continue;
      final remark = line.remarkController.text.trim();
      result.add(ServerLine(
        id: line.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        name: remark.isEmpty ? '线路 ${result.length + 1}' : remark,
        url: _fullUrl(host, line.protocol, line.pathController.text),
        remark: remark.isEmpty ? null : remark,
      ));
    }
    return result;
  }

  Future<void> _saveAndConnect() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final name = _nameController.text.trim();
      final remark = _remarkController.text.trim();
      final username = _usernameController.text.trim();
      final password = _passwordController.text;
      final mainHost = _urlController.text.trim();

      if (mainHost.isEmpty) {
        if (_isEdit && widget.existing!.baseUrl.isNotEmpty) {
          // 编辑模式隐藏了主地址，沿用原 baseUrl。
        } else {
          throw Exception('服务器地址不能为空');
        }
      }
      final fullUrl = mainHost.isEmpty
          ? (_isEdit ? widget.existing!.baseUrl : '')
          : _fullUrl(mainHost, _protocol, _pathController.text);
      final lines = _collectLines();

      // 编辑时沿用原 sourceKind；新增时用表单传入的 sourceKind。
      final sourceKind = _isEdit ? widget.existing!.sourceKind : widget.sourceKind;

      var userId = '';
      var authToken = '';
      var fallbackName = '';

      // 仅 Emby/Jellyfin 走 Emby 登录并拉取服务器信息；
      // 飞牛保存时主动登录一次拿 token 写入 authToken，避免运行时频繁 login 触发 429。
      if (sourceKind == SourceKind.emby) {
        final client = EmbyApiClient(baseUrl: fullUrl);
        final serverInfo = await client.server.getPublicInfo(fullUrl);
        fallbackName = serverInfo.serverName;
        if (username.isNotEmpty) {
          final authResult =
              await client.auth.login(username: username, password: password);
          userId = authResult.userId;
          authToken = authResult.accessToken;
        }
      } else if (sourceKind == SourceKind.feiniu) {
        if (username.isNotEmpty) {
          try {
            authToken = await FeiniuBackend.login(fullUrl, username, password);
          } catch (_) {
            // 登录失败不阻塞保存；运行时 _ensureToken 会用 password 重试。
          }
        }
        if (lines.isEmpty) {
          lines.add(ServerLine(
            id: 'default',
            name: '默认线路',
            url: fullUrl,
          ));
        }
      }

      final newId = _isEdit
          ? widget.existing!.id
          : DateTime.now().millisecondsSinceEpoch.toString();
      final server = ServerConfig(
        id: newId,
        name: name.isEmpty ? fallbackName : name,
        baseUrl: fullUrl,
        iconUrl: ServerBatchAdder.buildIconUrl(
          fullUrl,
          userId: userId.isEmpty ? null : userId,
          primaryImageTag: null,
        ),
        remark: remark.isEmpty ? null : remark,
        lines: lines,
        activeLineIndex: 0,
        username: username.isEmpty ? null : username,
        authToken: authToken.isEmpty ? null : authToken,
        userId: userId.isEmpty ? null : userId,
        password: password.isEmpty ? null : password,
        allowInsecureTls: _allowInsecureTls,
        sourceKind: sourceKind,
      );

      if (_isEdit) {
        ref.read(serverListProvider.notifier).updateServer(server);
        final current = ref.read(currentServerProvider);
        if (current?.id == server.id) {
          ref.read(currentServerProvider.notifier).state = server;
        }
      } else {
        ref.read(serverListProvider.notifier).addServer(server);
        ref.read(currentServerProvider.notifier).state = server;
        ref.read(authStateProvider.notifier).state = AuthState.authenticated;
      }
      widget.onSaved?.call(server);
    } catch (e) {
      setState(() => _errorMessage = _formatError(e));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 规范化提示（沿用原添加页逻辑）。
  String _formatError(dynamic e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('failed host lookup') ||
        msg.contains('no address associated with hostname') ||
        msg.contains('name or service not known') ||
        msg.contains('errno = 7')) {
      return '无法解析服务器地址，请检查：\n1. 域名是否拼写正确\n2. 当前网络是否能访问该域名\n3. 是否需要使用 http 而非 https';
    }
    if (msg.contains('400')) {
      return '服务器返回 400 错误，可能原因：\n1. URL 路径重复（如 /emby/emby）\n2. 服务器不是 Emby/Jellyfin\n3. 需要修改路径（尝试将路径改为 / 或其他）\n\n请检查浏览器中能访问的完整地址，确保和输入一致';
    }
    if (msg.contains('401')) return '认证失败：用户名或密码错误';
    if (msg.contains('403')) return '访问被拒绝';
    if (msg.contains('404')) return '服务器接口不存在，请检查 URL 和路径是否正确';
    if (msg.contains('502')) return '服务器网关错误';
    if (msg.contains('connection') ||
        msg.contains('timeout') ||
        msg.contains('refused')) {
      return '网络连接失败，请检查：\n1. 服务器地址和端口是否正确\n2. 当前网络是否能访问该服务器';
    }
    return e.toString().replaceAll('Exception: ', '');
  }
}
