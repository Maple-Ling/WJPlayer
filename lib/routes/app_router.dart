import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show
    KeyEventResult,
    LogicalKeyboardKey,
    SystemNavigator;
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/providers/app_providers.dart';
import '../core/providers/media_providers.dart';
import '../core/services/tv_focus_manager.dart';
import '../core/services/tv_key_channel.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_motion.dart';
import '../core/utils/platform_utils.dart';
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
    observers: [appRouteObserver],
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
              targetEpisodeNumber: extra.targetEpisodeNumber,
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
          startPosition: state.uri.queryParameters['start'] != null
              ? Duration(
                  seconds:
                      int.tryParse(state.uri.queryParameters['start']!) ?? 0)
              : null,
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
  final ValueNotifier<bool> _tabCollapsed = ValueNotifier<bool>(false);
  DateTime? _lastBackPress;

  // 菜单键处理器：进入/退出状态栏。
  //   · 所有支持底部状态栏的页面（影视/记录/服务器/搜索/设置/服务器媒体页）
  //     均允许 MENU 切换状态栏——对齐主流 TV 平台「MENU=呼出导航/菜单」的
  //     惯例，避免按键被无声吞掉（2026-08-09 检测修复）。
  //   · 状态栏内部再按一次 MENU → 安全退出并归还进入前的区域焦点。
  //   · 播放器等 push 页面注册的 handler 注册更晚、优先执行，不会落到这里。
  KeyEventResult _handleMenuKey(
      LogicalKeyboardKey key, KeyEventSource source, bool isRepeat, bool isUp) {
    if (key != LogicalKeyboardKey.contextMenu) return KeyEventResult.ignored;
    if (isUp) return KeyEventResult.ignored; // KeyUp 不处理（避免双触发）。
    if (!_supportsFloatingTabBar) return KeyEventResult.ignored;
    final manager = TvFocusManager.instance;
    if (manager.activeArea?.config.id == 'main_tabs') {
      manager.exitArea('main_tabs');
    } else {
      // 进入状态栏：处于收缩/折叠状态时先自动展开，再切入焦点。
      if (_tabCollapsed.value) {
        _tabCollapsed.value = false;
      }
      manager.enterArea('main_tabs');
    }
    return KeyEventResult.handled;
  }

  // 分支内 push 的页面（如从服务器管理页进入的 /home、/edit、/add 等）先逐级返回；
  // 分支根返回统一回到默认“影视”；影视根两次返回退出。
  void _handleShellPop() {
    final router = GoRouter.of(context);
    // TV：状态栏（底部导航）聚焦时按返回 = 收起状态栏、归还页面焦点，
    // 不执行页面后退（对齐主流「返回关闭最上层 UI」语义）。
    if (isTvPlatform &&
        TvFocusManager.instance.activeArea?.config.id == 'main_tabs') {
      TvFocusManager.instance.exitArea('main_tabs');
      return;
    }
    if (router.canPop()) {
      // 延迟到下一帧再 pop：PopScope 回调正处于 pop 手势处理中，
      // 同步导航可能导致 Navigator 状态不一致（"already popping"）而卡死。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) router.pop();
      });
      return;
    }
    // 服务器主页（/home）：不管从哪个入口进的（服务器列表返回经 PopToHome
    // 用 go('/home') 替换栈、或 push 进入），返回统一回服务器列表（/servers）。
    if (widget.currentPath == '/home') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/servers');
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
    // 按滚动方向控制底部栏（所有 tab 页面生效，不限 /home）：
    // 内容下滑（手指上滑浏览）→ 收缩成仅搜索按钮并保持；
    // 内容上滑（回看）→ 展开完整 tab 栏。
    if (notification is ScrollUpdateNotification) {
      final delta = notification.scrollDelta ?? 0;
      if (delta > 1.5) {
        _tabCollapsed.value = true;
      } else if (delta < -1.5) {
        _tabCollapsed.value = false;
      }
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPath != widget.currentPath && _isServerListPage) {
      _tabCollapsed.value = false;
    }
    if (oldWidget.currentPath != widget.currentPath &&
        widget.currentPath == '/history') {
      ref.read(watchHistoryRefreshProvider.notifier).state++;
    }
    if (isTvPlatform && oldWidget.currentPath != widget.currentPath) {
      _syncCurrentPageArea();
      // 路由变化：旧的返回目标失效（如 tab 间切换后退出状态栏不应回到
      // 已不可见的旧页面区域），清空后由下一次 MENU 进入重新记录。
      TvFocusManager.instance.clearReturnTarget();
      final wasTabPage = switch (oldWidget.currentPath) {
        '/discover' ||
        '/history' ||
        '/servers' ||
        '/home' ||
        '/search' ||
        '/settings' =>
          true,
        _ => false,
      };
      final nowTabPage = _supportsFloatingTabBar;
      if (wasTabPage || nowTabPage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (nowTabPage) {
            TvFocusManager.instance.switchArea('main_tabs');
          } else {
            TvFocusManager.instance.releaseArea('main_tabs');
          }
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    if (isTvPlatform) {
      registerGlobalKeyHandler(_handleMenuKey);
      _syncCurrentPageArea();
    }
  }

  /// 同步"当前可见 tab 页面对应的页面区域"（供状态栏上键退出/下键切入）。
  void _syncCurrentPageArea() {
    switch (widget.currentPath) {
      case '/discover':
        // 影视页：状态栏上键 → 首个焦点元素（平台行/首卡），下键 → 第二元素。
        TvFocusManager.instance.setCurrentPageArea('discover');
      case '/history':
        // 状态栏上键 → 刷新按钮（tools[0]）；下键 → 第一条记录（index 1）。
        TvFocusManager.instance.setCurrentPageArea('history');
      case '/servers':
        // 状态栏上键 → 右上角加号按钮（tools[3]）；下键 → 第一张服务器卡（index 4）。
        TvFocusManager.instance
            .setCurrentPageArea('servers', topIndex: 3, firstCardIndex: 4);
      case '/settings':
        // 状态栏上/下键 → 第一张设置卡（界面）。
        TvFocusManager.instance.setCurrentPageArea('settings');
      case '/search':
        // 状态栏上键 → 搜索框（tools[0]）；下键 → 搜索框（同）。
        TvFocusManager.instance.setCurrentPageArea('search');
      default:
        TvFocusManager.instance.setCurrentPageArea(null);
    }
  }

  @override
  void dispose() {
    if (isTvPlatform) unregisterGlobalKeyHandler(_handleMenuKey);
    _tabCollapsed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final isKeyboardVisible = mediaQuery.viewInsets.bottom > 0;
    final showFloatingTabBar = _supportsFloatingTabBar && !isKeyboardVisible;
    final bottomPadding = mediaQuery.padding.bottom;
    final tabHeight = showFloatingTabBar ? 64.0 + bottomPadding : 0.0;

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
          body: isKeyboardVisible
              ? widget.navigationShell // 键盘显示时不修改 MediaQuery，让系统自动处理
              : MediaQuery(
                  data: mediaQuery.copyWith(
                    padding: mediaQuery.padding.copyWith(
                      bottom: mediaQuery.padding.bottom + tabHeight,
                    ),
                  ),
                  child: widget.navigationShell,
                ),
          bottomNavigationBar: const SizedBox.shrink(),
          floatingActionButtonLocation:
              FloatingActionButtonLocation.centerDocked,
          floatingActionButton: showFloatingTabBar
              ? ValueListenableBuilder<bool>(
                  valueListenable: _tabCollapsed,
                  builder: (context, collapsed, _) => _FloatingTabBar(
                    navigationShell: widget.navigationShell,
                    collapsed: collapsed,
                    onExpand: () => _tabCollapsed.value = false,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class _FloatingTabBar extends ConsumerStatefulWidget {
  const _FloatingTabBar({
    required this.navigationShell,
    this.collapsed = false,
    this.onExpand,
  });
  final StatefulNavigationShell navigationShell;

  final bool collapsed;
  final VoidCallback? onExpand;

  @override
  ConsumerState<_FloatingTabBar> createState() => _FloatingTabBarState();
}

class _FloatingTabBarState extends ConsumerState<_FloatingTabBar> {
  // TV 遥控器导航由 TvFocusManager 统一管理，不再手动维护 FocusNode。
  static const _tabOrder = [0, 1, 2, 4, 3]; // 影视/记录/服务器/设置/搜索
  int _tabAt(int orderPos) => _tabOrder[orderPos];

  @override
  void initState() {
    super.initState();
    if (!isTvPlatform) return;
    TvFocusManager.instance.registerArea(
      FocusAreaConfig(
        id: 'main_tabs',
        count: _tabOrder.length,
        traversal: TraversalPolicies.linear(_tabOrder.length),
        releaseOnUp: true,
        ignoreDown: true,
        // 左右键移动焦点即直接切换对应页面（无需再按 OK 确认）。
        onMoveActivated: (orderPos) {
          if (mounted) {
            widget.navigationShell.goBranch(_tabAt(orderPos));
          }
        },
      ),
    );
    TvFocusManager.instance.addListener(_onFocusChanged);
    // 初始聚焦到搜索 tab
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      TvFocusManager.instance.focusAt('main_tabs', 4);
    });
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _FloatingTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!isTvPlatform || oldWidget.collapsed == widget.collapsed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final area = TvFocusManager.instance.getArea('main_tabs');
      if (area == null) return;
      if (widget.collapsed && area.nodes.any((node) => node.hasFocus)) {
        TvFocusManager.instance.focusAt('main_tabs', 4);
      }
    });
  }

  @override
  void dispose() {
    TvFocusManager.instance.removeListener(_onFocusChanged);
    TvFocusManager.instance.unregisterArea('main_tabs');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBg = isDark ? AppColors.darkNavBackground : AppColors.lightNavBackground;
    final selectedBg = isDark ? AppColors.darkNavSelected : AppColors.lightNavSelected;
    final textColor = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final mutedColor = isDark ? const Color(0xFFB8B8BA) : const Color(0xFF6F6F72);

    // 收缩模式：4 个 tab 隐藏，遥控器无导航目标；展开后恢复。
    if (widget.collapsed) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        decoration: BoxDecoration(
          color: navBg,
          borderRadius: BorderRadius.circular(42),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 20, offset: const Offset(0, 8), spreadRadius: 2),
            BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2)),
          ],
        ),
        child: SafeArea(
          top: false,
          child: _buildSearchButton(context, isDark, navBg, selectedBg, textColor),
        ),
      );
    }

    // 展开模式：正常 5 个 tab。
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      decoration: BoxDecoration(
        color: navBg,
        borderRadius: BorderRadius.circular(42),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 20, offset: const Offset(0, 8), spreadRadius: 2),
          BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: _buildTabRowChildren(
            context,
            isDark,
            navBg,
            selectedBg,
            textColor,
            mutedColor,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildTabRowChildren(BuildContext context, bool isDark, Color navBg,
      Color selectedBg, Color textColor, Color mutedColor) {
    return [
      Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: navBg, borderRadius: BorderRadius.circular(36)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...List.generate(4, (i) => _buildTabItem(context, _tabAt(i), i, isDark, navBg, selectedBg, textColor, mutedColor)),
          ],
        ),
      ),
      const SizedBox(width: 8),
      _buildSearchButton(context, isDark, navBg, selectedBg, textColor),
    ];
  }

  /// 单个 tab 项：TV 遥控器焦点 + 方向键导航 + 激活跳转。
  Widget _buildTabItem(BuildContext context, int branchIndex, int orderPos,
      bool isDark, Color navBg, Color selectedBg, Color textColor, Color mutedColor) {
    final selected = widget.navigationShell.currentIndex == branchIndex;
    final area = TvFocusManager.instance.getArea('main_tabs');
    final focused = area != null &&
        area.focusIndex == orderPos &&
        area.nodes[orderPos].hasFocus;
    final borderWidth = focused ? 1.5 : 0.0;
    final borderColor = focused ? textColor.withValues(alpha: 0.5) : Colors.transparent;

    return FocusableActionDetector(
      focusNode: area?.nodes[orderPos],
      enabled: !widget.collapsed,
      autofocus: false,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.navigationShell.goBranch(_tabAt(orderPos));
            return null;
          },
        ),
      },
      child: _TabItemBase(
        onTap: () => widget.navigationShell.goBranch(branchIndex),
        selected: selected,
        focused: focused,
        borderWidth: borderWidth,
        borderColor: borderColor,
        branchIndex: branchIndex,
        navBg: navBg,
        selectedBg: selectedBg,
        textColor: textColor,
        mutedColor: mutedColor,
      ),
    );
  }

  /// 搜索按钮（最后位置）。
  Widget _buildSearchButton(BuildContext context, bool isDark, Color navBg,
      Color selectedBg, Color textColor) {
    final searchOrderPos = 4;
    final area = TvFocusManager.instance.getArea('main_tabs');
    final focused = area != null &&
        area.focusIndex == searchOrderPos &&
        area.nodes[searchOrderPos].hasFocus;
    final borderWidth = focused ? 1.5 : 0.0;
    final borderColor = focused ? textColor.withValues(alpha: 0.5) : Colors.transparent;

    return FocusableActionDetector(
      focusNode: area?.nodes[searchOrderPos],
      enabled: !widget.collapsed,
      autofocus: false,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (widget.collapsed) {
              widget.onExpand?.call();
            } else {
              widget.navigationShell.goBranch(3);
            }
            return null;
          },
        ),
      },
      child: _SearchButtonBase(
        onTap: () {
          if (widget.collapsed) {
            widget.onExpand?.call();
          } else {
            widget.navigationShell.goBranch(3);
          }
        },
        collapsed: widget.collapsed,
        focused: focused,
        borderWidth: borderWidth,
        borderColor: borderColor,
        selectedBg: selectedBg,
        navBg: navBg,
        textColor: textColor,
      ),
    );
  }
}

/// 纯展示层 tab 项（逻辑抽离，方便复用）。
class _TabItemBase extends StatelessWidget {
  const _TabItemBase({
    required this.onTap,
    required this.selected,
    required this.focused,
    required this.borderWidth,
    required this.borderColor,
    required this.branchIndex,
    required this.navBg,
    required this.selectedBg,
    required this.textColor,
    required this.mutedColor,
  });

  final VoidCallback onTap;
  final bool selected;
  final bool focused;
  final double borderWidth;
  final Color borderColor;
  final int branchIndex;
  final Color navBg;
  final Color selectedBg;
  final Color textColor;
  final Color mutedColor;

  static const _labels = ['影视', '记录', '服务器', '搜索', '设置'];
  static const _icons = [
    Icons.movie_filter_rounded,
    Icons.history_rounded,
    Icons.dns_rounded,
    Icons.search_rounded,
    Icons.settings_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final label = _labels[branchIndex];
    final icon = _icons[branchIndex];
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? selectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: selected ? textColor : mutedColor),
            if (selected) ...[
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: textColor, fontSize: 13, fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 搜索按钮纯展示层。
class _SearchButtonBase extends StatelessWidget {
  const _SearchButtonBase({
    required this.onTap,
    required this.collapsed,
    required this.focused,
    required this.borderWidth,
    required this.borderColor,
    required this.selectedBg,
    required this.navBg,
    required this.textColor,
  });

  final VoidCallback onTap;
  final bool collapsed;
  final bool focused;
  final double borderWidth;
  final Color borderColor;
  final Color selectedBg;
  final Color navBg;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: collapsed || focused ? selectedBg : navBg,
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Icon(
          collapsed ? Icons.expand_less_rounded : Icons.search_rounded,
          size: 22,
          color: textColor,
        ),
      ),
    );
  }
}

/// _TabBarTvController 已被 TvFocusManager 替代。
/// _TvTabRow 和 _TvKeyboardWrapper 已被 TvKeyboardListener 替代。

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
