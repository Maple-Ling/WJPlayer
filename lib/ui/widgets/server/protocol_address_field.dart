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
    this.initialProtocol = ServerProtocol.https,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final ValueChanged<ServerProtocol>? onProtocolChanged;
  final ServerProtocol initialProtocol;

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
    final lower = raw.trim().toLowerCase();
    final ServerProtocol? next = lower.startsWith('http://')
        ? ServerProtocol.http
        : lower.startsWith('https://')
            ? ServerProtocol.https
            : null;
    if (next == null) return;
    final host = raw
        .trim()
        .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
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
