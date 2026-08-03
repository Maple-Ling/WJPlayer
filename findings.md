# 分析发现

基线：GitHub `Maple-Ling/WJPlayer`，tag `test-20260803.7`，commit `1b80b91`。

## 1. 设置界面卡片
定位：`lib/ui/screens/settings/settings_general.dart`。
当前“启动页”“壁纸”位于通用设置列表；“壁纸”还出现在外观弹层。按需求移除界面卡片中的两个入口；仅移除 UI 入口，不删除现有配置、Provider 或选择逻辑。

## 2. 底部导航闪烁
定位：`lib/routes/app_router.dart`，根导航壳 `_RootScaffold` 约 420 行以后；各根 Tab 使用 `context.go`。现象属于根壳切换时旧页面/旧导航图标参与过渡重绘。修改范围：根导航选中状态与切换方式，确保目标项一次更新，旧项不执行闪烁动画；不改页面内容。

## 3. 服务器首页按钮位置
定位：`lib/ui/screens/source/unified_media_screens.dart` 的 `UnifiedMediaHomeScreen`：AppBar 使用 `centerTitle: true`，标题是 `_UnifiedServerTitle`，右侧另有线路按钮。需只调整服务器按钮/标题定位到顶部中间，不改变线路按钮和其它首页布局。

## 4. 两个详情页
定位：`lib/ui/screens/detail/media_detail_screen.dart`（服务器媒体详情）与 `lib/ui/screens/discover/external_media_detail_screen.dart`（外部详情）。当前二者结构明显不同：服务器页为 DynamicBackground + 详情头 + 简介/季集/电影播放区；外部页为沉浸式 SliverAppBar + 播放按钮 + 外部资源/演员/剧照/推荐等。实施方向：以外部详情的视觉结构为模板重排服务器详情；保留两个独立路由/页面。只在服务器详情增加/保留播放按钮下四项“内核/线路/音频/字幕”，并把媒体信息、媒体路径移动至页面最底部；不将服务器详情改成外部数据逻辑。

## 5. MPV 比例与字幕
定位：`lib/ui/screens/player/player_screen_state.dart`（`_computeContentRect`、默认比例/渲染）、`lib/core/services/mpv_player_adapter.dart`（MPV 属性）、`lib/core/services/native_mpv_player_adapter.dart`（Android 原生 MPV）。当前已有 `aspectRatioProvider` 默认“自动”，但播放布局仍可能按容器比例计算；字幕已有 `sub-scale-by-window=no`、`sub-scale-with-window=no`、`sub-ass-scale-with-window=no`，但默认字幕尺寸 Provider 为 0.5，需仅 MPV 将默认字号放大 2 倍并保持字幕独立于画面缩放；Exo 相关代码不动。需区分“自动/原始比例”和用户手动“画面填充”，不改变 Exo。

## 6. 搜索
定位：`lib/core/providers/media_providers.dart`、`lib/core/api/emby_api.dart`、`lib/core/sources/feiniu_backend.dart`。
- Emby `search()` 未限制 `IncludeItemTypes`，普通搜索会返回 Episode；聚合虽客户端过滤 Movie/Series，但 `rankingCrossServerMatchProvider` 直接挑首个结果，可能挑到 Episode，造成全集只显示一集。修改普通与跨服查询服务端参数/客户端选择，统一只取 Movie/Series；剧集结果按 Series 保留全集，不返回 Episode。
- 飞牛搜索原生端点失败后走逐库兜底，但 `/item/list` 固定 `exclude_grouped_video: 1` 且仅按文本过滤；需继续保持 Movie/TV 顶层搜索，并修正聚合下的服务器查询/结果归一，避免漏搜。具体实现需再读 `_itemToEntry`、原生返回结构和 UI 过滤。

## 7. 服务器管理双排卡片高度
定位：`lib/ui/screens/server/server_list_screen.dart`，双排 `SliverGridDelegateWithFixedCrossAxisCount` 当前 `childAspectRatio: .68`。该比例造成卡片偏高；只调整双排网格比例/布局高度，不改单排卡片。

## 8. 三个点菜单
定位：`lib/ui/screens/server/server_list_screen.dart` `_showServerMenu`。当前菜单含“编辑信息、重新登录、服务器线路、修改图标、修改备注、删除”。按需求仅移除“重新登录”和“修改图标”两项，其余保留。

## 不涉及
不改用户未列出的设置、播放器 Exo 行为、其它导航页面、服务器卡片字段、线路功能、CI 或构建流程。

