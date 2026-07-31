import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/app_identity.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/server_icon_cache.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/media_widgets.dart';

class IconSelectScreen extends ConsumerStatefulWidget {
  final String serverId;

  const IconSelectScreen({super.key, required this.serverId});

  @override
  ConsumerState<IconSelectScreen> createState() => _IconSelectScreenState();
}

class _IconSelectScreenState extends ConsumerState<IconSelectScreen> {
  // 默认图标源（四源分开显示，不合并）。gist 用 /raw 原始 JSON，套 gh-proxy 前缀免墙。
  static const List<({String name, String url})> _defaultSources = [
    (name: '综合图标库', url: 'https://zizhu.291277.xyz/icons-all.json'),
    (
      name: '图标源 2',
      url:
          'https://v4.gh-proxy.org/https://gist.github.com/zzzwannasleep/fe6e84f43fcd64672ec71302f48a01ea/raw/4629cb6a10abf954c2ccb2f1b20b9149ba6f1bd9/icons.json'
    ),
    (
      name: '图标源 3',
      url:
          'https://v4.gh-proxy.org/https://gist.github.com/zzzwannasleep/a52322ad8cf1dcf7462dd4a33816e0f4/raw/ab4b2e1a8390c0f1d4f5171e9f2b24fba832a32e/icons.json'
    ),
    (
      name: '图标源 4',
      url:
          'https://v4.gh-proxy.org/https://gist.github.com/zzzwannasleep/1da6e9d12cd9285980c6aba05855dede/raw/bc278c72ac514eba4f9fab48a54975feeeb7d386/icons.json'
    ),
  ];
  static const double _desktopBreakpoint = 960;

  final TextEditingController _searchController = TextEditingController();

  final List<NetworkIconLibrary> _libraries = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String? _selectedLibraryId;

  @override
  void initState() {
    super.initState();
    _reloadAll();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _isDesktopLayout =>
      MediaQuery.sizeOf(context).width >= _desktopBreakpoint;

  /// 当前选中的源（四源分开，不合并——方便逐源排查哪个源有问题）。
  NetworkIconLibrary? get _selectedLibrary {
    if (_libraries.isEmpty) return null;
    for (final lib in _libraries) {
      if (lib.id == _selectedLibraryId) return lib;
    }
    return _libraries.first;
  }

  List<IconItem> get _filteredIcons {
    final lib = _selectedLibrary;
    if (lib == null) return const [];
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return lib.icons;
    return lib.icons.where((icon) {
      final sourceName = icon.sourceName?.toLowerCase() ?? '';
      return icon.name.toLowerCase().contains(query) ||
          sourceName.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serverListProvider);
    final server = _findServer(servers);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _closePage,
          ),
          centerTitle: !_isDesktopLayout,
          title: const Text('图标选择'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '本地图片'),
              Tab(text: '网络图标库'),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: _isDesktopLayout ? 1160 : double.infinity,
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  _isDesktopLayout ? 24 : 16,
                  _isDesktopLayout ? 24 : 16,
                  _isDesktopLayout ? 24 : 16,
                  _isDesktopLayout ? 24 : 16,
                ),
                child: TabBarView(
                  children: [
                    _buildLocalTab(server),
                    _buildNetworkTab(server),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLocalTab(ServerConfig? server) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.24),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CurrentIconPreview(iconUrl: server?.iconUrl),
              const SizedBox(height: 20),
              Text(
                '选择本地图片',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _pickLocalImage,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text(_isDesktopLayout ? '浏览文件' : '选择图片'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNetworkTab(ServerConfig? server) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    final icons = _filteredIcons;
    final selectedId = _selectedLibrary?.id;

    return Column(
      children: [
        // 源选择条：四源分开，各带图标数（失败/0 一目了然，方便定位问题源）。
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _libraries.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final lib = _libraries[i];
              return _SourceChip(
                label: lib.name,
                count: lib.failed ? null : lib.icons.length,
                selected: lib.id == selectedId,
                onTap: () => setState(() {
                  _selectedLibraryId = lib.id;
                  _searchQuery = '';
                  _searchController.clear();
                }),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        // 工具条：搜索占主，添加源/刷新为小图标。
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                },
                decoration: InputDecoration(
                  hintText: '搜索图标',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: _clearSearch,
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '添加图标源',
              icon: const Icon(Icons.add_link_rounded),
              onPressed: _showAddSourceDialog,
            ),
            IconButton(
              tooltip: '刷新图标源',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _reloadAll,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: icons.isEmpty
              ? _NetworkEmptyState(
                  message: _searchQuery.isNotEmpty
                      ? '没有找到匹配的图标'
                      : (_selectedLibrary?.failed ?? true)
                          ? '该源加载失败'
                          : '该源没有可用图标',
                  buttonText: _searchQuery.isEmpty ? '重新加载' : '清空搜索',
                  onPressed:
                      _searchQuery.isEmpty ? _reloadAll : _clearSearch,
                )
              : LayoutBuilder(
                      builder: (context, constraints) {
                        final crossAxisCount =
                            _gridColumnCount(constraints.maxWidth);
                        return Scrollbar(
                          child: GridView.builder(
                            padding: EdgeInsets.zero,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              childAspectRatio: _isDesktopLayout ? 0.78 : 0.74,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                            itemCount: icons.length,
                            itemBuilder: (context, index) {
                              final icon = icons[index];
                              return _NetworkIconCard(
                                icon: icon,
                                selected: server?.iconUrl == icon.url,
                                onTap: () => _selectIcon(icon),
                              );
                            },
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  /// 并发拉取所有图标源（当前 [_libraries] 的地址，首次为默认 4 源），**四源分开保留**。
  /// 单个源失败/为空也保留占位（标记 failed），方便在源选择条上直接看出是哪个源出问题。
  Future<void> _reloadAll() async {
    final sources = _libraries.isEmpty
        ? _defaultSources.toList()
        : [for (final l in _libraries) (name: l.name, url: l.url)];

    if (mounted) {
      setState(() => _isLoading = true);
    }

    final results = await Future.wait(sources.map((s) async {
      try {
        return await _fetchLibrary(name: s.name, url: s.url, id: s.url);
      } catch (_) {
        // 失败也保留占位，用户能在源条上看到「图标源 X · 失败」。
        return NetworkIconLibrary(
            id: s.url, name: s.name, url: s.url, icons: const [], failed: true);
      }
    }));

    if (!mounted) {
      return;
    }

    setState(() {
      _libraries
        ..clear()
        ..addAll(results);
      // 选中项失效时回退到第一个源。
      if (!_libraries.any((l) => l.id == _selectedLibraryId)) {
        _selectedLibraryId = _libraries.isEmpty ? null : _libraries.first.id;
      }
      _isLoading = false;
    });
  }

  /// 去掉 gh-proxy 反代前缀，拿到直连 gist 地址（反代挂了时退回直连）。
  static String _stripGhProxy(String url) {
    const prefixes = [
      'https://v4.gh-proxy.org/',
      'https://v6.gh-proxy.org/',
      'https://gh-proxy.org/',
      'https://ghproxy.org/',
      'https://ghproxy.net/',
    ];
    for (final p in prefixes) {
      if (url.startsWith(p)) return url.substring(p.length);
    }
    return url;
  }

  Future<NetworkIconLibrary> _fetchLibrary({
    required String name,
    required String url,
    required String id,
  }) async {
    // 图标库 CDN 多拒绝 App UA，用中立浏览器 UA 请求 JSON。
    Future<dynamic> fetch(String u) async {
      final response = await Dio().get(
        u,
        options: Options(
          headers: const {'User-Agent': kDefaultBrowserUserAgent},
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      return response.data;
    }

    dynamic data;
    try {
      data = await fetch(url);
    } catch (_) {
      // 反代（gh-proxy）用不了就直接用默认直连链接，避免整个源 0/失败。
      final direct = _stripGhProxy(url);
      if (direct == url) rethrow;
      data = await fetch(direct);
    }
    final icons = _parseIconJson(jsonEncode(data));

    return NetworkIconLibrary(
      id: id,
      name: name,
      url: url,
      icons: icons,
    );
  }

  Future<void> _showAddSourceDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    bool submitting = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('添加图标库源'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: '名称',
                        hintText: '我的图标库',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: urlController,
                      decoration: const InputDecoration(
                        labelText: '源地址',
                        hintText: 'https://example.com/icons.json',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      submitting ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          final name = nameController.text.trim();
                          final url = urlController.text.trim();
                          if (url.isEmpty) {
                            AppToast.show(context, '请输入源地址');
                            return;
                          }

                          setDialogState(() {
                            submitting = true;
                          });

                          try {
                            final library = await _fetchLibrary(
                              name: name.isEmpty ? '自定义图标库' : name,
                              url: url,
                              id: url,
                            );

                            if (!mounted) {
                              return;
                            }

                            setState(() {
                              final existingIndex = _libraries.indexWhere(
                                (item) => item.id == library.id,
                              );
                              if (existingIndex == -1) {
                                _libraries.add(library);
                              } else {
                                _libraries[existingIndex] = library;
                              }
                              _selectedLibraryId = library.id;
                            });

                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                          } catch (_) {
                            if (!mounted) {
                              return;
                            }
                            AppToast.show(context, '添加源失败',
                                kind: AppToastKind.error);
                            setDialogState(() {
                              submitting = false;
                            });
                          }
                        },
                  child: submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('添加'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
    urlController.dispose();
  }

  Future<void> _pickLocalImage() async {
    final platform = defaultTargetPlatform;
    if (platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS) {
      await _pickFromFiles();
      return;
    }

    await _pickFromGallery();
  }

  Future<void> _pickFromGallery() async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        await _applyLocalIcon(image.path);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      AppToast.show(context, '选择图片失败', kind: AppToastKind.error);
    }
  }

  Future<void> _pickFromFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final path = result.files.first.path;
        if (path != null && path.isNotEmpty) {
          await _applyLocalIcon(path);
        }
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      AppToast.show(context, '选择文件失败', kind: AppToastKind.error);
    }
  }

  /// 选中的本地图片先复制进应用数据目录再落库，避免引用临时/原始路径：
  /// image_picker 给的是会被清理的缓存路径，file_picker 给的是原文件路径
  /// （用户移动/删除即损坏）。复制到 `应用支持目录/server_icons/` 才稳定持久。
  Future<void> _applyLocalIcon(String srcPath) async {
    final stable = await _persistLocalIcon(srcPath);
    if (!mounted) {
      return;
    }
    _updateServerIcon(stable ?? srcPath);
  }

  Future<String?> _persistLocalIcon(String srcPath) async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'server_icons'));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final ext = p.extension(srcPath).isNotEmpty
          ? p.extension(srcPath).toLowerCase()
          : '.png';
      // 文件名带时间戳：换图后路径变化，绕开 Image.file 对同路径文件的缓存。
      final dest = p.join(
        dir.path,
        '${widget.serverId}_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      await File(srcPath).copy(dest);
      // 清掉该服务器的旧图标文件，避免目录里堆积历史图。
      final prefix = '${widget.serverId}_';
      for (final entity in dir.listSync()) {
        if (entity is File &&
            p.basename(entity.path).startsWith(prefix) &&
            entity.path != dest) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
      return dest;
    } catch (_) {
      return null;
    }
  }

  void _updateServerIcon(String iconUrl) {
    final servers = ref.read(serverListProvider);
    final server = _findServer(servers);
    if (server == null) {
      return;
    }

    ref.read(serverListProvider.notifier).updateServer(
          server.copyWith(iconUrl: iconUrl),
        );
    _closePage();
  }

  Future<void> _selectIcon(IconItem icon) async {
    // 用户选了网络图标：立刻下载到本地并存**本地路径**，此后永远离线直接显示，
    // 不再每次启动重新拉取（拉取失败才退回存网络 URL）。
    final local =
        await ServerIconCache.persist(serverId: widget.serverId, url: icon.url);
    if (!mounted) return;
    _updateServerIcon(local ?? icon.url);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchQuery = '';
    });
  }

  void _closePage() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }

    context.go(_isDesktopLayout ? '/servers' : '/');
  }

  ServerConfig? _findServer(List<ServerConfig> servers) {
    for (final server in servers) {
      if (server.id == widget.serverId) {
        return server;
      }
    }
    return null;
  }

  List<IconItem> _parseIconJson(String jsonText) {
    final decoded = jsonDecode(jsonText);
    final items = <Map<String, dynamic>>[];
    final seenUrls = <String>{};

    void collect(dynamic value) {
      if (value is List) {
        for (final item in value) {
          collect(item);
        }
        return;
      }

      if (value is Map) {
        final map = value.map(
          (key, mapValue) => MapEntry(key.toString(), mapValue),
        );

        if (map['url'] is String) {
          items.add(map);
        }

        for (final nested in map.values) {
          collect(nested);
        }
      }
    }

    collect(decoded);

    final icons = <IconItem>[];
    for (final item in items) {
      final url = item['url'].toString();
      if (!seenUrls.add(url)) {
        continue;
      }

      final name =
          (item['name'] ?? item['title'] ?? item['label'])?.toString().trim();
      final sourceName =
          (item['sourceName'] ?? item['libraryName'] ?? item['source'])
              ?.toString()
              .trim();

      icons.add(
        IconItem(
          name: name == null || name.isEmpty ? '图标 ${icons.length + 1}' : name,
          url: url,
          sourceName:
              sourceName == null || sourceName.isEmpty ? null : sourceName,
        ),
      );
    }

    return icons;
  }

  int _gridColumnCount(double width) {
    if (width >= 1000) {
      return 6;
    }
    if (width >= 820) {
      return 5;
    }
    if (width >= 640) {
      return 4;
    }
    if (width >= 460) {
      return 3;
    }
    return 2;
  }
}

class NetworkIconLibrary {
  final String id;
  final String name;
  final String url;
  final List<IconItem> icons;
  final bool failed; // 拉取失败的占位源（源选择条上标「失败」）。

  const NetworkIconLibrary({
    required this.id,
    required this.name,
    required this.url,
    required this.icons,
    this.failed = false,
  });
}

class IconItem {
  final String name;
  final String url;
  final String? sourceName;

  const IconItem({
    required this.name,
    required this.url,
    this.sourceName,
  });
}

class _CurrentIconPreview extends StatelessWidget {
  final String? iconUrl;

  const _CurrentIconPreview({required this.iconUrl});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasIcon = iconUrl != null && iconUrl!.isNotEmpty;

    return Container(
      width: 112,
      height: 112,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      // MediaImage 现已兼容本地文件与网络地址，本地图标也能正常预览。
      child: hasIcon
          ? MediaImage(
              imageUrl: iconUrl,
              fit: BoxFit.contain,
              useDefaultUserAgent: true,
            )
          : Icon(
              Icons.image_outlined,
              size: 36,
              color: theme.colorScheme.outline,
            ),
    );
  }
}

/// 源选择胶囊：名称 + 图标数（失败标「失败」），选中高亮。
class _SourceChip extends StatelessWidget {
  final String label;
  final int? count; // null = 加载失败
  final bool selected;
  final VoidCallback onTap;

  const _SourceChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tail = count == null ? '失败' : '$count';
    final failed = count == null;
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.14)
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                tail,
                style: TextStyle(
                  fontSize: 12,
                  color: failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NetworkEmptyState extends StatelessWidget {
  final String message;
  final String buttonText;
  final VoidCallback onPressed;

  const _NetworkEmptyState({
    required this.message,
    required this.buttonText,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onPressed,
              child: Text(buttonText),
            ),
          ],
        ),
      ),
    );
  }
}

class _NetworkIconCard extends StatelessWidget {
  final IconItem icon;
  final bool selected;
  final VoidCallback onTap;

  const _NetworkIconCard({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = selected
        ? theme.colorScheme.primary
        : theme.dividerColor.withValues(alpha: 0.28);

    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    // 固定浅底：许多图标是深色/透明 logo，放深色底上会「全黑看不见」。
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: MediaImage(
                    imageUrl: icon.url,
                    fit: BoxFit.contain,
                    useDefaultUserAgent: true,
                    errorWidget: const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.black26,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                icon.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
