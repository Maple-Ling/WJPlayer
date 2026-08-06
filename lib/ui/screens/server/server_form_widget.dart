import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/emby_api.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/server_providers.dart';
import '../../../core/sources/feiniu_backend.dart';
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

/// 服务器 添加/编辑 共用表单：名称(可空自动获取)/服务器备注/用户名/密码，
/// 连接并保存；下方加号可动态增删线路（每条：线路备注/协议(http·https)/地址/路径，
/// 路径固定显示默认 /）。粘贴完整网址时自动识别协议、主机和路径。
class ServerEditorForm extends ConsumerStatefulWidget {
  const ServerEditorForm({
    super.key,
    this.existing,
    this.allowInsecureTls = false,
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
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final List<_LineField> _lines = [];
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
    }
    if (widget.autoAddLine && !_isEdit && _lines.isEmpty) {
      _lines.add(_LineField());
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _remarkController.dispose();
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
      const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF687386));

  BoxDecoration get _cardDeco => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      );

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 14, bottom: 6),
        child: Text(text, style: _labelStyle),
      );

  InputDecoration _fieldDeco({String? hint, required IconData icon}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9AA3B2)),
        prefixIcon: Icon(icon, size: 20, color: const Color(0xFF98A1B1)),
        filled: true,
        fillColor: const Color(0xFFF0F2F5),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: const BorderSide(color: Color(0xFF5B8DEF), width: 1.5),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: const Color(0xFFF4F6F9),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 36),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
          decoration: _cardDeco,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _fieldLabel('服务器名称'),
              TextField(
                controller: _nameController,
                decoration: _fieldDeco(
                    hint: '留空则自动获取', icon: Icons.dns_outlined),
              ),
              const SizedBox(height: 14),
              _fieldLabel('服务器备注（例如：到期时间、归属）'),
              TextField(
                controller: _remarkController,
                decoration: _fieldDeco(
                    hint: '服务器全局备注，与线路备注无关',
                    icon: Icons.notes_rounded),
              ),
              const SizedBox(height: 14),
              _fieldLabel('用户名'),
              TextField(
                controller: _usernameController,
                decoration: _fieldDeco(
                    hint: '服务器登录用户名', icon: Icons.person_outline_rounded),
                keyboardType: TextInputType.text,
                autocorrect: false,
              ),
              const SizedBox(height: 14),
              _fieldLabel('密码'),
              TextField(
                controller: _passwordController,
                decoration: _fieldDeco(
                    hint: '服务器登录密码', icon: Icons.lock_outline_rounded),
                obscureText: true,
                autocorrect: false,
              ),
              if (_isEdit) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F2F5),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('信任自签名证书',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: const Text('仅对自签名证书的服务器开启',
                        style: TextStyle(fontSize: 11)),
                    value: _allowInsecureTls,
                    onChanged: (v) => setState(() => _allowInsecureTls = v),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: _sectionTitle('服务器线路')),
                _addLineButton(),
              ]),
              const SizedBox(height: 4),
              Text(
                '支持粘贴完整网址，自动识别协议、主机和路径',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF8B95A5), fontSize: 11),
              ),
              const SizedBox(height: 10),
              if (_lines.isEmpty)
                _emptyLinesHint()
              else
                ...List.generate(_lines.length, (i) => _buildLineCard(i)),
              if (_errorMessage != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(_errorMessage!,
                      style: TextStyle(
                          color: theme.colorScheme.onErrorContainer)),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF4A7BD0),
                    shape: const StadiumBorder(),
                    elevation: 4,
                    shadowColor: const Color(0x555B8DEF),
                  ),
                  onPressed: _isLoading ? null : _saveAndConnect,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2,
                              color: Colors.white))
                      : const Icon(Icons.link_rounded),
                  label: Text(_isEdit ? '保存并连接' : '连接并保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(text, style: _labelStyle);

  Widget _addLineButton() => Material(
        color: const Color(0xFFEAF1FF),
        shape: const CircleBorder(),
        child: IconButton(
          tooltip: '新增线路',
          visualDensity: VisualDensity.compact,
          onPressed: _addLine,
          icon: const Icon(Icons.add, color: Color(0xFF4A7BD0), size: 20),
        ),
      );

  Widget _emptyLinesHint() => Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Text('暂无线路，点击右侧 + 添加',
            style: TextStyle(color: Color(0xFF8B95A5), fontSize: 12)),
      );

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
          _fieldLabel('线路备注（如：备用线路、电信宽带）'),
          TextField(
            controller: line.remarkController,
            decoration: _fieldDeco(
                hint: '仅用于备注这条线路', icon: Icons.notes_rounded),
          ),
          const SizedBox(height: 12),
          _fieldLabel('服务器地址'),
          ProtocolAddressField(
            controller: line.urlController,
            label: '服务器地址',
            hint: 'example.com:8096 或粘贴完整网址',
            initialProtocol: line.protocol,
            onProtocolChanged: (v) => line.protocol = v,
            // 粘贴完整网址：自动把路径剥离并填入下方路径输入框。
            onPathExtracted: (path) {
              line.pathController.text = path;
            },
          ),
          const SizedBox(height: 12),
          _fieldLabel('路径'),
          TextField(
            controller: line.pathController,
            decoration: _fieldDeco(
                hint: '默认 /，如 /emby', icon: Icons.folder_open_rounded),
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
    for (var index = 0; index < _lines.length; index++) {
      final line = _lines[index];
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
      final lines = _collectLines();

      if (lines.isEmpty) {
        if (_isEdit && widget.existing!.baseUrl.isNotEmpty) {
          // 编辑模式：用户删光了所有线路，沿用原 baseUrl 兜底。
        } else {
          throw Exception('请至少填写一条线路的服务器地址');
        }
      }
      final fullUrl = lines.isEmpty
          ? (_isEdit ? widget.existing!.baseUrl : '')
          : lines.first.url;

      // 编辑时沿用原 sourceKind；新增时用表单传入的 sourceKind。
      final sourceKind = _isEdit ? widget.existing!.sourceKind : widget.sourceKind;

      var userId = '';
      var authToken = '';
      var fallbackName = '';

      // 仅 Emby/Jellyfin 走 Emby 登录并拉取服务器信息；
      // 飞牛保存时主动登录一次拿 token 写入 authToken，避免运行时频繁 login 触发 429。
      final isEdit = _isEdit;
      // 地址是否变更：编辑模式下线路首地址与原有 baseUrl 不同视为"改了地址"。
      final urlChanged = isEdit && fullUrl != widget.existing!.baseUrl;
      if (sourceKind == SourceKind.emby) {
        final client = EmbyApiClient(baseUrl: fullUrl);
        // 需要连通校验的情形：添加模式（拦截坏服务器入库）、编辑且改了地址
        // （确认新地址可用）、或名称留空需自动获取。
        // 仅改备注/名称/凭据（地址未变）时跳过校验，服务器暂不可达也能保存。
        if (name.isEmpty || !isEdit || urlChanged) {
          try {
            final serverInfo = await client.server.getPublicInfo(fullUrl);
            fallbackName = serverInfo.serverName;
          } catch (_) {
            if (!isEdit || urlChanged) rethrow;
            // 编辑 + 地址未变 + 服务器暂不可达：名称留空时用主机名兜底，仍允许保存。
            fallbackName = Uri.tryParse(fullUrl)?.host ?? '';
          }
        }
        if (username.isNotEmpty) {
          try {
            final authResult =
                await client.auth.login(username: username, password: password);
            userId = authResult.userId;
            authToken = authResult.accessToken;
          } catch (_) {
            // 编辑模式：登录失败不阻塞保存，运行时用 password 重试（对齐飞牛）。
            if (!isEdit) rethrow;
          }
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
    // DioException 原文（如 "DioException [connectionError]: ..."）对用户不友好，
    // 先转成可读的中文提示，再走原有规则。
    if (e is DioException) {
      final status = e.response?.statusCode;
      final type = e.type;
      if (type == DioExceptionType.connectionTimeout ||
          type == DioExceptionType.receiveTimeout ||
          type == DioExceptionType.sendTimeout) {
        return '连接服务器超时，请检查地址、端口和当前网络';
      }
      if (type == DioExceptionType.connectionError ||
          type == DioExceptionType.unknown && e.message?.contains('SocketException') == true) {
        return '无法连接服务器：\n1. 地址或端口是否正确\n2. 当前网络是否能访问该服务器';
      }
      if (status != null) {
        if (status == 400) {
          return '服务器返回 400 错误，可能原因：\n1. URL 路径重复（如 /emby/emby）\n2. 服务器不是 Emby/Jellyfin\n3. 需要修改路径（尝试将路径改为 / 或其他）\n\n请检查浏览器中能访问的完整地址，确保和输入一致';
        }
        if (status == 401) return '认证失败：用户名或密码错误';
        if (status == 403) return '访问被拒绝';
        if (status == 404) return '服务器接口不存在，请检查 URL 和路径是否正确';
        if (status == 502) return '服务器网关错误';
        if (status >= 500) return '服务器内部错误（HTTP $status）';
      }
      return '服务器请求失败：${e.message ?? e.type.name}';
    }
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
