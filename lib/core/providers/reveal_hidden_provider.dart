import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 是否在服务器列表「三击标题」显示了隐藏服务器（仅 UI 展示态）。
/// 提升为全局状态：为 true 时，带 hidden 标记的服务器**也参与聚合搜索**
/// （搜索过滤从「只看 hidden != true」放宽为「!hidden || 已三击显示」），
/// 与服务器列表里实际能看到的一致。
final revealHiddenServersProvider = StateProvider<bool>((ref) => false);
