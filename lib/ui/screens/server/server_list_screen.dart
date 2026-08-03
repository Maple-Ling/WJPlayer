import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/emby_api.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/sources/anirss_backend.dart';
import '../../../core/sources/feiniu_backend.dart';
import '../../../core/sources/openlist_backend.dart';
import '../../../core/sources/source_http.dart';
import '../../../core/sources/source_kind.dart';
import '../../../core/theme/app_theme.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/media_widgets.dart';
import '../source/quark_qr_login_view.dart';

/// 服务器列表页面
class ServerListScreen extends ConsumerStatefulWidget {
  const ServerListScreen({super.key});

  @override
  ConsumerState<ServerListScreen> createState() => _ServerListScreenState();
}

class _ServerListScreenState extends ConsumerState<ServerListScreen> {
  String _searchQuery = '';
  bool _isSearching = false;
  bool _gridLayout = false;
  bool _revealHidden = false;
  int _titleTapCount = 0;
  DateTime? _lastTitleTap;

  @override
  void initState() {
    super.initState();
    _gridLayout = AppPreferencesStore.instance.getString('wjplayer_server_layout') == 'grid';
    // 延迟恢复当前服务器（等待serverListProvider加载完成）
    Future.microtask(() async {
      final servers = ref.read(serverListProvider);
      if (servers.isNotEmpty) {
        await ref.read(currentServerProvider.notifier).loadFromSaved(servers);
      }
    });
  }

  /// 连点三次顶部“服务器”标题：切换隐藏服务器显示/隐藏。
  void _onTitleTap() {
    final now = DateTime.now();
    if (_lastTitleTap != null &&
        now.difference(_lastTitleTap!).inMilliseconds > 700) {
      _titleTapCount = 0;
    }
    _lastTitleTap = now;
    _titleTapCount++;
    if (_titleTapCount >= 3) {
      _titleTapCount = 0;
      setState(() => _revealHidden = !_revealHidden);
      AppToast.show(context, _revealHidden ? '已显示隐藏服务器' : '已隐藏服务器');
    }
  }

  @override
  Widget build(BuildContext context) {
    final allServers = ref.watch(serverListProvider);
    var visible = _searchQuery.isEmpty
        ? allServers
        : allServers
            .where((s) =>
                s.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                s.remark?.toLowerCase().contains(_searchQuery.toLowerCase()) ==
                    true ||
                s.activeLineUrl
                    .toLowerCase()
                    .contains(_searchQuery.toLowerCase()))
            .toList();
    if (!_revealHidden) {
      visible = visible.where((s) => !s.hidden).toList();
    } else {
      // 显示隐藏时，隐藏的服务器排到最后。
      visible = [...visible.where((s) => !s.hidden), ...visible.where((s) => s.hidden)];
    }

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '搜索服务器...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(
                      color: Theme.of(context).textTheme.bodySmall?.color),
                ),
                style: TextStyle(
                    color: Theme.of(context).textTheme.bodyLarge?.color),
                onChanged: (value) => setState(() => _searchQuery = value),
              )
            : GestureDetector(
                onTap: _onTitleTap,
                child: const Text('服务器'),
              ),
        actions: [
          if (!_isSearching)
            IconButton(
              tooltip: _gridLayout ? '切换单排' : '切换双排',
              icon: Icon(_gridLayout ? Icons.view_agenda_rounded : Icons.grid_view_rounded),
              onPressed: () {
                final next = !_gridLayout;
                setState(() => _gridLayout = next);
                AppPreferencesStore.instance.setString('wjplayer_server_layout', next ? 'grid' : 'list');
              },
            ),
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) _searchQuery = '';
              });
            },
          ),
          if (!_isSearching) ...[
            // 下载入口已移除，右侧保留搜索与添加。
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () {
                context.push('/add');
              },
            ),
          ],
        ],
      ),
      body: visible.isEmpty
          ? _buildEmptyState(context)
          : _buildServerList(context, visible),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.dns_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            '暂无服务器',
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              context.push('/add');
            },
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        ],
      ),
    );
  }

  Widget _buildServerList(BuildContext context, List<ServerConfig> servers) {
    if (_gridLayout) {
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.12,
        ),
        itemCount: servers.length,
        itemBuilder: (context, index) {
          final server = servers[index];
          return _ServerCard(
            key: ValueKey(server.id),
            server: server,
            compact: true,
            onTap: () => _openServer(context, server),
            onMoreTap: () => _showServerMenu(context, ref, server),
          );
        },
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: servers.length,
      onReorder: (oldIndex, newIndex) {
        ref.read(serverListProvider.notifier).reorderServers(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final server = servers[index];
        return _ServerCard(
          key: ValueKey(server.id),
          server: server,
          onTap: () => _openServer(context, server),
          onMoreTap: () => _showServerMenu(context, ref, server),
        );
      },
    );
  }

  void _openServer(BuildContext context, ServerConfig server) {
    ref.read(currentServerProvider.notifier).state = server;
    if (server.authToken != null || server.isFileBrowse) {
      ref.read(authStateProvider.notifier).state = AuthState.authenticated;
    }
    final destination = server.sourceKind == SourceKind.feiniu
        ? '/home'
        : (server.isFileBrowse ? '/browse' : '/home');
    // push 而非 go：保留分支栈，从服务器首页返回时回到服务器管理页（而非跳转影视页）。
    context.push(destination);
  }

  void _showServerMenu(
      BuildContext context, WidgetRef ref, ServerConfig server) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑信息'),
              onTap: () {
                Navigator.pop(context);
                context.push('/edit/${server.id}');
              },
            ),
            ListTile(
              leading: const Icon(Icons.notes),
              title: const Text('修改备注'),
              onTap: () {
                Navigator.pop(context);
                _showEditRemarkDialog(context, ref, server);
              },
            ),
            ListTile(
              leading: Icon(
                  server.hidden
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  color: const Color(0xFF5B8DEF)),
              title: Text(server.hidden ? '显示卡片' : '隐藏卡片'),
              onTap: () {
                Navigator.pop(context);
                ref
                    .read(serverListProvider.notifier)
                    .setHidden(server.id, !server.hidden);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete,
                  color: Theme.of(context).colorScheme.error),
              title: Text('删除',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                _showDeleteConfirm(context, ref, server);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditRemarkDialog(
      BuildContext context, WidgetRef ref, ServerConfig server) {
    final controller = TextEditingController(text: server.remark);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改备注'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入备注...',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(serverListProvider.notifier).updateServer(
                    server.copyWith(remark: controller.text),
                  );
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirm(
      BuildContext context, WidgetRef ref, ServerConfig server) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除服务器 "${server.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(serverListProvider.notifier).removeServer(server.id);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 按源类型分流「重新登录」：夸克=扫码/Cookie，OpenList/Ani-rss=账密，Emby=账密。
  /// 修复此前所有源都弹 Emby 账密框的问题（扫码登录的夸克不该让用户输密码）。
  void _relogin(BuildContext context, WidgetRef ref, ServerConfig server) {
    switch (server.sourceKind) {
      case SourceKind.quark:
        _showQuarkRelogin(context, ref, server);
      case SourceKind.openlist:
      case SourceKind.anirss:
      case SourceKind.feiniu:
        _showSourceCredRelogin(context, ref, server);
      case SourceKind.emby:
        _showReloginDialog(context, ref, server);
    }
  }

  /// 夸克重新登录：复用扫码视图，凭据写回同一 server（不新建、不要求密码）。
  void _showQuarkRelogin(
      BuildContext context, WidgetRef ref, ServerConfig server) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新扫码登录夸克'),
        content: SizedBox(
          width: 300,
          child: QuarkQrLoginView(
            currentName: () => server.name,
            existingServerId: server.id,
            onSuccess: (_) {
              // 凭据已写回 SourceCredentialStore[server.id]，服务器记录无需改动。
              ref.read(currentServerProvider.notifier).state = server;
              ref.read(authStateProvider.notifier).state =
                  AuthState.authenticated;
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                AppToast.show(context, '夸克已重新登录');
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// OpenList / Ani-rss 重新登录：账密对自身后端鉴权，更新同一 server 的 token。
  void _showSourceCredRelogin(
      BuildContext context, WidgetRef ref, ServerConfig server) {
    final urlCtrl = TextEditingController(text: server.baseUrl);
    final userCtrl = TextEditingController(text: server.username ?? '');
    final passCtrl = TextEditingController();
    var loading = false;
    String? error;
    final kind = server.sourceKind;
    final label = switch (kind) {
      SourceKind.openlist => 'OpenList',
      SourceKind.feiniu => '飞牛影视',
      _ => 'Ani-rss',
    };

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('重新登录 $label'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                    labelText: '服务器地址', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: userCtrl,
                decoration: const InputDecoration(
                    labelText: '用户名', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: '密码', border: OutlineInputBorder()),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!,
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error, fontSize: 13)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: loading
                  ? null
                  : () async {
                      setDialogState(() {
                        loading = true;
                        error = null;
                      });
                      try {
                        final base = normalizeBaseUrl(urlCtrl.text.trim());
                        final user = userCtrl.text.trim();
                        final pass = passCtrl.text;
                        final token = switch (kind) {
                          SourceKind.openlist =>
                            await OpenListBackend.login(base, user, pass),
                          SourceKind.feiniu =>
                            await FeiniuBackend.login(base, user, pass),
                          _ => await AniRssBackend.login(base, user, pass),
                        };
                        final updated = server.copyWith(
                          baseUrl: base,
                          username: user,
                          password: pass,
                          authToken: token,
                        );
                        ref
                            .read(serverListProvider.notifier)
                            .updateServer(updated);
                        ref.read(currentServerProvider.notifier).state =
                            updated;
                        ref.read(authStateProvider.notifier).state =
                            AuthState.authenticated;
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setDialogState(() {
                          loading = false;
                          error = e.toString().replaceAll('Exception: ', '');
                        });
                      }
                    },
              child: loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }

  void _showReloginDialog(
      BuildContext context, WidgetRef ref, ServerConfig server) {
    final usernameCtrl = TextEditingController(text: server.username ?? '');
    final passwordCtrl = TextEditingController();
    var loading = false;
    var error = <String?>[];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('重新登录'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: usernameCtrl,
                decoration: const InputDecoration(
                    labelText: '用户名', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordCtrl,
                decoration: const InputDecoration(
                    labelText: '密码', border: OutlineInputBorder()),
                obscureText: true,
              ),
              if (error.isNotEmpty && error.first != null) ...[
                const SizedBox(height: 8),
                Text(error.first!,
                    style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error, fontSize: 13)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: loading
                  ? null
                  : () async {
                      setDialogState(() {
                        loading = true;
                        error = [];
                      });
                      try {
                        final client =
                            EmbyApiClient(baseUrl: server.activeLineUrl);
                        final authResult = await client.auth.login(
                          username: usernameCtrl.text.trim(),
                          password: passwordCtrl.text,
                        );
                        final updated = server.copyWith(
                          authToken: authResult.accessToken,
                          userId: authResult.userId,
                          username: usernameCtrl.text.trim(),
                        );
                        ref
                            .read(serverListProvider.notifier)
                            .updateServer(updated);
                        ref.read(currentServerProvider.notifier).state =
                            updated;
                        ref.read(authStateProvider.notifier).state =
                            AuthState.authenticated;
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setDialogState(() {
                          loading = false;
                          error = [e.toString().replaceAll('Exception: ', '')];
                        });
                      }
                    },
              child: loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerCard extends ConsumerWidget {
  final ServerConfig server;
  final bool compact;
  final VoidCallback onTap;
  final VoidCallback onMoreTap;

  const _ServerCard({
    super.key,
    required this.server,
    required this.onTap,
    required this.onMoreTap,
    this.compact = false,
  });

  String _date(DateTime value) {
    final local = value.toLocal();
    final date = '${local.year.toString().padLeft(4, '0')}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
    final days = DateTime.now().difference(local).inMinutes / 1440.0;
    return '$date·${days < 0.05 ? '刚刚' : '${days.toStringAsFixed(1)}天前'}观影';
  }

  Widget _stats(BuildContext context, ServerCardStats stats) {
    final color = Theme.of(context).textTheme.bodySmall?.color;
    Widget item(IconData icon, String label, int? value) => Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: compact ? 16 : 18, color: color),
              const SizedBox(height: 2),
              Text('${value ?? '—'}', style: TextStyle(fontSize: compact ? 11 : 12, fontWeight: FontWeight.w700, color: color)),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: compact ? 9 : 10, color: color)),
            ],
          ),
        );
    return Row(children: [
      item(Icons.movie_outlined, '电影', stats.movieCount),
      item(Icons.tv_outlined, '电视剧', stats.seriesCount),
      item(Icons.video_library_outlined, '媒体', stats.episodeCount),
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(serverCardStatsProvider(server.id));
    return Card(
      margin: EdgeInsets.only(bottom: compact ? 0 : 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.borderRadiusLarge),
        child: Padding(
          padding: EdgeInsets.all(compact ? 8 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: compact ? 32 : 48,
                  height: compact ? 32 : 48,
                  decoration: BoxDecoration(color: const Color(0xFF5B8DEF).withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
                  child: server.iconUrl != null
                      ? ClipRRect(borderRadius: BorderRadius.circular(12), child: MediaImage(imageUrl: server.iconUrl, width: 48, height: 48, fit: BoxFit.contain, useDefaultUserAgent: true, errorWidget: const EmbyDefaultIcon()))
                      : const Icon(Icons.dns, color: Color(0xFF5B8DEF)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(children: [
                    Flexible(
                      child: Text(server.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: compact ? 14 : 16,
                              fontWeight: FontWeight.w600)),
                    ),
                    if (server.hidden) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                            color: Color(0xFF5B8DEF), shape: BoxShape.circle),
                      ),
                    ],
                  ]),
                ),
                IconButton(icon: const Icon(Icons.more_vert), padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32), onPressed: onMoreTap),
              ]),
              const SizedBox(height: 8),
              stats.when(data: (value) => _stats(context, value), loading: () => _stats(context, const ServerCardStats()), error: (_, __) => _stats(context, const ServerCardStats())),
              const SizedBox(height: 5),
              stats.when(data: (value) => Text(value.lastWatchedAt == null ? '暂无观影记录' : _date(value.lastWatchedAt!), style: TextStyle(fontSize: compact ? 11 : 12, color: Theme.of(context).textTheme.bodySmall?.color)), loading: () => const Text('最近观影 —', style: TextStyle(fontSize: 12)), error: (_, __) => const Text('最近观影 —', style: TextStyle(fontSize: 12))),
              if (server.remark?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 5),
                Text(server.remark!, maxLines: compact ? 1 : 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: compact ? 11 : 13, color: Theme.of(context).textTheme.bodySmall?.color)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
