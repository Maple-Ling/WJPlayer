import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'app_logger.dart';

class LibassBridge {
  static const _channel = MethodChannel('com.mapleling.wjplayer/libass');
  static final _logger = AppLogger();
  static bool _available = false;
  static bool _checked = false;

  static Future<bool> isAvailable() async {
    if (_checked) return _available;
    try {
      _available = await _channel.invokeMethod<bool>('isLibassAvailable') ?? false;
      _logger.i('LibassBridge', 'libass 可用性检查结果: $_available');
    } on PlatformException catch (e) {
      _logger.e('LibassBridge', 'libass 可用性检查失败: ${e.message}');
      _available = false;
    } on MissingPluginException catch (e) {
      _logger.e('LibassBridge', 'libass MethodChannel 未注册: ${e.message}');
      _available = false;
    } catch (e) {
      _logger.e('LibassBridge', 'libass 可用性检查异常: $e');
      _available = false;
    }
    _checked = true;
    return _available;
  }

  static Future<bool> init({required int width, required int height}) async {
    try {
      _logger.i('LibassBridge', '初始化 libass: ${width}x$height');
      final result = await _channel.invokeMethod<bool>('initLibass', {
        'width': width,
        'height': height,
      }) ?? false;
      _logger.i('LibassBridge', 'libass 初始化结果: $result');
      return result;
    } on PlatformException catch (e) {
      _logger.e('LibassBridge', 'libass 初始化失败: ${e.message}');
      return false;
    } catch (e) {
      _logger.e('LibassBridge', 'libass 初始化异常: $e');
      return false;
    }
  }

  static Future<bool> loadSubFile(String path) async {
    try {
      _logger.i('LibassBridge', '加载字幕文件: $path');
      final result = await _channel.invokeMethod<bool>('loadSubFile', {
        'path': path,
      }) ?? false;
      _logger.i('LibassBridge', '字幕文件加载结果: $result');
      return result;
    } on PlatformException catch (e) {
      _logger.e('LibassBridge', '加载字幕文件失败: ${e.message}');
      return false;
    } catch (e) {
      _logger.e('LibassBridge', '加载字幕文件异常: $e');
      return false;
    }
  }

  static Future<bool> loadSubMemory(Uint8List data, {String codec = 'ass'}) async {
    try {
      _logger.i('LibassBridge', '加载内存字幕: ${data.length} bytes, codec=$codec');
      final result = await _channel.invokeMethod<bool>('loadSubMemory', {
        'data': data,
        'codec': codec,
      }) ?? false;
      _logger.i('LibassBridge', '内存字幕加载结果: $result');
      return result;
    } on PlatformException catch (e) {
      _logger.e('LibassBridge', '加载内存字幕失败: ${e.message}');
      return false;
    } catch (e) {
      _logger.e('LibassBridge', '加载内存字幕异常: $e');
      return false;
    }
  }

  static Future<bool> setFontSize(int size) async {
    try {
      return await _channel.invokeMethod<bool>('setFontSize', {
        'size': size,
      }) ?? false;
    } on PlatformException catch (e) {
      _logger.e('LibassBridge', '设置字体大小失败: ${e.message}');
      return false;
    } catch (e) {
      _logger.e('LibassBridge', '设置字体大小异常: $e');
      return false;
    }
  }

  static Future<bool> setFontName(String name) async {
    try {
      return await _channel.invokeMethod<bool>('setFontName', {
        'name': name,
      }) ?? false;
    } on PlatformException catch (e) {
      _logger.e('LibassBridge', '设置字体名称失败: ${e.message}');
      return false;
    } catch (e) {
      _logger.e('LibassBridge', '设置字体名称异常: $e');
      return false;
    }
  }

  static Future<List<LibassBlendRect>?> renderFrame(int ptsMs) async {
    try {
      final raw = await _channel.invokeMethod<Uint8List?>('renderFrame', {
        'ptsMs': ptsMs,
      });
      if (raw == null) return null;
      return _parseRenderResult(raw);
    } on PlatformException catch (e) {
      _logger.e('LibassBridge', '渲染帧失败: ${e.message}');
      return null;
    } catch (e) {
      _logger.e('LibassBridge', '渲染帧异常: $e');
      return null;
    }
  }

  static Future<void> dispose() async {
    try {
      _logger.i('LibassBridge', '释放 libass');
      await _channel.invokeMethod<bool>('dispose');
    } on PlatformException catch (e) {
      _logger.e('LibassBridge', '释放 libass 失败: ${e.message}');
    } catch (e) {
      _logger.e('LibassBridge', '释放 libass 异常: $e');
    }
    _available = false;
    _checked = false;
  }

  static List<LibassBlendRect>? _parseRenderResult(Uint8List raw) {
    final rects = <LibassBlendRect>[];
    int offset = 0;
    final data = raw.buffer.asByteData();

    while (offset + 20 <= raw.length) {
      final w = data.getInt32(offset, Endian.host);
      offset += 4;
      final h = data.getInt32(offset, Endian.host);
      offset += 4;
      final stride = data.getInt32(offset, Endian.host);
      offset += 4;
      final dstX = data.getInt32(offset, Endian.host);
      offset += 4;
      final dstY = data.getInt32(offset, Endian.host);
      offset += 4;

      if (w <= 0 || h <= 0) break;
      final pixelCount = w * h;
      final byteCount = pixelCount * 4;
      if (offset + byteCount > raw.length) break;

      final pixels = Uint8List.sublistView(raw, offset, offset + byteCount);
      offset += byteCount;

      rects.add(LibassBlendRect(
        width: w,
        height: h,
        stride: stride,
        dstX: dstX,
        dstY: dstY,
        pixels: pixels,
      ));
    }
    return rects.isEmpty ? null : rects;
  }
}

class LibassBlendRect {
  final int width;
  final int height;
  final int stride;
  final int dstX;
  final int dstY;
  final Uint8List pixels;

  const LibassBlendRect({
    required this.width,
    required this.height,
    required this.stride,
    required this.dstX,
    required this.dstY,
    required this.pixels,
  });

  Future<ui.Image> toImage() async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (ui.Image image) => completer.complete(image),
    );
    return completer.future;
  }
}
