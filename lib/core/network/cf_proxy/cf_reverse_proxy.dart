import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../services/app_logger.dart';

/// 本地反代：监听 `127.0.0.1:<随机端口>`，把明文 HTTP 桥接成到**优选 CF IP** 的 HTTPS。
///
/// 关键性能点——**上游连接复用（keep-alive 连接池）**：
/// 旧实现每个请求强制 `Connection: close`、一请求一条隧道，每次都要重新 TCP+TLS 握手；
/// 首页几十个接口/封面请求、视频的 Range 分段请求各付一次握手（几十~上百 ms），
/// 优选到的快 IP 完全被握手开销吃掉，表现为「优选了还是一样卡」。
/// 现在：客户端侧交给 `HttpServer`（自带请求解析 + keep-alive），上游侧维护一个到
/// 优选 IP 的 TLS 连接池，按 Content-Length / chunked 精确读完每个响应后把连接放回池子
/// 复用，省掉重复握手。响应体用 `addStream` 透传，天然带背压（视频不会在内存里堆积）。
class CfReverseProxy {
  static final AppLogger _log = AppLogger();

  final String upstreamScheme; // https
  final String upstreamHost; // emby 域名
  final int upstreamPort; // 443
  final bool allowInsecureTls;

  String _ip; // 当前优选 IP
  ServerSocket? _rawServer;
  HttpServer? _http;

  // 上游空闲连接池（复用免握手）。generation 在 updateIp 时自增，作废旧 IP 的连接。
  final Queue<_Upstream> _idle = Queue<_Upstream>();
  int _generation = 0;
  static const int _maxIdle = 6;

  CfReverseProxy({
    required this.upstreamScheme,
    required this.upstreamHost,
    required this.upstreamPort,
    required String ip,
    this.allowInsecureTls = false,
  }) : _ip = ip;

  int get port => _http?.port ?? 0;
  String get pinnedIp => _ip;

  Future<void> start() async {
    _rawServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final http = HttpServer.listenOn(_rawServer!);
    http.autoCompress = false; // 不再压缩：忠实透传上游字节
    http.defaultResponseHeaders.clear(); // 不注入 x-frame-options 等默认头
    http.serverHeader = null;
    http.idleTimeout = const Duration(seconds: 30);
    http.listen(_handle, onError: (e, _) {
      _log.w('CfProxy', '本地反代监听异常: $e');
    });
    _http = http;
    _log.i('CfProxy',
        '反代已启动 127.0.0.1:$port -> $upstreamScheme://$upstreamHost:$upstreamPort via $_ip');
  }

  /// 切换优选 IP：作废旧 IP 的空闲连接，之后新建连接走新 IP（端口不变）。
  void updateIp(String ip) {
    if (ip == _ip) return;
    _ip = ip;
    _generation++;
    _drainIdle();
    _log.i('CfProxy', '反代上游切换到 $_ip（端口 $port 不变）');
  }

  Future<void> stop() async {
    _drainIdle();
    try {
      await _http?.close(force: true);
    } catch (_) {}
    _http = null;
    _rawServer = null;
  }

  void _drainIdle() {
    while (_idle.isNotEmpty) {
      _idle.removeFirst().destroy();
    }
  }

  // ---------------------------------------------------------------------------
  // 上游连接池
  // ---------------------------------------------------------------------------

  Future<_Upstream> _acquire() async {
    while (_idle.isNotEmpty) {
      final u = _idle.removeFirst();
      if (!u.closed && u.generation == _generation) {
        u.fromPool = true;
        return u;
      }
      u.destroy();
    }
    final addr = InternetAddress.tryParse(_ip);
    final raw = await Socket.connect(addr ?? _ip, upstreamPort,
        timeout: const Duration(seconds: 15));
    try {
      raw.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    final secured = await SecureSocket.secure(
      raw,
      host: upstreamHost, // SNI=真实域名
      supportedProtocols: const ['http/1.1'],
      onBadCertificate: (_) => allowInsecureTls,
    );
    return _Upstream(secured, _generation)..fromPool = false;
  }

  void _release(_Upstream u) {
    if (u.closed || u.generation != _generation || _idle.length >= _maxIdle) {
      u.destroy();
      return;
    }
    u.fromPool = false;
    _idle.add(u);
  }

  // ---------------------------------------------------------------------------
  // 请求处理
  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;

    // 先缓冲请求体（Emby 只有小 JSON 的 POST），便于上游连接失效时安全重试。
    final Uint8List body;
    try {
      final bb = BytesBuilder(copy: false);
      await for (final chunk in req) {
        bb.add(chunk);
      }
      body = bb.takeBytes();
    } catch (_) {
      _safeClose(res, HttpStatus.badRequest);
      return;
    }

    final headBytes = _buildUpstreamHead(req, body.length);

    var attempt = 0;
    while (true) {
      _Upstream? up;
      var resStarted = false;
      try {
        up = await _acquire();
        final fromPool = up.fromPool;
        up.socket.add(headBytes);
        if (body.isNotEmpty) up.socket.add(body);
        await up.socket.flush();

        // 读状态行/响应头（尚未写客户端响应，失败可重试）。
        final statusLine = await up.reader.readLine();
        if (statusLine == null) {
          up.destroy();
          if (fromPool && attempt == 0) {
            attempt++;
            continue; // 池中连接被上游关闭 → 换新连接重试一次
          }
          throw const _ProxyError('上游空响应');
        }
        final head = await _readHead(up.reader, statusLine);

        // 开始写客户端响应——此后不可再重试。
        resStarted = true;
        _applyHead(res, req, head);
        final reusable = await _streamBody(up.reader, req, res, head);
        await res.close();
        if (reusable && !up.closed) {
          _release(up);
        } else {
          up.destroy();
        }
        return;
      } catch (e) {
        up?.destroy();
        if (!resStarted && attempt == 0 && (up?.fromPool ?? false)) {
          attempt++;
          continue;
        }
        if (!resStarted) {
          _log.w('CfProxy', '代理请求失败 via $_ip: $e');
          _safeClose(res, HttpStatus.badGateway);
        } else {
          // 响应已开始，只能中断连接。
          try {
            await res.close();
          } catch (_) {}
        }
        return;
      }
    }
  }

  /// 构造发往上游的请求头：改写 Host、去逐跳头、强制 keep-alive 复用连接。
  Uint8List _buildUpstreamHead(HttpRequest req, int bodyLength) {
    final target = req.uri.toString();
    final sb = StringBuffer()
      ..write('${req.method} ${target.isEmpty ? '/' : target} HTTP/1.1\r\n')
      ..write('Host: $upstreamHost\r\n');
    req.headers.forEach((name, values) {
      switch (name.toLowerCase()) {
        case 'host':
        case 'connection':
        case 'proxy-connection':
        case 'keep-alive':
        case 'upgrade':
        case 'transfer-encoding':
          return;
      }
      for (final v in values) {
        sb.write('$name: $v\r\n');
      }
    });
    // 原请求若是 chunked（已缓冲），补 Content-Length。
    if (bodyLength > 0 && req.headers.value('content-length') == null) {
      sb.write('Content-Length: $bodyLength\r\n');
    }
    sb.write('Connection: keep-alive\r\n\r\n');
    return latin1.encode(sb.toString());
  }

  Future<_Head> _readHead(_ByteReader r, String statusLine) async {
    final m = RegExp(r'^HTTP/\d\.\d\s+(\d{3})').firstMatch(statusLine);
    if (m == null) throw const _ProxyError('响应状态行非法');
    final code = int.parse(m.group(1)!);
    final reason = statusLine.substring(m.end).trim();

    final headers = <MapEntry<String, String>>[];
    int? contentLength;
    var chunked = false;
    var upstreamClose = false;
    while (true) {
      final line = await r.readLine();
      if (line == null) throw const _ProxyError('响应头未结束即断开');
      if (line.isEmpty) break;
      final c = line.indexOf(':');
      if (c <= 0) continue;
      final name = line.substring(0, c).trim();
      final value = line.substring(c + 1).trim();
      switch (name.toLowerCase()) {
        case 'content-length':
          contentLength = int.tryParse(value);
          continue;
        case 'transfer-encoding':
          if (value.toLowerCase().contains('chunked')) chunked = true;
          continue;
        case 'connection':
          if (value.toLowerCase().contains('close')) upstreamClose = true;
          continue;
        case 'keep-alive':
          continue;
      }
      headers.add(MapEntry(name, value));
    }
    return _Head(code, reason, headers, contentLength, chunked, upstreamClose);
  }

  void _applyHead(HttpResponse res, HttpRequest req, _Head h) {
    res.statusCode = h.code;
    try {
      if (h.reason.isNotEmpty) res.reasonPhrase = h.reason;
    } catch (_) {}
    for (final e in h.headers) {
      try {
        res.headers.add(e.key, e.value);
      } catch (_) {}
    }
    // HEAD：无实体但要如实回报资源 Content-Length（mpv 会用 HEAD 探测文件大小，
    // 回 0 会被当成空文件）。dart:io 对 HEAD 响应自动忽略 body，不会因长度不符报错。
    if (req.method == 'HEAD') {
      if (h.contentLength != null) res.headers.contentLength = h.contentLength!;
    } else if (h.code == HttpStatus.noContent ||
        h.code == HttpStatus.notModified ||
        (h.code >= 100 && h.code < 200)) {
      res.headers.contentLength = 0;
    } else if (!h.chunked && h.contentLength != null) {
      res.headers.contentLength = h.contentLength!; // 精确长度（Range 206 等）
    }
    // 其余（chunked / 读到关闭）交给 HttpResponse 自动分块。
  }

  Future<bool> _streamBody(
      _ByteReader r, HttpRequest req, HttpResponse res, _Head h) async {
    if (_isBodyless(h.code, req.method)) return !h.upstreamClose;
    if (h.chunked) {
      await res.addStream(r.readChunked());
      return !h.upstreamClose;
    }
    if (h.contentLength != null) {
      if (h.contentLength! > 0) await res.addStream(r.readN(h.contentLength!));
      return !h.upstreamClose;
    }
    // 无 Content-Length 也非 chunked：读到连接关闭，不能复用。
    await res.addStream(r.readUntilClose());
    return false;
  }

  bool _isBodyless(int code, String method) =>
      method == 'HEAD' ||
      code == HttpStatus.noContent ||
      code == HttpStatus.notModified ||
      (code >= 100 && code < 200);

  void _safeClose(HttpResponse res, int status) {
    try {
      res.statusCode = status;
    } catch (_) {}
    try {
      res.close();
    } catch (_) {}
  }
}

/// 一条到上游的复用连接：持有 socket + 贯穿多次响应的字节读取器。
class _Upstream {
  final SecureSocket socket;
  final int generation;
  final _ByteReader reader;
  bool closed = false;
  bool fromPool = false;

  _Upstream(this.socket, this.generation) : reader = _ByteReader(socket) {
    socket.done.whenComplete(() => closed = true);
  }

  void destroy() {
    closed = true;
    try {
      socket.destroy();
    } catch (_) {}
  }
}

class _Head {
  final int code;
  final String reason;
  final List<MapEntry<String, String>> headers;
  final int? contentLength;
  final bool chunked;
  final bool upstreamClose;
  const _Head(this.code, this.reason, this.headers, this.contentLength,
      this.chunked, this.upstreamClose);
}

class _ProxyError implements Exception {
  final String message;
  const _ProxyError(this.message);
  @override
  String toString() => 'ProxyError: $message';
}

/// 拉取式字节读取器（贯穿一条上游连接的多次响应）：支持按行读头、按长度读体、chunked 解码。
/// 读体用 `Stream` 产出，配合 `HttpResponse.addStream` 天然带背压。
class _ByteReader {
  final StreamIterator<List<int>> _it;
  List<int> _buf = const <int>[];
  int _pos = 0;

  _ByteReader(Stream<List<int>> stream) : _it = StreamIterator(stream);

  Future<bool> _more() async {
    while (_pos >= _buf.length) {
      if (!await _it.moveNext()) return false;
      _buf = _it.current;
      _pos = 0;
    }
    return true;
  }

  /// 读一行（不含 CRLF）。流结束且无残留返回 null。
  Future<String?> readLine() async {
    final out = <int>[];
    while (true) {
      if (!await _more()) return out.isEmpty ? null : latin1.decode(out);
      while (_pos < _buf.length) {
        final b = _buf[_pos++];
        if (b == 10) {
          if (out.isNotEmpty && out.last == 13) out.removeLast();
          return latin1.decode(out);
        }
        out.add(b);
        if (out.length > 65536) return null; // 单行过长，异常
      }
    }
  }

  /// 精确读 n 字节，逐段 yield（末尾若流提前结束则自然停止）。
  Stream<List<int>> readN(int n) async* {
    var left = n;
    while (left > 0) {
      if (!await _more()) return;
      final avail = _buf.length - _pos;
      final take = avail < left ? avail : left;
      yield _buf.sublist(_pos, _pos + take);
      _pos += take;
      left -= take;
    }
  }

  /// chunked 解码，yield 解码后的实体字节。
  Stream<List<int>> readChunked() async* {
    while (true) {
      final sizeLine = await readLine();
      if (sizeLine == null) return;
      final hex = sizeLine.split(';').first.trim();
      final size = int.tryParse(hex, radix: 16);
      if (size == null || size < 0) return;
      if (size == 0) {
        // 读掉 trailer，直到空行。
        while (true) {
          final l = await readLine();
          if (l == null || l.isEmpty) break;
        }
        return;
      }
      yield* readN(size);
      await readLine(); // 消费块数据后的 CRLF
    }
  }

  /// 读到连接关闭。
  Stream<List<int>> readUntilClose() async* {
    while (await _more()) {
      yield _buf.sublist(_pos);
      _pos = _buf.length;
    }
  }
}
