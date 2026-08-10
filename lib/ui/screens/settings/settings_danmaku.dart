part of 'settings_screen.dart';

class DanmakuSettingsScreen extends ConsumerWidget {
  const DanmakuSettingsScreen({super.key});

  @override
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: Theme.of(context).brightness == Brightness.light
          ? AppColors.lightBackground
          : AppColors.darkBackground,
      appBar: AppBar(title: const Text('弹幕设置')),
      body: TvListArea(
        id: 'settings_danmaku',
        onBoundary: (_) => Navigator.of(context).pop(),
        child: body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: [
          // 其余弹幕开关/滑块均移至播放器弹幕按钮菜单内（播放中可直接调整），
          // 设置页仅保留弹幕源管理。
          const Divider(),
          TvListTile(
            title: const Text('自定义弹幕源'),
            subtitle: const Text('添加 danmu_api / 御坂弹幕 等自定义源'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showCustomSourceManager(context, ref),
          ),
        ],
      ),),

    );
  }

  /// 滑动条标题：左侧名称 + 右侧当前数值，方便边滑边看具体值。
  void _showCustomSourceManager(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _CustomSourceManagerSheet(),
    );
  }
}

class _CustomSourceManagerSheet extends ConsumerStatefulWidget {
  @override
  ConsumerState<_CustomSourceManagerSheet> createState() =>
      _CustomSourceManagerSheetState();
}

class _CustomSourceManagerSheetState
    extends ConsumerState<_CustomSourceManagerSheet> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  DanmakuAuthType _authType = DanmakuAuthType.pathToken;
  bool _isAdding = false;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  static const _authLabels = {
    DanmakuAuthType.none: '无鉴权',
    DanmakuAuthType.pathToken: 'huangxd 路径 Token',
    DanmakuAuthType.headerToken: 'misaka Token（请求头）',
    DanmakuAuthType.queryToken: 'Token（Query 参数）',
  };

  bool get _needsToken =>
      _authType == DanmakuAuthType.pathToken ||
      _authType == DanmakuAuthType.headerToken ||
      _authType == DanmakuAuthType.queryToken;

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(danmakuServiceProvider);
    final customSources = service.sources;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('自定义弹幕源',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (service.dandanplay != null)
                  Card(
                    child: TvListTile(
                      leading: const Icon(Icons.cloud, color: Colors.blue),
                      title: const Text('弹弹Play（官方）'),
                      subtitle: Text(
                        service.dandanplay!.hasCredentials
                            ? '默认源，内置签名凭据，无需配置'
                            : '默认源（当前构建未内置官方凭据）',
                      ),
                      trailing: Icon(
                        service.dandanplay!.hasCredentials
                            ? Icons.check_circle
                            : Icons.cloud_off,
                        color: service.dandanplay!.hasCredentials
                            ? Colors.green
                            : Colors.grey,
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: customSources.length,
                    itemBuilder: (context, index) {
                      final source = customSources[index];
                      return Card(
                        child: TvListTile(
                          leading: Icon(
                            Icons.dns,
                            color: source.config.enabled
                                ? Colors.green
                                : Colors.grey,
                          ),
                          title: Text(source.config.name),
                          subtitle: Text(source.config.apiUrl,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: source.config.enabled,
                                onChanged: (val) {
                                  ref
                                      .read(danmakuServiceProvider.notifier)
                                      .addCustomSource(
                                          source.config.copyWith(enabled: val));
                                },
                              ),
                              IconButton(
                                icon:
                                    const Icon(Icons.delete, color: Colors.red),
                                onPressed: () {
                                  ref
                                      .read(danmakuServiceProvider.notifier)
                                      .removeCustomSource(source.config.id);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(),
                if (_isAdding) ...[
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: '源名称',
                      hintText: '如：我的弹幕API',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'API地址',
                      hintText: '如: http://192.168.1.7:9321',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<DanmakuAuthType>(
                    initialValue: _authType,
                    decoration: const InputDecoration(
                      labelText: '鉴权方式',
                      border: OutlineInputBorder(),
                    ),
                    items: _authLabels.entries
                        .map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _authType = v);
                    },
                  ),
                  if (_needsToken) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _tokenController,
                      decoration: const InputDecoration(
                        labelText: 'Token',
                        hintText: '按各项目文档填入访问 token',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => setState(() => _isAdding = false),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _addSource,
                        child: const Text('添加'),
                      ),
                    ],
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: () => setState(() => _isAdding = true),
                    icon: const Icon(Icons.add),
                    label: const Text('添加自定义源'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _addSource() {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      AppToast.show(context, '请填写名称和API地址');
      return;
    }
    if (_needsToken && token.isEmpty) {
      AppToast.show(context, '当前鉴权方式需要填入 Token');
      return;
    }
    final cfg = DanmakuSourceConfig(
      id: const Uuid().v4(),
      type: DanmakuSourceType.custom,
      name: name,
      apiUrl: url,
      priority: ref.read(danmakuServiceProvider).sources.length,
      authType: _authType,
      token: _needsToken ? token : null,
    );
    ref.read(danmakuServiceProvider.notifier).addCustomSource(cfg);
    _nameController.clear();
    _urlController.clear();
    _tokenController.clear();
    setState(() => _isAdding = false);
    AppToast.show(context, '已添加 $name');
  }
}

/// 备份与恢复页
