import 'package:flutter/material.dart';

import '../manager/plugin_manager.dart';
import '../models/plugin_extension_point.dart';
import '../../ui/widgets/common/app_toast.dart';

/// 渲染一个插件「设置页」扩展（settingsPages）。
///
/// 支持声明式表单：扩展描述里给出 `fields`（字段 schema），可选 `load`/`submit` handler：
///  - load() -> 返回初始值 {key: value}
///  - submit(values) -> 保存
class PluginSettingsPageHost extends StatefulWidget {
  final PluginExtension extension;
  const PluginSettingsPageHost({super.key, required this.extension});

  @override
  State<PluginSettingsPageHost> createState() => _PluginSettingsPageHostState();
}

class _PluginSettingsPageHostState extends State<PluginSettingsPageHost> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _switches = {};
  bool _loading = true;

  List<Map> get _fields {
    final raw = widget.extension.data['fields'];
    if (raw is List) return raw.whereType<Map>().toList();
    return const [];
  }

  @override
  void initState() {
    super.initState();
    _initFields();
    _loadInitialValues();
  }

  void _initFields() {
    for (final f in _fields) {
      final key = '${f['key']}';
      final type = '${f['type'] ?? 'text'}';
      if (type == 'switch') {
        _switches[key] = f['default'] == true;
      } else {
        _controllers[key] = TextEditingController(
            text: f['default'] == null ? '' : '${f['default']}');
      }
    }
  }

  Future<void> _loadInitialValues() async {
    try {
      final loaded = await PluginManager.instance
          .invokeExtensionField(widget.extension, 'load', const []);
      if (loaded is Map) {
        for (final entry in loaded.entries) {
          final key = '${entry.key}';
          if (_switches.containsKey(key)) {
            _switches[key] = entry.value == true;
          } else if (_controllers.containsKey(key)) {
            _controllers[key]!.text =
                entry.value == null ? '' : '${entry.value}';
          }
        }
      }
    } catch (_) {
      // 忽略加载失败，使用默认值。
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _collect() {
    final out = <String, dynamic>{};
    for (final f in _fields) {
      final key = '${f['key']}';
      final type = '${f['type'] ?? 'text'}';
      if (type == 'switch') {
        out[key] = _switches[key] ?? false;
      } else if (type == 'number') {
        out[key] = num.tryParse(_controllers[key]?.text.trim() ?? '');
      } else {
        out[key] = _controllers[key]?.text ?? '';
      }
    }
    return out;
  }

  Future<void> _save() async {
    await PluginManager.instance
        .invokeExtensionField(widget.extension, 'submit', [_collect()]);
    if (mounted) {
      AppToast.show(context, '已保存');
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.extension.title ?? '插件设置';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final f in _fields) _buildField(f),
                const SizedBox(height: 24),
                if (_fields.isNotEmpty)
                  FilledButton(
                    onPressed: _save,
                    child: const Text('保存'),
                  )
                else
                  const Text('该插件未提供可编辑的设置项。'),
              ],
            ),
    );
  }

  Widget _buildField(Map f) {
    final key = '${f['key']}';
    final label = '${f['label'] ?? key}';
    final type = '${f['type'] ?? 'text'}';
    if (type == 'switch') {
      return SwitchListTile(
        title: Text(label),
        value: _switches[key] ?? false,
        onChanged: (v) => setState(() => _switches[key] = v),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: _controllers[key],
        obscureText: type == 'password',
        keyboardType:
            type == 'number' ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          hintText: f['hint'] == null ? null : '${f['hint']}',
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
