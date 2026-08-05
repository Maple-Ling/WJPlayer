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
