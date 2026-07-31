import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 视频背景组件 - 用于详情页 Hero 区域
/// 自动播放、静音、循环播放视频，无需点击
class VideoBackground extends StatefulWidget {
  final String videoUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;

  const VideoBackground({
    super.key,
    required this.videoUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  @override
  State<VideoBackground> createState() => _VideoBackgroundState();
}

class _VideoBackgroundState extends State<VideoBackground> {
  Player? _player;
  VideoController? _controller;
  bool _isPlaying = false;
  bool _hasError = false;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  @override
  void didUpdateWidget(covariant VideoBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _disposePlayer();
      _initPlayer();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _disposePlayer();
    super.dispose();
  }

  Future<void> _initPlayer() async {
    // Android 使用原生 MPV，不初始化 media_kit
    if (Platform.isAndroid) {
      if (mounted && !_isDisposed) {
        setState(() => _hasError = true);
      }
      return;
    }

    try {
      final player = Player();
      final controller = VideoController(player);

      // 监听播放状态：真正开始播放后才显示视频，避免缓冲期显示暂停态
      player.stream.playing.listen((playing) {
        if (_isDisposed || !mounted) return;
        if (playing && !_isPlaying) {
          setState(() => _isPlaying = true);
        }
      });

      // 监听错误
      player.stream.error.listen((error) {
        if (_isDisposed || !mounted) return;
        if (error.toString().isNotEmpty) {
          setState(() => _hasError = true);
        }
      });

      // 静音 + 循环
      await player.setVolume(0);
      await player.setPlaylistMode(PlaylistMode.loop);

      // 打开媒体并强制播放
      await player.open(Media(widget.videoUrl));
      await player.play();

      if (!mounted || _isDisposed) return;
      setState(() {
        _player = player;
        _controller = controller;
      });

      // 安全兜底：即使没收到 playing 事件，2 秒后也尝试显示
      await Future.delayed(const Duration(seconds: 2));
      if (mounted && !_isDisposed && !_isPlaying && !_hasError) {
        setState(() => _isPlaying = true);
      }
    } catch (e) {
      if (mounted && !_isDisposed) {
        setState(() => _hasError = true);
      }
    }
  }

  void _disposePlayer() {
    _player?.dispose();
    _player = null;
    _controller = null;
    _isPlaying = false;
    _hasError = false;
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError || _controller == null || !_isPlaying) {
      return widget.placeholder ??
          Container(
            width: widget.width,
            height: widget.height,
            color: Colors.black,
          );
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Video(
        controller: _controller!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        controls: NoVideoControls,
      ),
    );
  }
}
