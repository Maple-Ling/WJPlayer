# 重构进度日志

## 2026-08-04
- 启动22项重构任务，基线 654946a
- 提交 97b75db: 顶栏网速 + MPV比例/自适应 + 首页缓存优化雏形

## 2026-08-05
- 完成剩余 5 项收口：历史页进入自动刷新、详情页浅蓝蒙版移除、详情页播放键渐变联动、
  首页服务器持久化缓存(HomeDataCache/HomeCacheLoader)、聚合搜索复用 PlaybackResourceCard。
- MediaItem/Library 增 fromJson/toJson；PersistentJsonCache 增 delete。
- 静态检查：9 个改动文件括号/括弧全部平衡，符号引用一致。
- 本地无法编译（x86_64 Flutter 缺 qemu ld-linux）。

## 2026-08-05 本轮执行
- 已将 `lib/ui/screens/source/source_browse_screen.dart` 的飞牛条目入口切换为 `UnifiedMediaDetailScreen`。
- 已将 `lib/ui/widgets/common/ranking_entry_panel.dart` 的飞牛详情入口切换为统一详情页。
- 统一页现有 `_buildPlaybackOptions()` 保留内核、线路、音频、字幕四个按钮；`_buildMediaCards()` 与文件卡片仍位于底部媒体信息区。
- 独立 `FeiniuMediaDetailScreen` 暂不删除，仅不再由这两个入口调用。
- `dart` 未安装，无法执行 dart format/analyze；已完成 diff、符号引用和关键组件静态核对。

## 2026-08-05 播放器交互与媒体信息
- 修复控制层空白区域点击：控制层显示时空白点击由覆盖层隐藏 UI，锁定时不抢占触摸，底层手势继续可用。
- 锁定状态改为锁上立即隐藏 UI，并在左侧保留解锁按钮；解锁恢复 UI。
- 媒体信息弹层继续使用可滚动胶囊容器，并扩充播放器媒体详情项目。
- 扩展 Emby MediaStream 和统一资源映射：封装格式、SAR/DAR、采样率、位深、色彩范围/空间/矩阵/传输、GOP、时间基等。
- 统一详情页底部视频/音频卡片已扩充对应参数；飞牛接口字段尚需根据真实响应做别名适配，未知字段不会伪造。
- `git diff --check` 通过；未安装 Dart/Flutter，尚未执行 analyze 或真机回归。

## 2026-08-05 服务器表单统一
- `ServerEditorForm` 已按挂载目录 `添加服务器.html` 重构为浅灰背景 + 白色圆角卡片 + 胶囊输入 + 线路卡片 + 蓝色连接按钮。
- Emby/飞牛新增和编辑共用同一个 `ServerEditorForm`，仅保留 sourceKind 对应的登录/保存逻辑差异。
- 编辑页已取消 `hideMainUrl` 精简模式，和新增页显示完全相同的名称、备注、地址、路径、账号、密码、线路区布局。
- 编辑页会从现有服务器 activeLineUrl 回填主机、端口、协议和路径；线路保存逻辑避免第一条线路重复。
- `ProtocolAddressField` 增加初始协议参数；`git diff --check` 通过，未执行 Flutter analyze（环境无 Dart/Flutter）。

## 2026-08-05 播放器媒体 Logo
- 原播放器顶部 `_mediaLogoUrl` 实际优先取海报/背景图，没有优先取 Emby Logo，导致左上角媒体标识错误。
- 已改为优先使用 `MediaItem.logoItemId/logoImageTag` 生成 Logo URL，再回退到自身/父级/系列海报，最后才回退背景图。
- 统一直链播放载荷 `SourcePlayback` 增加可选 `logoUrl`；统一详情页把 TMDB 外部 Logo 传给飞牛/直链播放器，播放器顶部优先使用该 Logo。
- 已同步播放器旧顶部和新 `PlayerOverlay` 两条渲染路径；`git diff --check` 通过。

## 2026-08-05 播放前后系统音量亮度
- 播放器进入时通过 Android system_controls 读取当前窗口亮度和媒体音量，并保存为本次播放会话快照。
- 播放过程中滑动调整不影响快照；退出播放页等待快照读取完成后恢复进入前的亮度和音量，而不是恢复系统默认值。
- 竖向亮度/音量调节手势确认方向后隐藏播放控制 UI，仅保留调节指示器；水平进度手势不受影响。
- `git diff --check` 通过；未安装 Dart/Flutter，未执行 analyze/真机回归。

## 2026-08-05 比例与详情选集
- 播放器比例菜单已移除“等比填充”，保留“自适应/裁切铺满”；历史 `拉伸` 配置按铺满兼容。
- 详情页电视剧进入时按观看记录选择最近播放季和集；选集横向列表会自动定位，非末集尽量置左，末集按最大滚动位置显示在右侧并露出前一集。
- 当季增加每 10 集一个区间选择器，例如 1-10、11-20、21-30。
- 初始视频比例计算加入 Emby DAR/SAR，原生 MPV 使用实际显示比例而不是单纯 width/height，修复非方形像素导致的画面扭曲。
- 详情页和播放器比例/选集改动 `git diff --check` 通过；未执行 Flutter analyze/真机回归。

## 2026-08-05 继续完成聚合与播放体验
- 播放器聚合无资源时不再打开空长条菜单，直接进入跨服搜索；有资源时保留资源卡片。
- 底部聚合搜索的飞牛服务器筛选允许只有用户名、尚未缓存 authToken 的服务器参与。
- 飞牛统一媒体资源增加字段别名归一化：编码、容器、采样率、位深、声道布局、SAR/DAR、色彩、HDR、帧率、GOP、时间基等。
- 详情页点击播放入口立即切换横屏/沉浸模式，网络解析在横屏播放器内等待。
- 长按倍速提示上移，亮度/音量每 5% 触发一次轻微震动且每次手势重置分段状态。
- `git diff --check` 通过；未安装 Dart/Flutter，未执行 analyze/真机回归。

## 2026-08-05 播放器内核与飞牛备份
- 播放器内核切换现写入当前媒体覆盖值，不再修改 `playerCoreProvider` 系统默认；初始化优先读取媒体级偏好。
- 统一详情页按当前条目匹配观看记录后恢复内核，避免误用同一作用域其它媒体的内核。
- CommonConfig 备份此前固定 `type: emby` 且恢复不还原源类型，导致飞牛恢复后被当作 Emby；现保存/恢复 `source_kind`，兼容 `sourceKind/type` 旧字段，并为飞牛补默认线路。
- 播放器 HUD 在内核/码率附近增加媒体体积，使用 MediaSource.size 格式化为 B/KB/MB/GB/TB。
- `git diff --check` 通过；环境无 Dart/Flutter，未执行 analyze 与真机回归。
- 弹幕轨道间距由固定 32px 改为跟随字号动态计算（34–56px），解决大字号重叠；显示区域变化会改变可用轨道数量。
- 滚动弹幕统一从屏幕右边缘出生，修正未到点弹幕直接跳入显示的问题。
- 弹幕 Ticker 不再因父层每次 position 微小更新而重置时间轴；仅 seek、换速、暂停恢复时重新锚定，解决倍速滚动跳帧。
- 暂停时同步 ticker 基准，恢复播放不产生时间跳跃；`git diff --check` 通过。

## 2026-08-06 本轮任务开始
- 已读取现有计划、发现和进度，确定修改 `/var/minis/shared/WJPlayer-gitwork`。
- 已确认当前工作区干净，基线为 `f6a6fac`；本地没有 Dart/Flutter，后续只能做静态检查与 diff 审查。
- 下一步：集中读取播放器核心文件和系统控制调用。

## 2026-08-06 播放器五项任务收尾
- 已完成页面级系统亮度/媒体音量快照：播放器服务重建不覆盖快照，最后一个播放器页面退出时恢复原值。
- 聚合按钮现在必定打开反馈；有资源最多显示 3 张详情页 PlaybackResourceCard，横向滑动且不再包裹外层胶囊；无资源显示搜索更多入口。
- 媒体信息改为整体面板，基础信息/轨道信息分页，内部使用普通信息行，不使用胶囊。
- 选集改为每页 5 集，支持左右滑动与翻页按钮，并定位当前集页。
- 空白区域命中层改为 opaque；播放器源码 4 个核心 Dart 文件括号检查通过，git diff --check 通过。
- 按用户要求不下载 SDK、不执行构建；GitHub 构建和 Flutter analyze 留给 CI。

## 2026-08-08 TV 焦点重构
- MainActivity.kt：仅拦截 MENU（keyCode==137）/TV_BACK，D-pad/确认/返回全部保留 Flutter 原生链路。
- 抽离 `lib/core/services/tv_key_channel.dart`：MethodChannel 只接收 MENU，转发到 dispatchGlobalTvKey，未处理时恢复 main_tabs。
- 新增 `lib/core/services/tv_focus_manager.dart`：集中式焦点管理器。支持 focusArea/registerArea/unregisterArea/switchArea/focusAt/moveDPad/releaseArea，带 lastFocusIndex 记忆与 canHandleDPad 条件接管。
- `lib/ui/widgets/common/tv_focus_widgets.dart`：TvFocusArea/TvFocusCard 组件 + TvKeyboardListener（D-pad 接管；未接管时回退到 Flutter 默认 next/left/right/up/down）。
- `lib/ui/widgets/common/tv_focusable.dart`：新增 `autofocus` 参数（默认 false），不再默认抢焦，由父级 FocusScope/管理器统一分配。
- `lib/routes/app_router.dart`：_FloatingTabBar 注册 main_tabs 区域，didUpdateWidget 在路由进出主页时 switchArea/releaseArea。
- `lib/app.dart`：根节点加 `Focus(autofocus:true, child: TvKeyboardListener(...))`。
- 静态检查：dart_lex_check 7 文件全 OK；git diff --check 通过；git status 干净。
- 不推不提交，等待用户确认。

## 2026-08-09 TV 卡片聚焦放大裁切修复（提示词 1）
用户反馈：TV 卡片聚焦放大时四周描边/圆角被裁切显示不全，卡片底部年份信息被遮挡。
**根因**：TvFocusable/TvFocusCard 的 AnimatedScale 放大 1.04 后溢出原始布局盒；GridView/ListView 默认 clipBehavior=Clip.hardEdge 把溢出部分裁掉；部分卡片 Card clipBehavior=Clip.antiAlias 也裁；网格间距不足时相邻卡片重叠。
**修复（10 文件）**：
1. **焦点组件留白**：tv_focusable.dart / tv_focus_widgets.dart 的 AnimatedScale 外包 `Padding(all:4)` —— 放大 1.04（约 4px 余量）+ 3px 描边不再溢出父容器边界被裁。手机端零副作用（非 TV 直接返回 child）。
2. **资源卡**：playback_resource_card.dart Card `clipBehavior: Clip.antiAlias → Clip.none`（selected 2.5px 描边曾被 antiAlias 裁掉）+ 内容外包 Padding(4) 防选中描边溢出（父列表已 Clip.none）。
3. **网格/列表释放裁切**：所有含 TvFocusable 卡片的 GridView/ListView 加 `clipBehavior: Clip.none`（discover 主网格/分类网格、unified 库网格/推荐网格/预览横滑/资源卡横滑、feiniu 库网格/预览横滑、libraries、favorites、server_list）。
4. **间距补偿**：卡片网格 mainAxisSpacing +4~6（14→18/20/22）、crossAxisSpacing +2（10→12/14）、外 padding 12→14/18，给放大溢出留呼吸空间。
5. **卡片高度补偿**：海报卡横滑区高度 220→236（统一/飞牛库预览）、选集 220→232、推荐 180→196；discover 海报卡 Column 外包 Padding(bottom:4) 保底部年份文字不被描边遮挡（年分行成为卡片末行，放大后描边覆盖）。
检查：git diff --check OK、10 文件括号平衡 OK。未提交不推送（等用户统一指示）。

## 2026-08-09 TV 方向键确定性导航（提示词 2）
用户反馈：首页右键整页滚动、下键随机乱跳、上键错误左翻页。要求：右键一次一卡、下键列对齐垂直分类切换、上键两段式（行内→本行查看更多→上一分类）。
**根因**：首页卡片走 TvFocusable 自建节点 + Flutter 默认几何遍历（水平 ListView 嵌套垂直 ListView 时遍历乱跳/翻页）。
**修复（5 文件）**：
1. **tv_focus_manager.dart**：`FocusSection` 增加 `trailing`（行尾查看更多）；`FocusSectionLayout.traversal` 重写——左/右逐卡片移动（行首/行尾停留、行尾卡片→查看更多）；下=下一分区同列 clamp（严禁水平跳转）；上=两段式（行内卡片→本行查看更多→上一分区同列 clamp）。新增全局 `appRouteObserver`（RouteObserver<ModalRoute>）。
2. **tv_focusable.dart**：`TvFocusable` 增加 `focusNode` 注入参数（外部节点不 dispose，listener 随 didUpdateWidget 切换），供 TvFocusManager 集中管理。
3. **tv_focus_widgets.dart**：`TvFocusArea` 加 `isTvPlatform` 守卫（手机端不注册）+ `_autoActivate`（区域就绪自动 switchArea 聚焦；其他区域节点有焦点时不抢占；页面被覆盖时不激活）。
4. **app_router.dart**：GoRouter 挂 `observers: [appRouteObserver]`。
5. **unified_media_screens.dart 首页**：`_UnifiedMediaHomeScreenState` with RouteAware（didPushNext→releaseArea('home_media')，didPopNext→switchArea 恢复）；`_load` 改为所有库预览一次性加载完再 setState（保证区域 count 稳定）；`_buildBody` 数据就绪且 TV 时包 `TvFocusArea('home_media', FocusSectionLayout)`；`_ContinueSection`（无查看更多）与 `_LibrarySection`（trailing=true）卡片挂区域节点，`查看全部` TextButton 挂行尾节点（focus overlay 高亮）；`_UnifiedMediaCard` 透传 focusNode。继续观看卡片补 TvFocusable 包装（原为裸 InkWell，TV 不可聚焦）+ 高度 166→182 + Clip.none。
验证：python 模拟 FocusSectionLayout 遍历 28 场景全 PASS（含两段式上键、列对齐下键、行尾查看更多、边界停留）；括号平衡 5 文件 OK；git diff --check OK。未提交不推送。

## 2026-08-09 状态栏菜单键进出与折叠联动（提示词 3）
用户反馈：MENU 键进出状态栏不稳定（退出后焦点不归还原位置）、收缩/折叠时 MENU 无法展开进入。
**根因**：toggleArea 进入/退出只做 switchArea/unfocus，无来源记忆——退出后焦点交还 Flutter 默认树（不回到进入前区域）；collapsed 时直接 switchArea 聚焦到记忆索引，但收缩模式只渲染搜索按钮，且不自动展开。
**修复（3 文件）**：
1. **tv_focus_manager.dart**：新增 `_returnAreaId` 来源记忆 + `enterArea`（记录来源→switchArea）/`exitArea`（unfocus→归还来源区域，来源已注销/无来源则交还默认树）/`clearReturnTarget`；删除旧 `toggleArea`；`moveDPad` 的 releaseOnUp（上键退出状态栏）分支同样归还来源区域，与 MENU 退出一致。
2. **tv_key_channel.dart**：默认 MENU 分支改 enterArea/exitArea（无 MainShell handler 时的兜底路径）。
3. **app_router.dart**：`_handleMenuKey` 改为——activeArea==main_tabs → exitArea；否则先 `_tabCollapsed.value=false` 自动展开再 enterArea（折叠联动）；`didUpdateWidget` 路由变化（currentPath 变）时 `clearReturnTarget()`（tab 间切换后旧来源失效，退出不回到不可见旧页面）。
验证：python 模拟 7 场景（区域来源归还/无区域交还/清来源/tab 切换/详情 push/来源注销/折叠）全 PASS；括号平衡 6 文件 OK；git diff --check OK。未提交不推送。

## 2026-08-09 状态栏左右键直接切换页面（模块四 提示词 1）
用户要求：状态栏焦点下按左/右键直接触发对应页面切换，无需先聚焦再按 OK。
**方案（2 文件）**：`FocusAreaConfig` 新增 `onMoveActivated` 回调——**仅** `moveDPad`（用户方向键移动导致索引变化）触发，`focusAt`/`switchArea`/`enterArea` 不触发（避免初始聚焦、MENU 进入恢复、collapsed 恢复搜索按钮时误切页面）。`_FloatingTabBar` 注册 main_tabs 时传 `onMoveActivated: (orderPos) => navigationShell.goBranch(_tabAt(orderPos))`——焦点左/右移即切换页面；OK 键 ActivateIntent 保留（幂等）。
**边界**：收缩模式只渲染搜索按钮节点（enabled=false 不可聚焦）→ 方向键走 Flutter 默认遍历不触发 moveDPad → 不会误切；goBranch 后 MainShell didUpdateWidget（currentPath 变）→ clearReturnTarget + switchArea('main_tabs') 保持焦点，不触发 onMoveActivated（无循环）。
验证：python 模拟（初始 focusAt/switchArea 不触发、左右移触发、边界停留不重复、恢复焦点不触发）PASS；括号 OK；git diff --check OK。未提交不推送。

## 2026-08-09 记录页焦点导航/多选删除/返回逻辑（模块四 提示词 2）
用户要求 TV 记录页：状态栏上键→刷新按钮、下键→第一张卡、上下选卡；长按 OK 多选删除（单击选中变色、上键到删除按钮 OK 删除）；返回阶梯（多选→取消、再返回→刷新按钮、再返回→状态栏）；最底部下键/任意返回→状态栏。
**实现（4 文件）**：
1. **tv_focus_manager.dart**：FocusAreaConfig 加 `onLongPressAt`（长按 OK 通知当前索引）/`onBoundary`（traversal 返回 -1 时区域间衔接）；nextIndex 透传 -1；moveDPad 处理 -1→onBoundary、releaseOnUp 无来源时切 `_currentPageAreaId` 初始位置（刷新按钮）、ignoreDown 时切 `_currentPageAreaId` index1（第一张卡）；新增 `_currentPageAreaId`/`setCurrentPageArea`。
2. **tv_focus_widgets.dart**：TvKeyboardListener 检测 enter/select 按键重复（KeyDownEvent.repeat）→ activeArea.onLongPressAt；TvFocusArea 透传 onLongPressAt/onBoundary。
3. **app_router.dart**：MainShell 新增 `_syncCurrentPageArea`（'/history'→'history'，initState/didUpdateWidget 调用）。
4. **history_screen.dart**：State 加 PopScope（TV canPop:false 拦截返回）→ `_handleTvBack` 阶梯（状态栏→exitArea+go('/discover')；多选→取消；卡片→focusAt(0) 刷新按钮；工具行/无焦点→enterArea('main_tabs')）；`_buildScaffold`（Builder 内取节点防未注册 StateError）；TvFocusArea('history') 包 Scaffold：traversal 自定义（0=工具行、1..N=卡片、上下边界 -1→onBoundary enterArea('main_tabs')、左右停留）；onLongPressAt 卡片→选中+进入多选；工具行节点复用（非多选=刷新按钮/多选=删除按钮）；卡片 focusNode 注入；区域 Key 随记录数重建。
**坑**：build 里先取 getFocusNode 会因区域未注册抛 StateError → 必须用 Builder 延迟到 TvFocusArea 挂载后；TvFocusArea 的 onLongPressAt/onBoundary 需透传；多选 toggle 时区域不重建（key 不变）而删除后重建（key 变）。
验证：python 模拟 14 场景全 PASS（状态栏进出、刷新按钮/第一卡导航、长按多选、删除按钮、返回阶梯、边界→状态栏、无焦点返回）；括号 4 文件 OK；git diff --check OK。未提交不推送。

## 2026-08-09 服务器列表页顶部按钮/显隐切换/排序逻辑（模块四 提示词 3）
用户要求 TV 服务器列表页：状态栏上键→右上角加号、左右键选旁边按钮；标题"服务器"焦点下连按三下 OK 切换隐藏卡片显隐；工具行任意按钮下键→列表；卡片 MENU→三点菜单；长按 OK→排序（抖动、方向键移动，单排上下、双排上下左右）。
**实现（3 文件）**：
1. **tv_focus_manager.dart**：`setCurrentPageArea` 增加 `topIndex`（状态栏上键切入位，服务器页=加号 3）/`firstCardIndex`（状态栏下键切入位=第一张卡 4）；releaseOnUp/ignoreDown 使用。
2. **app_router.dart**：MainShell `_syncCurrentPageArea` 加 '/servers' → ('servers', topIndex 3, firstCardIndex 4)。
3. **server_list_screen.dart**：
   - 区域 `TvFocusArea('servers')`：0..3=工具行（标题/布局切换/搜索/加号）、4..=卡片；traversal 工具行左右线性+下→第一卡+上→状态栏，卡片单排上下（左右停留）/双排 2 列上下左右，首卡上→工具行加号、末卡下→状态栏（onBoundary enterArea main_tabs）；Key 随 数量/布局/排序 重建。
   - 标题挂 TvFocusable（onActivate=_onTitleTap 三连击 OK 切换显隐）；工具行按钮挂节点。
   - 排序模式：长按 OK（onLongPressAt）→ `_sorting=true`+选中卡；traversal 换 `_sortingTraversal`（全向 -1 → onBoundary → `_moveSortingCard` 移动插入重排 reorderByVisibleIds + focusAt 跟随）；卡片 `_Shake` 抖动动画（往返平移+正弦）；OK/返回退出排序（PopScope TV 排序中拦截）。
   - MENU 键：注册全局 key handler，卡片焦点 → `_showServerMenu`（三点菜单）；`_MenuTile` 组件（TvFocusable 包 ListTile，首个 autofocus）TV 可聚焦。
   - 搜索模式（_isSearching）不注册区域（TextField 输入）。
验证：python 模拟 31 场景全 PASS（工具行导航/三连击显隐/边界→状态栏/排序单双排移动/菜单/来源归还）；括号 5 文件 OK；git diff --check OK。未提交不推送。

## 2026-08-09 服务器添加/编辑页表单焦点与删除逻辑（模块四 提示词 4）
用户要求 TV 添加/编辑表单：初始聚焦 emby/jellyfin 类型选择（SourcePickerScreen）上下选择；表单顺序 名称→备注→用户名→密码→TLS→加号→线路卡（备注→协议→地址→路径）→删除→保存；协议左右直接切换；卡内任意位置右→删除按钮；多线路时删除下→下一线路卡而非保存；最后才到保存。
**实现（3 文件）**：
1. **source_picker_screen.dart**：`TvFocusArea('source_picker')`（linear）包源类型列表；_SourceTypeCard 包 TvFocusable+注入节点；autoActivate 初始聚焦第一项；OK 进入添加表单。Key 随数量重建。
2. **server_form_widget.dart**：`TvFocusArea('server_form')`；元素索引 0名称/1备注/2用户名/3密码/4TLS/5加号 + 线路卡 i（base=6+5i：+0备注/+1协议/+2地址/+3路径/+4删除）+ 保存（6+5N）；traversal 上下线性（顶部/底部停留）、协议位左右→-1（onBoundary 切换 http/https，ProtocolAddressField 以 ValueKey('proto_$i_$protocol') 重建刷新）、卡内非协议/非删除位右→-1（onBoundary focusAt 删除按钮）；TextFields 挂区域节点（EditableText 自动滚动），按钮/TLS/保存包 TvFocusable（聚焦描边+ensureVisible 自动滚动）；线路数变化 Key 重建；手机端零副作用（TvFocusArea 平台守卫）。
3. **protocol_address_field.dart**：加 `focusNode` 参数透传给地址 TextField。
验证：python 模拟 38 场景全 PASS（顺序下移/顶部底部停留/协议左右切换不移动焦点/卡内右→删除/删除下→下一线路备注或保存/多线路遍历/普通字段左右停留）；括号 8 文件 OK；git diff --check OK。未提交不推送。

## 2026-08-09 设置界面聚焦高亮与返回状态栏（模块四 提示词 5）
用户要求 TV 设置页：卡片选中无高亮标识（聚焦框不可见/在卡片底部看不到）→ 加清晰聚焦高亮/边框；最底部"关于"卡片下键、任意位置返回键 → 回状态栏。
**实现（3 文件）**：
1. **settings_home.dart**（SettingsScreen）：`TvFocusArea('settings')` count=6 固定（界面/播放/弹幕/检查更新/备份恢复/关于），单列线性 traversal（顶部上/底部下 → -1 → onBoundary enterArea('main_tabs')）；PopScope（TV canPop:false）任意位置返回 → enterArea('main_tabs')，状态栏内返回 → exitArea + go('/discover')（回影视）；`_SettingsCard` 包 `TvFocusable`（聚焦主题色描边+放大高亮，focusNode 注入）；`_SettingsGroup` clipBehavior antiAlias→none（放大不裁切）。
2. **settings_screen.dart**：主文件补 tv_focus/tv_focusable/tv_focus_manager imports（part 文件共享）。
3. **app_router.dart**：`_syncCurrentPageArea` 加 '/settings' → ('settings', topIndex 0, firstCardIndex 0)。
验证：python 模拟 10 场景 PASS（状态栏进出、顺序下移、关于下→状态栏、首卡上→状态栏、返回阶梯、来源归还、左右停留）；括号 18 文件 OK；git diff --check OK。未提交不推送。

## 2026-08-09 任务栏搜索页焦点导航与聚合切换（模块四 提示词 6）
用户要求 TV 搜索页：状态栏上键 → 搜索框聚焦；右键 → 聚合框聚焦（OK 切换聚合方式）；选框聚焦时按返回键或下键 → 直接回状态栏。
**实现（2 文件）**：
1. **search_screen.dart**：`TvFocusArea('search')` count=2（0=搜索框、1=聚合开关）；traversal：聚合上→搜索框、搜索框上→-1（状态栏）、任意下→-1、右：搜索框→聚合、左：聚合→搜索框；onBoundary enterArea('main_tabs')；PopScope（TV canPop:false）选框返回→enterArea('main_tabs')、状态栏内返回→exitArea+go('/discover')；TextField focusNode 注入 + TV 关闭 autofocus（手机保留）；`_AggregateToggle` 包 TvFocusable（OK 切换聚合，聚焦描边）。
2. **app_router.dart**：`_syncCurrentPageArea` 加 '/search' → ('search', topIndex 0, firstCardIndex 0)。
验证：python 模拟 17 场景 PASS（状态栏进出、搜索框↔聚合框导航、OK 切换、下键/返回回状态栏、左右边界、来源归还）；括号 OK；git diff --check OK。未提交不推送。

## 2026-08-09 全局输入框两段式与菜单/返回键权限重构（模块四 提示词 7）
用户要求全局规则：① 输入框/配置选框聚焦时仅显示聚焦状态，绝不直接进入键盘输入，必须再次按 OK 才进入编辑；② MENU 返回状态栏仅限「影视页」（/discover）与「服务器内媒体页」（/home）；③ 其他页面（记录/设置/服务器列表/搜索）最底部下键或任意位置返回键 → 安全回状态栏。
**实现（5 文件）**：
1. **tv_focus_widgets.dart**：新增 `TvInputField` 两段式输入框组件——外部 focusNode（区域）聚焦仅显示主题色描边（不触发 IME）；OK（ActivateIntent）→ 内部 editorNode.requestFocus() 进入编辑（打开键盘）；编辑态隐藏外部描边（TextField 自身 focusedBorder）；聚焦自动 ensureVisible；手机端直接渲染编辑器零副作用。
2. **server_form_widget.dart**：表单 7 个 TextField 全部换 TvInputField（名称/备注/用户名/密码/线路备注/地址/路径）；地址位 = 协议 TvFocusable 包 TvInputField 包 ProtocolAddressField（协议左右切换不变，地址 OK 进入编辑）。
3. **search_screen.dart**：搜索框换 TvInputField（两段式）。
4. **app_router.dart**：`_handleMenuKey` 权限限定——path 非 /discover//home → handled 吞掉（不返回状态栏，且避免落到 tv_key_channel 默认分支）；影视页/服务器媒体页保留 MENU 进出状态栏。
5. **server_list_screen.dart**：PopScope 返回逻辑改造——TV 全拦截：状态栏内返回 → exitArea + go('/discover')；排序中 → 退出排序；普通返回 → enterArea('main_tabs')（与记录/设置/搜索页一致）。
验证：python 模拟 25 场景 PASS（MENU 各页面权限、三点菜单优先、返回阶梯、底部下键、来源归还）；括号 20 文件 OK；git diff --check OK。未提交不推送。
