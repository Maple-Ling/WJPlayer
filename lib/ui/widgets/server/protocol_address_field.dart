import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum ServerProtocol { http, https }

class ProtocolAddressField extends StatefulWidget {
  const ProtocolAddressField({
    super.key,
    required this.controller,
    this.label = '服务器地址',
    this.hint = 'example.com:8096',
    this.onProtocolChanged,
    this.onPathExtracted,
    this.initialProtocol = ServerProtocol.https,
    this.focusNode,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final ValueChanged<ServerProtocol>? onProtocolChanged;

  /// 粘贴完整网址时，自动解析出的路径部分（如 /path/to/server）回调给外部，
  /// 用于填入该线路的路径输入框；解析为空或 / 时不回调。
  final ValueChanged<String>? onPathExtracted;
  final ServerProtocol initialProtocol;

  /// TV 集中焦点管理注入的地址输入框节点。
  final FocusNode? focusNode;

  @override
  State<ProtocolAddressField> createState() => _ProtocolAddressFieldState();
}

class _ProtocolAddressFieldState extends State<ProtocolAddressField> {
  ServerProtocol _protocol = ServerProtocol.https;
  bool _normalizing = false;

  String get scheme =>
      _protocol == ServerProtocol.http ? 'http://' : 'https://';
  String get fullUrl => '$scheme${widget.controller.text.trim()}';

  @override
  void initState() {
    super.initState();
    _protocol = widget.initialProtocol;
    _consumeCompleteUrl(widget.controller.text);
    widget.controller.addListener(_handleInput);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleInput);
    super.dispose();
  }

  void _handleInput() {
    if (_normalizing) return;
    _consumeCompleteUrl(widget.controller.text);
  }

  void _consumeCompleteUrl(String raw) {
    final trimmed = raw.trim();
    final lower = trimmed.toLowerCase();
    final ServerProtocol? next = lower.startsWith('http://')
        ? ServerProtocol.http
        : lower.startsWith('https://')
            ? ServerProtocol.https
            : null;
    if (next == null) return;
    // 完整网址：剥离协议 → 主机[:端口] 填入地址框，路径剥离 → 回调外部。
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return;
    final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    _normalizing = true;
    widget.controller.value = TextEditingValue(
      text: host,
      selection: TextSelection.collapsed(offset: host.length),
    );
    _normalizing = false;
    if (_protocol != next && mounted) {
      setState(() => _protocol = next);
      widget.onProtocolChanged?.call(next);
    }
    final path = uri.path;
    if (path.isNotEmpty && path != '/') {
      widget.onPathExtracted?.call(path);
    }
  }

  void _setProtocol(ServerProtocol value) {
    if (_protocol == value) return;
    setState(() => _protocol = value);
    widget.onProtocolChanged?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<ServerProtocol>(
          segments: const [
            ButtonSegment(value: ServerProtocol.http, label: Text('http://')),
            ButtonSegment(value: ServerProtocol.https, label: Text('https://')),
          ],
          selected: {_protocol},
          showSelectedIcon: false,
          onSelectionChanged: (value) => _setProtocol(value.first),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            prefixText: scheme,
            prefixIcon: const Icon(Icons.link_rounded),
            border: const OutlineInputBorder(),
          ),
          onChanged: _consumeCompleteUrl,
        ),
      ],
    );
  }
}

String protocolAddressValue(
    TextEditingController controller, ServerProtocol protocol) {
  final host = controller.text
      .trim()
      .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
  final scheme = protocol == ServerProtocol.http ? 'http://' : 'https://';
  return '$scheme$host';
}
