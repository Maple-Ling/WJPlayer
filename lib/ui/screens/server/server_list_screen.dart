import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyEventResult, LogicalKeyboardKey;
import 'package:flutter_reorderable_grid_view/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/api/emby_api.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/providers/reveal_hidden_provider.dart';
import '../../../core/services/tv_focus_manager.dart';
import '../../../core/services/tv_key_channel.dart';
import '../../../core/sources/feiniu_backend.dart';
import '../../../core/sources/source_http.dart';
import '../../../core/sources/source_kind.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/platform_utils.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/media_widgets.dart';
import '../../widgets/common/tv_focusable.dart';
import '../../widgets/common/tv_focus_widgets.dart';

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
  int _titleTapCount = 0;
  DateTime? _lastTitleTap;
  // 双排长按拖动排序（flutter_reorderable_grid_view）需要共享 ScrollController。
  final ScrollController _gridScrollController = ScrollController();

  /// TV 排序模式：长按 OK 进入，方向键移动卡片位置，OK/返回退出。
  bool _sorting = false;
  int _sortingIndex = 0;

  /// 工具行元素数：0=标题「服务器」、1=布局切换、2=搜索、3=加号。
  static const int _toolCount = 4;

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
    if (isTvPlatform) registerGlobalKeyHandler(_handleMenuKey);
  }

  @override
  void dispose() {
    if (isTvPlatform) unregisterGlobalKeyHandler(_handleMenuKey);
    _gridScrollController.dispose();
    super.dispose();
  }

  /// TV 菜单键：服务器卡片聚焦时打开三点菜单（排序中屏蔽）。
  KeyEventResult _handleMenuKey(
      LogicalKeyboardKey key, KeyEventSource source, bool isRepeat, bool isUp) {
    if (key != LogicalKeyboardKey.contextMenu) return KeyEventResult.ignored;
    if (isUp) return KeyEventResult.ignored; // KeyUp 不处理（避免双触发）。
    if (_sorting) return KeyEventResult.handled;
    final manager = TvFocusManager.instance;
    final area = manager.activeArea;
    if (area == null || area.config.id != 'servers') {
      return KeyEventResult.ignored;
    }
    final index = area.focusIndex - _toolCount;
    if (index < 0) return KeyEventResult.ignored;
    final visible = _computeVisible();
    if (index >= visible.length) return KeyEventResult.ignored;
    _showServerMenu(context, ref, visible[index]);
    return KeyEventResult.handled;
  }

  /// 与 build 一致的可见服务器计算（隐藏过滤 + 隐藏项排后）。
  List<ServerConfig> _computeVisible() {
    final allServers = ref.read(serverListProvider);
    final revealHidden = ref.read(revealHiddenServersProvider);
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
    if (!revealHidden) {
      visible = visible.where((s) => !s.hidden).toList();
    } else {
      visible = [
        ...visible.where((s) => !s.hidden),
        ...visible.where((s) => s.hidden),
      ];
    }
    return visible;
  }

  /// TV 排序：方向键移动当前抖动卡片位置（单排仅上下，双排上下左右）。
  void _moveSortingCard(DPad direction) {
    final visible = _computeVisible();
    if (visible.isEmpty) return;
    final i = _sortingIndex.clamp(0, visible.length - 1);
    var target = i;
    if (_gridLayout) {
      switch (direction) {
        case DPad.up:
          target = i >= 2 ? i - 2 : i;
        case DPad.down:
          target = i + 2 < visible.length ? i + 2 : i;
        case DPad.left:
          target = i % 2 == 1 ? i - 1 : i;
        case DPad.right:
          target = (i % 2 == 0 && i + 1 < visible.length) ? i + 1 : i;
      }
    } else {
      switch (direction) {
        case DPad.up:
          target = i > 0 ? i - 1 : i;
        case DPad.down:
          target = i + 1 < visible.length ? i + 1 : i;
        case DPad.left:
        case DPad.right:
          return; // 单排不支持左右移动
      }
    }
    if (target == i) return;
    final ids = [for (final s in visible) s.id];
    final moved = ids.removeAt(i);
    ids.insert(target, moved);
    ref.read(serverListProvider.notifier).reorderByVisibleIds(ids);
    setState(() => _sortingIndex = target);
    // 焦点跟随抖动卡片（区域不重建，索引即位置）。
    TvFocusManager.instance.focusAt('servers', _toolCount + target);
  }

  void _exitSorting() {
    if (!_sorting) return;
    setState(() => _sorting = false);
  }

  /// TV 方向键遍历：0..3=工具行，4..=服务器卡片。
  /// 工具行：左右线性、上→状态栏、下→第一张卡；
  /// 卡片：单排上下线性（左右停留）、双排 2 列上下左右；首卡上→工具行加号、
  /// 末卡下→状态栏。
  TraversalFn _serversTraversal(int cardCount) {
    return (current, direction, nodes) {
      if (current < _toolCount) {
        switch (direction) {
          case DPad.left:
            return current > 0 ? current - 1 : current;
          case DPad.right:
            return current < _toolCount - 1 ? current + 1 : current;
          case DPad.up:
            return -1; // 工具行上键 → 状态栏
          case DPad.down:
            return _toolCount; // 工具行下键 → 第一张卡
        }
      }
      final ci = current - _toolCount;
      if (_gridLayout) {
        switch (direction) {
          case DPad.up:
            return ci >= 2 ? current - 2 : _toolCount - 1;
          case DPad.down:
            return ci + 2 < cardCount ? current + 2 : -1;
          case DPad.left:
            return ci % 2 == 1 ? current - 1 : current;
          case DPad.right:
            return (ci % 2 == 0 && ci + 1 < cardCount) ? current + 1 : current;
        }
      }
      switch (direction) {
        case DPad.up:
          return ci > 0 ? current - 1 : _toolCount - 1;
        case DPad.down:
          return ci + 1 < cardCount ? current + 1 : -1;
        case DPad.left:
        case DPad.right:
          return current; // 单排左右停留
      }
    };
  }

  /// 排序模式：方向键一律返回 -1，由 onBoundary 转 _moveSortingCard（焦点不动）。
  TraversalFn _sortingTraversal() => (current, direction, nodes) => -1;

  /// 连点三次顶部“服务器”标题：切换隐藏服务器显示/隐藏（纯功能，无提示）。
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
      // 三击显隐是全局状态（聚合搜索也跟随：显示出来的隐藏服务器可被搜索）。
      final next = !ref.read(revealHiddenServersProvider);
      ref.read(revealHiddenServersProvider.notifier).state = next;
    }
  }

  /// 首次把服务器设为隐藏时，提示顶部三连击的找回方式（全局只提示一次）。
  Future<void> _maybeShowHiddenTip(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('wjplayer_hidden_tip_shown') ?? false) return;
    await prefs.setBool('wjplayer_hidden_tip_shown', true);
    if (!context.mounted) return;
    AppToast.show(
      context,
      '小逼崽子，慌啥呢！顶部服务器三连击！',
      duration: const Duration(seconds: 10),
    );
  }

  /// 首次点「显示卡片」恢复隐藏服务器时的确认（全局只提示一次）。
  Future<void> _maybeShowUnhideTip(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('wjplayer_unhide_tip_shown') ?? false) return;
    await prefs.setBool('wjplayer_unhide_tip_shown', true);
    if (!context.mounted) return;
    AppToast.show(
      context,
      '小逼崽子，可算不怂了！',
      duration: const Duration(seconds: 10),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allServers = ref.watch(serverListProvider);
    final revealHidden = ref.watch(revealHiddenServersProvider);
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
    if (!revealHidden) {
      visible = visible.where((s) => !s.hidden).toList();
    } else {
      // 显示隐藏时，隐藏的服务器排到最后。
      visible = [...visible.where((s) => !s.hidden), ...visible.where((s) => s.hidden)];
    }

    // TV：非搜索且有可见服务器时注册焦点区域（工具行 + 服务器卡片）。
    final tvAreaReady = isTvPlatform && !_isSearching && visible.isNotEmpty;

    return PopScope(
      // TV：仅排序态拦截返回键（退出排序）；其余返回放行系统默认——
      // 逐级后退（编辑/添加页 pop）/分支根返回回影视 tab（与主流 TV 一致）。
      // 手机端不拦截（零副作用）。
      canPop: !isTvPlatform || !_sorting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_sorting) {
          _exitSorting();
          return;
        }
      },
      child: tvAreaReady
          ? TvFocusArea(
              // 布局/排序/数量变化时用 Key 重建区域（count 与 traversal 稳定）。
              key: ValueKey('servers_${visible.length}_$_gridLayout$_sorting'),
              id: 'servers',
              count: _toolCount + visible.length,
              traversal: _sorting
                  ? _sortingTraversal()
                  : _serversTraversal(visible.length),
              // 长按 OK（服务器卡片）：进入排序模式（卡片抖动，方向键移动位置）。
              onLongPressAt: (index) {
                if (_sorting || index < _toolCount) return;
                if (index - _toolCount >= visible.length) return;
                setState(() {
                  _sorting = true;
                  _sortingIndex = index - _toolCount;
                });
              },
              // 边界（工具行上/末卡下）：回状态栏；排序中：方向键移动卡片。
              onBoundary: (direction) {
                if (_sorting) {
                  _moveSortingCard(direction);
                } else {
                  TvFocusManager.instance.enterArea('main_tabs');
                }
              },
              // Builder 保证取焦点节点时区域已注册（TvFocusArea 先挂载）。
              child: Builder(
                builder: (ctx) => _buildScaffold(
                  ctx,
                  visible,
                  useTvArea: true,
                ),
              ),
            )
          : _buildScaffold(context, visible, useTvArea: false),
    );
  }

  Widget _buildScaffold(
    BuildContext ctx,
    List<ServerConfig> visible, {
    required bool useTvArea,
  }) {
    // 工具行节点：0=标题「服务器」、1=布局切换、2=搜索、3=加号。
    final titleNode = useTvArea ? ctx.getFocusNode('servers', 0) : null;
    final layoutNode = useTvArea ? ctx.getFocusNode('servers', 1) : null;
    final searchNode = useTvArea ? ctx.getFocusNode('servers', 2) : null;
    final addNode = useTvArea ? ctx.getFocusNode('servers', 3) : null;

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
            : // TV：标题聚焦时连按三下 OK 切换隐藏服务器显隐。
              TvFocusable(
                onActivate: _onTitleTap,
                borderRadius: 8,
                focusNode: titleNode,
                child: GestureDetector(
                  onTap: _onTitleTap,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('服务器'),
                        // 三击进入「显示隐藏卡片」模式时：标题左侧显示
                        // 与隐藏卡片同款蓝点提示；三击退出后蓝点消失。
                        if (ref.watch(revealHiddenServersProvider)) ...[
                          const SizedBox(width: 6),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                                color: Color(0xFF5B8DEF),
                                shape: BoxShape.circle),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
        actions: [
          if (!_isSearching)
            IconButton(
              focusNode: layoutNode,
              tooltip: _gridLayout ? '切换单排' : '切换双排',
              icon: Icon(_gridLayout
                  ? Icons.view_agenda_rounded
                  : Icons.grid_view_rounded),
              onPressed: () {
                final next = !_gridLayout;
                setState(() => _gridLayout = next);
                AppPreferencesStore.instance.setString(
                    'wjplayer_server_layout', next ? 'grid' : 'list');
              },
            ),
          IconButton(
            focusNode: searchNode,
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
              focusNode: addNode,
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
          : _buildServerList(ctx, visible, useTvArea: useTvArea),
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

  Widget _buildServerList(
    BuildContext ctx,
    List<ServerConfig> servers, {
    required bool useTvArea,
  }) {
    // 双排（grid）：flutter_reorderable_grid_view 支持长按单卡片拖动排序；
    // 单排：官方 ReorderableListView。排序结果统一走
    // serverListProvider.reorderByVisibleIds（按可见列表 id 重排，
    // 隐藏/过滤项保持原相对顺序，杜绝 visible 索引与 state 索引错位）。
    if (_gridLayout) {
      return ReorderableBuilder<ServerConfig>(
        children: [
          for (var i = 0; i < servers.length; i++)
            _ServerCard(
              key: ValueKey(servers[i].id),
              server: servers[i],
              compact: true,
              focusNode: useTvArea
                  ? ctx.getFocusNode('servers', _toolCount + i)
                  : null,
              sorting: _sorting && i == _sortingIndex,
              onTap: _sorting
                  ? _exitSorting
                  : () => _openServer(context, servers[i]),
              onMoreTap: () => _showServerMenu(context, ref, servers[i]),
            ),
        ],
        scrollController: _gridScrollController,
        // 默认 enableLongPress=true：长按卡片拖动排序（手机端）。
        // 注意：库要求「拖动及释放动画期间禁止更新 children」（否则白屏/
        // 位置乱），onReorder 松手时回调一次，此处延迟到释放动画结束后
        // 再同步 provider，避免重建打断库内部动画。
        onReorder: (reorder) {
          final ordered = reorder(servers);
          final ids = [for (final s in ordered) s.id];
          Future<void>.delayed(const Duration(milliseconds: 400), () {
            if (mounted) {
              ref
                  .read(serverListProvider.notifier)
                  .reorderByVisibleIds(ids);
            }
          });
        },
        builder: (children) => GridView(
          controller: _gridScrollController,
          clipBehavior: Clip.none,
          padding: const EdgeInsets.all(14),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: 1.12,
          ),
          children: children,
        ),
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.all(16),
      // TV 排序模式：cacheExtent 预构建，确保排序卡片焦点节点挂载。
      cacheExtent: 3000,
      itemCount: servers.length,
      onReorder: (oldIndex, newIndex) {
        // 基于可见列表的 id 顺序重排完整 state（隐藏/过滤项不参与索引换算，
        // 避免 visible != state 时索引错位导致拖动回弹）。
        final ids = [for (final s in servers) s.id];
        final movedId = ids.removeAt(oldIndex);
        final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
        ids.insert(target, movedId);
        ref
            .read(serverListProvider.notifier)
            .reorderByVisibleIds(ids);
      },
      itemBuilder: (context, index) {
        final server = servers[index];
        return _ServerCard(
          key: ValueKey(server.id),
          server: server,
          focusNode: useTvArea
              ? ctx.getFocusNode('servers', _toolCount + index)
              : null,
          sorting: _sorting && index == _sortingIndex,
          onTap: _sorting
              ? _exitSorting
              : () => _openServer(context, server),
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
    final destination = '/home'; // 仅剩 emby/feiniu，统一进影视首页。
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
            _MenuTile(
              autofocus: true,
              leading: const Icon(Icons.edit),
              title: const Text('编辑信息'),
              onTap: () {
                Navigator.pop(context);
                context.push('/edit/${server.id}');
              },
            ),
            _MenuTile(
              leading: const Icon(Icons.notes),
              title: const Text('修改备注'),
              onTap: () {
                Navigator.pop(context);
                _showEditRemarkDialog(context, ref, server);
              },
            ),
            _MenuTile(
              leading: Icon(
                  server.hidden
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                  color: const Color(0xFF5B8DEF)),
              title: Text(server.hidden ? '显示卡片' : '隐藏卡片'),
              onTap: () {
                Navigator.pop(context);
                final hiding = !server.hidden;
                ref
                    .read(serverListProvider.notifier)
                    .setHidden(server.id, hiding);
                if (hiding) {
                  // 首次点「隐藏卡片」：提示顶部三连击找回方式（10s/点击取消，
                  // 全局只提示一次）。
                  unawaited(_maybeShowHiddenTip(context));
                } else {
                  // 首次点「显示卡片」恢复显示：确认一句（点击取消，只一次）。
                  unawaited(_maybeShowUnhideTip(context));
                }
              },
            ),
            _MenuTile(
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

  /// 按源类型分流「重新登录」：飞牛=账密，Emby=账密。
  void _relogin(BuildContext context, WidgetRef ref, ServerConfig server) {
    switch (server.sourceKind) {
      case SourceKind.feiniu:
        _showSourceCredRelogin(context, ref, server);
      case SourceKind.emby:
        _showReloginDialog(context, ref, server);
    }
  }

  /// 飞牛重新登录：账密对自身后端鉴权，更新同一 server 的 token。
  void _showSourceCredRelogin(
      BuildContext context, WidgetRef ref, ServerConfig server) {
    final urlCtrl = TextEditingController(text: server.baseUrl);
    final userCtrl = TextEditingController(text: server.username ?? '');
    final passCtrl = TextEditingController();
    var loading = false;
    String? error;
    final kind = server.sourceKind;
    final label = switch (kind) {
      SourceKind.feiniu => '飞牛影视',
      SourceKind.emby => 'Emby',
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
                          SourceKind.feiniu =>
                            await FeiniuBackend.login(base, user, pass),
                          SourceKind.emby =>
                            await FeiniuBackend.login(base, user, pass),
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

  /// TV 集中焦点管理注入的节点（null = 自建节点，走 Flutter 默认遍历）。
  final FocusNode? focusNode;

  /// TV 排序模式：卡片抖动。
  final bool sorting;

  const _ServerCard({
    super.key,
    required this.server,
    required this.onTap,
    required this.onMoreTap,
    this.compact = false,
    this.focusNode,
    this.sorting = false,
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
    return TvFocusable(
      onActivate: onTap,
      borderRadius: 14,
      focusNode: focusNode,
      child: _Shake(
        enabled: sorting,
        child: Card(
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
                  child: server.sourceKind == SourceKind.feiniu
                      ? Image.asset(
                          'assets/images/fnico.png',
                          width: 48,
                          height: 48,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(Icons.movie),
                        )
                      : server.iconUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: MediaImage(
                                imageUrl: server.iconUrl,
                                width: 48,
                                height: 48,
                                fit: BoxFit.contain,
                                useDefaultUserAgent: true,
                                errorWidget: const EmbyDefaultIcon(),
                              ),
                            )
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
                    // 连接状态点（红/绿统一位置，加载中不显示）：
                    // 统计拉取成功（error==null）= 绿点；失败/异常 = 红点。
                    if (stats.hasValue || stats.hasError) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: (stats.valueOrNull?.error == null &&
                                  !stats.hasError)
                              ? const Color(0xFF34C759) // 绿：连接成功
                              : const Color(0xFFE53935), // 红：连接失败
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                    // 隐藏提示蓝点：右移一点（在状态点之后），
                    // 避免与红绿点位置冲突（红绿点固定同一位置）。
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
              stats.when(
                  data: (value) => Text(
                        // 优先服务器配置上的最近观影（隐藏删历史后仍保留），
                        // 回退历史统计。
                        server.lastWatchedAt != null
                            ? '最近观影 ${_date(DateTime.parse(server.lastWatchedAt!))}'
                            : value.lastWatchedAt == null
                                ? '暂无观影记录'
                                : _date(value.lastWatchedAt!),
                        style: TextStyle(
                            fontSize: compact ? 11 : 12,
                            color: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.color),
                      ),
                  loading: () => const Text('最近观影 —',
                      style: TextStyle(fontSize: 12)),
                  error: (_, __) => const Text('最近观影 —',
                      style: TextStyle(fontSize: 12))),
              if (server.remark?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 5),
                Text(server.remark!, maxLines: compact ? 1 : 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: compact ? 11 : 13, color: Theme.of(context).textTheme.bodySmall?.color)),
              ],
            ],
          ),
        ),
      ),
      ),
      ),
    );
  }
}

/// 三点菜单项：TV 上可聚焦（OK 触发），手机端原样 ListTile。
class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.leading,
    required this.title,
    required this.onTap,
    this.autofocus = false,
  });
  final Widget leading;
  final Widget title;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    if (!isTvPlatform) {
      return ListTile(leading: leading, title: title, onTap: onTap);
    }
    return TvFocusable(
      onActivate: onTap,
      borderRadius: 12,
      autofocus: autofocus,
      child: ListTile(
        leading: leading,
        title: title,
        onTap: onTap,
        // TV 上不显示 ListTile 自身的按压水波纹（由 TvFocusable 描边指示）。
        splashColor: Colors.transparent,
      ),
    );
  }
}

/// TV 排序模式抖动动画：水平往返 + 垂直正弦微抖。
class _Shake extends StatefulWidget {
  const _Shake({required this.child, this.enabled = false});
  final Widget child;
  final bool enabled;

  @override
  State<_Shake> createState() => _ShakeState();
}

class _ShakeState extends State<_Shake> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Shake oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.enabled && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (!widget.enabled) return child!;
        final t = _controller.value; // 0..1 往返
        final dx = (t * 2 - 1) * 2.4; // -2.4..2.4
        final dy = math.sin(t * math.pi * 2) * 1.4;
        return Transform.translate(offset: Offset(dx, dy), child: child);
      },
      child: widget.child,
    );
  }
}
