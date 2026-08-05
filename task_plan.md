# WJPlayer 剩余修改任务计划

## 当前基线
- 本地 HEAD: 97b75db (dev)
- 远端 origin/dev: 8580146

## 本轮完成
- [x] 播放记录页进入自动刷新 (history_screen initState/didChangeDependencies + app_router 路由监听)
- [x] 详情页浅蓝蒙版移除 (color_extractor gradientStart 改用背景色)
- [x] 详情页播放键分界线与渐变联动 (_PlaybackHeaderDelegate 随滚动渐隐)
- [x] 所有服务器首页本地持久化缓存 (HomeDataCache + HomeCacheLoader, 服务器隔离, 24h)
- [x] 聚合搜索复用 PlaybackResourceCard, 移除独立卡片实现
- [x] MediaItem/Library 补 fromJson/toJson 供缓存序列化

## 待用户确认
- 提交本地 + 是否推送 dev / 触发 CI（按用户指令）

## 环境说明
- 本地 Flutter 为 x86_64，缺 qemu ld-linux，无法本地编译；仅做静态括号/符号一致性检查。

## 本轮任务：统一飞牛文件浏览详情入口
- [x] 将 SourceBrowseScreen 的飞牛详情入口改为 UnifiedMediaDetailScreen
- [x] 确保统一详情页保留播放键下四个播放选项按钮
- [x] 确保统一详情页最底部保留媒体信息栏/文件信息
- [x] 修正飞牛条目转换，保证顶部封面、外部 TMDB 信息和播放资源使用正确 SourceEntry
- [x] 做 Dart 静态检查与差异审查

## 本轮任务：播放器内核按媒体持久化、飞牛备份恢复、媒体体积展示
- [x] 定位当前系统默认内核与单媒体播放参数存储/传递链路
- [x] 实现当前媒体内核覆盖：播放器和详情页修改只影响当前媒体；历史播放优先恢复覆盖值；未覆盖媒体继续使用系统默认
- [x] 详情页显示当前媒体实际内核（按匹配的媒体记录）
- [x] 修正飞牛备份/恢复：保存并恢复 sourceKind，兼容旧字段与默认线路
- [x] 在播放器 HUD 增加媒体文件体积（如 26.52 GB）
- [x] 静态检查、diff 审查；待 Dart/Flutter 与真机回归
