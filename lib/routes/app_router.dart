import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/providers/app_providers.dart';
import '../core/providers/media_providers.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_motion.dart';
import '../plugins/plugin_system.dart';
import '../ui/screens/discover/discover_screen.dart';
import '../ui/screens/history/history_screen.dart';
import '../ui/screens/favorites/favorites_screen.dart';
import '../ui/screens/library/libraries_screen.dart';
import '../ui/screens/library/library_detail_screen.dart';
import '../ui/screens/player/player_screen.dart';
import '../ui/screens/search/search_screen.dart';
import '../ui/screens/server/add_server_screen.dart';
import '../ui/screens/server/edit_server_screen.dart';
import '../ui/screens/server/icon_select_screen.dart';
import '../ui/screens/server/server_list_screen.dart';
import '../ui/screens/settings/settings_screen.dart';
import '../ui/screens/source/unified_media_screens.dart';
import '../ui/screens/source/source_picker_screen.dart';
import '../core/sources/source_playback.dart';
import '../core/sources/source_kind.dart';
import '../ui/utils/image_size_helper.dart';
import '../ui/utils/media_helpers.dart';
import '../ui/widgets/common/app_toast.dart';
import '../ui/widgets/common/media_widgets.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>((ref) {
  attachPluginNavigator(_rootNavigatorKey);
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/discover',
    onException: (context, state, router) => router.go('/discover'),
    routes: [
      StatefulShellRoute(
        navigatorContainerBuilder: (context, navigationShell, children) {
          return _AnimatedBranchContainer(
            currentIndex: navigationShell.currentIndex,
            children: children,
          );
        },
        builder: (context, state, navigationShell) => MainShell(
          navigationShell: navigationShell,
          currentPath: state.uri.path,
        ),
        branches: [
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/discover',
                pageBuilder: (context, state) => _buildBranchRootPage(
                  child: const DiscoverScreen(),
                  state: state,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/history',
                pageBuilder: (context, state) => _buildBranchRootPage(
                  child: const HistoryScreen(),
                  state: state,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/servers',
                pageBuilder: (context, state) => _buildBranchRootPage(
                  child: const ServerListScreen(),
                  state: state,
                ),
              ),
              GoRoute(
                path: '/home',
                pageBuilder: (context, state) => _buildHorizontalPage(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final server = ref.watch(currentServerProvider);
                      if (server == null) return const ServerListScreen();
                      return const UnifiedMediaHomeScreen();
                    },
                  ),
                  state: state,
                  direction: _PageTransitionDirection.forward,
                ),
              ),
              GoRoute(
                path: '/add',
                pageBuilder: (context, state) => _buildHorizontalPage(
                  child: const SourcePickerScreen(),
                  state: state,
                  direction: _PageTransitionDirection.forward,
                ),
                routes: [
                  GoRoute(
                    path: 'emby',
                    pageBuilder: (context, state) => _buildHorizontalPage(
                      child: AddServerScreen(
                        sourceKind: SourceKind.values.firstWhere(
                          (k) =>
                              k.name ==
                              (state.uri.queryParameters['sourceKind'] ??
                                  'emby'),
                          orElse: () => SourceKind.emby,
                        ),
                      ),
                      state: state,
                      direction: _PageTransitionDirection.forward,
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: '/edit/:serverId',
                pageBuilder: (context, state) => _buildHorizontalPage(
                  child: EditServerScreen(
                    serverId: state.pathParameters['serverId']!,
                  ),
                  state: state,
                  direction: _PageTransitionDirection.forward,
                ),
              ),
              GoRoute(
                path: '/icons/:serverId',
                pageBuilder: (context, state) => _buildHorizontalPage(
                  child: IconSelectScreen(
                    serverId: state.pathParameters['serverId']!,
                  ),
                  state: state,
                  direction: _PageTransitionDirection.forward,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/search',
                pageBuilder: (context, state) => _buildBranchRootPage(
                  child: const SearchScreen(),
                  state: state,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            preload: true,
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) => _buildBranchRootPage(
                  child: const SettingsScreen(),
                  state: state,
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/resume',
        builder: (context, state) => const _ResumeRouteScreen(),
      ),
      GoRoute(
        path: '/detail/:id',
        builder: (context, state) {
          // 支持带完整服务器+真实类型 entry 的跳转（搜索/历史/飞牛库等入口）：
          // 避免手动 Navigator.push 与 StatefulShellRoute 混用导致的灰屏，
          // 也避免 /detail 伪造 Movie type 造成飞牛剧集数据拉取不完整。
          final extra = state.extra;
          if (extra is UnifiedMediaDetailRouteExtra) {
            return UnifiedMediaDetailScreen(
              server: extra.server,
              entry: extra.entry,
              autoPlay: extra.autoPlay,
            );
          }
          return UnifiedEmbyDetailRoute(
            itemId: state.pathParameters['id']!,
            autoPlay: state.uri.queryParameters['autoplay'] == '1',
          );
        },
      ),
      GoRoute(
        path: '/season/:id',
        builder: (context, state) => UnifiedEmbyDetailRoute(
          itemId: state.pathParameters['id']!,
          autoPlay: state.uri.queryParameters['autoplay'] == '1',
        ),
      ),
      GoRoute(
        path: '/episode/:id',
        builder: (context, state) => UnifiedEmbyDetailRoute(
          itemId: state.pathParameters['id']!,
          autoPlay: state.uri.queryParameters['autoplay'] == '1',
        ),
      ),
      GoRoute(path: '/libraries', builder: (_, __) => const LibrariesScreen()),
      GoRoute(
        path: '/library/:id',
        builder: (context, state) => LibraryDetailScreen(
          libraryId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/player/:id',
        builder: (context, state) => PlayerScreen(
          itemId: state.pathParameters['id']!,
          mediaSourceId: state.uri.queryParameters['mediaSourceId'],
          playerCoreOverride: state.uri.queryParameters['core'],
        ),
      ),
      GoRoute(path: '/favorites', builder: (_, __) => const FavoritesScreen()),
      GoRoute(
        path: '/source-player',
        builder: (context, state) {
          final sp = state.extra as SourcePlayback;
          return PlayerScreen(itemId: sp.syntheticItemId, sourcePlay: sp);
        },
      ),
    ],
  );
});

enum _PageTransitionDirection { neutral, forward, backward }

CustomTransitionPage<void> _buildBranchRootPage({
  required Widget child,
  required GoRouterState state,
}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: AppMotion.standard,
        ),
        child: child,
      );
    },
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 140),
  );
}

CustomTransitionPage<void> _buildHorizontalPage({
  required Widget child,
  required GoRouterState state,
  _PageTransitionDirection direction = _PageTransitionDirection.neutral,
}) {
  final Offset begin = switch (direction) {
    _PageTransitionDirection.backward => const Offset(-0.18, 0),
    _PageTransitionDirection.forward => const Offset(0.16, 0),
    _PageTransitionDirection.neutral => const Offset(0.08, 0),
  };

  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.reverse,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: begin,
          end: Offset.zero,
        ).animate(curved),
        child: FadeTransition(
          opacity: Tween<double>(begin: 0.92, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 200),
  );
}

class _AnimatedBranchContainer extends StatefulWidget {
  const _AnimatedBranchContainer({
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  State<_AnimatedBranchContainer> createState() =>
      _AnimatedBranchContainerState();
}

class _AnimatedBranchContainerState extends State<_AnimatedBranchContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  // 切换方向：true=向右（索引增大），false=向左。决定淡入方向（轻微位移）。
  bool _moveRight = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AppMotion.medium,
      vsync: this,
    );
    // 首帧停在动画终点，否则 autoPlay:false 会让初始画面停在 SlideEffect 的
    // begin 偏移（向右 4%），表现为“首次进入时 UI 整体往右歪、切换一下才回正”。
    _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(covariant _AnimatedBranchContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      // 方向必须与“切换前”的索引比较（oldWidget.currentIndex），
      // 旧实现用了滞后一拍的字段，导致方向错乱、看起来只能往一边切。
      _moveRight = widget.currentIndex > oldWidget.currentIndex;
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 丝滑切换：轻微淡入淡出 + 极小位移（4px），避免横移导致的“跳针感”。
    final double beginX = _moveRight ? 0.004 : -0.004;
    return Animate(
      controller: _controller,
      autoPlay: false,
      effects: [
        SlideEffect(
          begin: Offset(beginX, 0),
          end: Offset.zero,
          duration: AppMotion.medium,
          curve: AppMotion.standard,
        ),
        const FadeEffect(
          begin: 0.90,
          end: 1.0,
          duration: AppMotion.medium,
          curve: AppMotion.standard,
        ),
      ],
      child: IndexedStack(
        index: widget.currentIndex,
        children: widget.children,
      ),
    );
  }
}

class MainShell extends ConsumerStatefulWidget {
  const MainShell({
    super.key,
    required this.navigationShell,
    required this.currentPath,
  });

  final StatefulNavigationShell navigationShell;
  final String currentPath;

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  // 性能要点：滚动时只更新 ValueNotifier，由 ValueListenableBuilder 局部重建
  // 浮动 TabBar 的透明度，避免每个滚动事件 setState 整个 shell（含 navigationShell）。
  final ValueNotifier<double> _tabOpacity = ValueNotifier<double>(1.0);
  DateTime? _lastBackPress;

  // 分支内 push 的页面（如从服务器管理页进入的 /home、/edit、/add 等）先逐级返回；
  // 分支根返回统一回到默认“影视”；影视根两次返回退出。
  void _handleShellPop() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      // 延迟到下一帧再 pop：PopScope 回调正处于 pop 手势处理中，
      // 同步导航可能导致 Navigator 状态不一致（"already popping"）而卡死。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) router.pop();
      });
      return;
    }
    if (widget.navigationShell.currentIndex != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.navigationShell.goBranch(0);
      });
      return;
    }
    final now = DateTime.now();
    if (_lastBackPress == null ||
        now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
      _lastBackPress = now;
      AppToast.show(context, '再按一次返回键退出');
      return;
    }
    SystemNavigator.pop();
  }

  bool get _isHomePage => widget.currentPath == '/home';
  bool get _isServerListPage => widget.currentPath == '/servers';
  bool get _supportsFloatingTabBar => switch (widget.currentPath) {
        '/discover' ||
        '/history' ||
        '/servers' ||
        '/home' ||
        '/search' ||
        '/settings' =>
          true,
        _ => false,
      };

  bool _onScrollNotification(ScrollNotification notification) {
    if (!_isHomePage) return false;

    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      if (delta.abs() > 1.5) {
        // 下滑时最多淡到可发现状态，不能变成完全透明且仍拦截触摸。
        _tabOpacity.value = (_tabOpacity.value - delta / 150).clamp(0.18, 1.0);
      }
    } else if (notification is ScrollEndNotification) {
      // 手指离开后立即恢复，避免滚动中断/嵌套列表导致底栏永久隐藏。
      _tabOpacity.value = 1.0;
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPath != widget.currentPath && _isServerListPage) {
      _tabOpacity.value = 1.0;
    }
    if (oldWidget.currentPath != widget.currentPath &&
        widget.currentPath == '/history') {
      ref.read(watchHistoryRefreshProvider.notifier).state++;
    }
  }

  @override
  void dispose() {
    _tabOpacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final isKeyboardVisible = mediaQuery.viewInsets.bottom > 0;
    final showFloatingTabBar = _supportsFloatingTabBar && !isKeyboardVisible;
    final bottomPadding = mediaQuery.padding.bottom;
    // 底部 tab 栏下方原本间隔一个“同状态栏高度”的悬停空隙。
    // 需求：整体**向下**移动两倍胶囊高度（胶囊高 44），即把悬停空隙缩小
    // 2×44，让 tab 栏 + 搜索图标更贴近屏幕底部（clamp 防负）。
    final statusGap = showFloatingTabBar ? mediaQuery.padding.top : 0.0;
    final tabHeight = showFloatingTabBar
        ? (64.0 + bottomPadding + statusGap - 2 * 44.0)
            .clamp(0.0, double.infinity)
        : 0.0;
    final shellBody = isKeyboardVisible
        ? widget.navigationShell
        : MediaQuery(
            data: mediaQuery.copyWith(
              padding: mediaQuery.padding.copyWith(
                bottom: mediaQuery.padding.bottom + tabHeight,
              ),
            ),
            child: widget.navigationShell,
          );

    return PopScope(
      // canPop:false → 拦截 go_router 冒泡到根导航器的返回（分支根/退出），交由 _handleShellPop。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleShellPop();
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: Scaffold(
          resizeToAvoidBottomInset: true, // 显式设置以确保键盘正确处理
          body: Stack(
            fit: StackFit.expand,
            children: [
              shellBody,
              if (showFloatingTabBar)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ValueListenableBuilder<double>(
                    valueListenable: _tabOpacity,
                    builder: (context, value, _) => Opacity(
                      opacity: _isServerListPage ? 1.0 : value,
                      child: _FloatingTabBar(
                        navigationShell: widget.navigationShell,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          bottomNavigationBar: const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _FloatingTabBar extends ConsumerWidget {
  const _FloatingTabBar({required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 底部悬停空隙：间隔一个“同状态栏高度”的距离，不贴屏幕底边。
    final statusGap = MediaQuery.of(context).padding.top;
    // 底部胶囊栏高度：与 capsuleItem 的固定高度（44）保持一致，
    // 用于把底部状态栏整体再下移一个胶囊高度。
    const capsuleHeight = 44.0;
    final navBg = isDark ? AppColors.darkNavBackground : AppColors.lightNavBackground;
    final selectedBg = isDark ? AppColors.darkNavSelected : AppColors.lightNavSelected;
    final textColor = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final mutedColor = isDark ? const Color(0xFFB8B8BA) : const Color(0xFF6F6F72);
    final shadow = BoxShadow(
      color: Colors.black.withValues(alpha: 0.12),
      blurRadius: 16,
      offset: const Offset(0, 6),
    );

    // 胶囊内的四个 tab：空间等分（固定等宽）。
    Widget capsuleItem(int index, IconData icon, String label) {
      final selected = navigationShell.currentIndex == index;
      return GestureDetector(
        onTap: () => navigationShell.goBranch(index),
        child: Container(
          width: 66,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? selectedBg : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: selected ? textColor : mutedColor),
              if (selected) ...[
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // 圆形的搜索按钮：固定在胶囊右侧。
    Widget searchButton() {
      final selected = navigationShell.currentIndex == 3;
      return GestureDetector(
        onTap: () => navigationShell.goBranch(3),
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: selected ? selectedBg : navBg,
            shape: BoxShape.circle,
            boxShadow: [shadow],
          ),
          child: Icon(Icons.search_rounded, size: 22, color: textColor),
        ),
      );
    }

    return Container(
      alignment: Alignment.center,
      margin: EdgeInsets.only(
        top: 8,
        // 向下移动两倍胶囊高度（相对原悬停空隙 statusGap+8 减 2×44）。
        bottom: (statusGap + 8 - 2 * capsuleHeight)
            .clamp(0.0, double.infinity),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 左：影视 / 记录 / 服务器 / 设置，组合成一个胶囊，空间等分
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: navBg,
                borderRadius: BorderRadius.circular(36),
                boxShadow: [shadow],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  capsuleItem(0, Icons.movie_filter_rounded, '影视'),
                  capsuleItem(1, Icons.history_rounded, '记录'),
                  capsuleItem(2, Icons.dns_rounded, '服务器'),
                  capsuleItem(4, Icons.settings_rounded, '设置'),
                ],
              ),
            ),
            // 中：间隔一个图标的无连接空间
            const SizedBox(width: 24),
            // 右：圆形搜索
            searchButton(),
          ],
        ),
      ),
    );
  }
}

class _ResumeRouteScreen extends ConsumerWidget {
  const _ResumeRouteScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resumeAsync = ref.watch(resumeItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('继续观看'),
      ),
      body: resumeAsync.when(
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Text('暂无继续观看的内容'),
            );
          }

          final sizePreference = ImageSizeHelper.analyzeForResumeSection(items);

          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 1.3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 16,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final api = ref.read(apiClientProvider);
              final imageUrls = resolveMediaItemImageUrls(
                api,
                item,
                maxWidth: 400,
                preferThumb: true,
              );

              return GestureDetector(
                onTap: () => context.push('/detail/${item.id}?autoplay=1'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 封面图
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            MediaImage(
                              imageUrl:
                                  imageUrls.isNotEmpty ? imageUrls.first : null,
                              imageUrls: imageUrls.length > 1
                                  ? imageUrls.sublist(1)
                                  : null,
                              width: 400,
                              height: 225,
                              fit: BoxFit.cover,
                            ),
                            // 进度条
                            if (item.progress != null)
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: LinearProgressIndicator(
                                  value: item.progress,
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.3),
                                  valueColor: const AlwaysStoppedAnimation(
                                      Color(0xFF5B8DEF)),
                                  minHeight: 3,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 标题
                    SizedBox(
                      height: 16,
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Text('加载失败: $error'),
        ),
      ),
    );
  }
}
