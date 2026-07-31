import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/network/prefetch_proxy/prefetch_proxy.dart';

/// 起一个支持 Range 的假上游，内容是可预测的字节模式（byte i = i % 251）。
Future<(HttpServer, String, Uint8List)> _fakeUpstream(int total) async {
  final data = Uint8List(total);
  for (var i = 0; i < total; i++) {
    data[i] = i % 251;
  }
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final resp = req.response;
    final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = total - 1;
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring(6).split('-');
      start = int.tryParse(spec[0]) ?? 0;
      if (spec.length > 1 && spec[1].trim().isNotEmpty) {
        end = int.tryParse(spec[1]) ?? (total - 1);
      }
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set('Content-Range', 'bytes $start-$end/$total');
    }
    resp.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
    resp.headers.contentLength = end - start + 1;
    resp.add(data.sublist(start, end + 1));
    await resp.close();
  });
  return (server, 'http://127.0.0.1:${server.port}/file.mp4', data);
}

Future<Uint8List> _getRange(String url, {int? start, int? end}) async {
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(url));
  if (start != null) {
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end ?? ''}');
  }
  final resp = await req.close();
  final out = BytesBuilder();
  await for (final chunk in resp) {
    out.add(chunk);
  }
  client.close(force: true);
  return out.toBytes();
}

void main() {
  test('代理顺序供给完整文件，字节与上游一致', () async {
    // 50MB，跨越多个 4MB 分段，触发多 worker 并发。
    final total = 50 * 1024 * 1024;
    final (upstream, url, data) = await _fakeUpstream(total);
    addTearDown(() => upstream.close(force: true));

    final localUrl = await PrefetchProxy.instance.start(
      upstreamUrl: url,
      threads: 4,
      cacheLimitBytes: 64 * 1024 * 1024,
    );
    addTearDown(() => PrefetchProxy.instance.stop());
    expect(localUrl, isNotNull);

    final served = await _getRange(localUrl!, start: 0);
    expect(served.length, total);
    // 抽样校验内容（全量逐字节太慢）。
    for (final i in [0, 1, 4 * 1024 * 1024, 12345678, total - 1]) {
      expect(served[i], i % 251, reason: 'byte $i 不一致');
    }
  });

  test('中段 Range 请求（模拟 seek）返回正确片段', () async {
    final total = 30 * 1024 * 1024;
    final (upstream, url, data) = await _fakeUpstream(total);
    addTearDown(() => upstream.close(force: true));

    final localUrl = await PrefetchProxy.instance.start(
      upstreamUrl: url,
      threads: 2,
      cacheLimitBytes: 32 * 1024 * 1024,
    );
    addTearDown(() => PrefetchProxy.instance.stop());
    expect(localUrl, isNotNull);

    final start = 10 * 1024 * 1024 + 7;
    final end = start + 1024 * 1024;
    final served = await _getRange(localUrl!, start: start, end: end);
    expect(served.length, end - start + 1);
    expect(served[0], start % 251);
    expect(served.last, end % 251);
  });
}
