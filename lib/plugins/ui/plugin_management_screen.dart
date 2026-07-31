import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/platform_utils.dart';
import '../manager/plugin_manager.dart';
import '../models/plugin_extension_point.dart';
import '../models/plugin_info.dart';
import '../providers/plugin_providers.dart';
import 'plugin_permission_dialog.dart';
import 'plugin_settings_page_host.dart';
import 'plugin_store_screen.dart';
import '../../ui/widgets/common/app_toast.dart';

/// 插件管理页（移动端）。负责安装、启用/禁用、查看权限、打开设置、卸载。
class PluginManagementScreen extends ConsumerWidget {
  const PluginManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(pluginManagerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('插件'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: '安装插件',
            onSelected: (v) {
              switch (v) {
                case 'store':
                  _openStore(context);
                case 'url':
                  _installFromUrl(context, manager);
                case 'file':
                  _install(context, manager);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'store',
                child: ListTile(
                  leading: Icon(Icons.storefront_outlined),
                  title: Text('插件市场'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'url',
                child: ListTile(
                  leading: Icon(Icons.link),
                  title: Text('从链接安装'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'file',
                child: ListTile(
                  leading: Icon(Icons.folder_open),
                  title: Text('从文件安装 (.ipk)'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final plugins = manager.plugins;
          if (plugins.isEmpty) {
            return const _EmptyState();
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: plugins.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) =>
                _PluginTile(info: plugins[i], manager: manager),
          );
        },
      ),
    );
  }

  void _openStore(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PluginStoreScreen(target: isDesktopPlatform ? 'pc' : 'mobile'),
      ),
    );
  }

  Future<void> _installFromUrl(
      BuildContext context, PluginManager manager) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从链接安装'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '粘贴 .ipk 安装包直链',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    if (!context.mounted) return;
    await _runInstall(context, () => manager.installFromUrl(url));
  }

  Future<void> _install(BuildContext context, PluginManager manager) async {
    // iOS 对 .ipk 这类未知扩展名无 UTType，FileType.custom 会被系统拒绝/抛错，
    // 故 iOS 放开为 FileType.any 让用户从「文件」App 里选；其余平台保留扩展名过滤。
    final result = await FilePicker.platform.pickFiles(
      type: Platform.isIOS ? FileType.any : FileType.custom,
      allowedExtensions: Platform.isIOS ? null : const ['ipk', 'lpk', 'zip'],
    );
    final path = result?.files.single.path;
    if (path == null || !context.mounted) return;
    await _runInstall(context, () => manager.install(path));
  }

  Future<void> _runInstall(
      BuildContext context, Future<PluginInfo> Function() install) async {
    try {
      final info = await install();
      if (context.mounted) {
        AppToast.show(context, '已安装 ${info.name}，请在列表中启用');
      }
    } catch (e) {
      if (context.mounted) {
        AppToast.show(context, '安装失败: $e', kind: AppToastKind.error);
      }
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.extension_outlined, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('还没有安装任何插件'),
          const SizedBox(height: 8),
          Text(
            '点击右上角 + 从插件市场 / 链接 / 文件安装',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _PluginTile extends StatelessWidget {
  final PluginInfo info;
  final PluginManager manager;
  const _PluginTile({required this.info, required this.manager});

  @override
  Widget build(BuildContext context) {
    final isLoading = info.status == PluginStatus.loading;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF5B8DEF).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.extension, color: Color(0xFF5B8DEF)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.name,
                          style:
                              const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        'v${info.version} · ${info.manifest.author}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (isLoading)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Switch(
                    value: info.isEnabled,
                    onChanged: (v) => _toggle(context, v),
                  ),
              ],
            ),
            if (info.manifest.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(info.manifest.description,
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (info.status == PluginStatus.error && info.error != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        size: 18, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        info.faulted ? '插件已被自动禁用：${info.error}' : '${info.error}',
                        style: const TextStyle(
                            color: Colors.red, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.lock_outline, size: 18),
                  label: const Text('权限'),
                  // 只读查看权限：启用请用上方开关。避免「点权限也能假启用」的歧义。
                  onPressed: () => showPluginPermissionConsent(
                      context, info.manifest,
                      viewOnly: true),
                ),
                _SettingsButton(info: info, manager: manager),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: Colors.red),
                  label: const Text('卸载',
                      style: TextStyle(color: Colors.red)),
                  onPressed: () => _uninstall(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, bool enable) async {
    if (enable) {
      final agreed =
          await showPluginPermissionConsent(context, info.manifest);
      if (!agreed) return;
      try {
        await manager.enable(info.id);
      } catch (e) {
        if (context.mounted) {
          AppToast.show(context, '启用失败: $e', kind: AppToastKind.error);
        }
      }
    } else {
      await manager.disable(info.id);
    }
  }

  Future<void> _uninstall(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('卸载插件'),
        content: Text('确定卸载「${info.name}」？其数据也将被保留在 plugin_data 目录。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('卸载')),
        ],
      ),
    );
    if (ok == true) {
      await manager.uninstall(info.id);
    }
  }
}

/// 设置入口：列出该插件的 settingsPages 扩展，点击进入或触发其 handler。
class _SettingsButton extends StatelessWidget {
  final PluginInfo info;
  final PluginManager manager;
  const _SettingsButton({required this.info, required this.manager});

  List<PluginExtension> get _pages => manager.registry
      .byType(PluginExtensionType.settingsPages)
      .where((e) => e.pluginId == info.id)
      .toList();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: manager.registry,
      builder: (context, _) {
        final pages = _pages;
        if (pages.isEmpty) return const SizedBox.shrink();
        return TextButton.icon(
          icon: const Icon(Icons.settings, size: 18),
          label: const Text('设置'),
          onPressed: () => _openSettings(context, pages),
        );
      },
    );
  }

  Future<void> _openSettings(
      BuildContext context, List<PluginExtension> pages) async {
    final page = pages.first;
    // 声明式表单 -> 进入表单页；否则直接触发 handler（插件自绘 UI）。
    final hasFields = page.data['fields'] is List;
    if (hasFields) {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PluginSettingsPageHost(extension: page),
      ));
    } else {
      await manager.triggerExtension(page);
    }
  }
}
