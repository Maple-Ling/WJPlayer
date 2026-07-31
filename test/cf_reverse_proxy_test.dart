import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/network/cf_proxy/cf_reverse_proxy.dart';

/// CF 本地反代集成测试：验证 keep-alive 连接复用（提速关键）+ 响应透传正确
/// （Content-Length / chunked）。用自签证书起一个 TLS「假上游」，让反代连它。
void main() {
  // 自签证书（CN=test.local，仅测试用）。反代 allowInsecureTls=true 接受它。
  const certPem = '''
-----BEGIN CERTIFICATE-----
MIIDCzCCAfOgAwIBAgIUajCGGM7/uR/4koJcVkonzf1eW3UwDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAwwKdGVzdC5sb2NhbDAeFw0yNjA3MDMwOTE3NTNaFw0zNjA2
MzAwOTE3NTNaMBUxEzARBgNVBAMMCnRlc3QubG9jYWwwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQCisaBngRC5F1g1Tm0PKigznFvKwM70weQaXBDUSGlk
mvjrUxwvXOFf8rLXL4bYs5jSk+FBOMg1LDlwRDs+EVlYq4dGjiPLmFknGlQiTW33
T8WP0JUJRyEpJzhaOJ61irifXF7diOEuLt/oNC78e5OCZ6UHJzJ1liCUFQ0a5O3C
1Zx3laDjp9TfIXnPEvrJGgb+SV8FXhAXoDhxfv7J5A6ZJuqTXrcOXBdASnGY2GrJ
xRPj81al/w//7Dbo5sDM9RVadlehWE1l/i2rUnOgScoOetsTfvAw0+Vo0+eGf5va
c93TMHy86PagdvNrBmTo6FctW+Pq6Q7QeXT01w5eHp+bAgMBAAGjUzBRMB0GA1Ud
DgQWBBTAlHyFi484trmUmTsp/gZzHumW1jAfBgNVHSMEGDAWgBTAlHyFi484trmU
mTsp/gZzHumW1jAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCc
QxgaPT1phHctYZLyDB32Zb/mslVuJq1cfH6ZMDTgccMlMnEmzBEb2IIybk+ltcVW
GM/jAUe8u6sVoD/1V907s+Wv4cUMgOoAi9Ij3UNvMHOsAgqMCQgtIjjpFGxdHQEB
I8Uq5UgsaITHtKjjXqnOnNbYFcETjAq+jmrLPRmFUv2Af30A4dbylbuF7X0nc950
hII7KtZ17iThq6JfSbIB0AVIMnfjvVuq6+mDbxz66jj2aErfCyWftPY3YlgKSblD
XGtXnWDUVlEWnA77vm3tltfUVMKZYC1Kj8uc7TTlAhTlMTpdVCvcdPM7XR71sjOI
+r+vl5iVzt2wtnkw2bwB
-----END CERTIFICATE-----
''';
  const keyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCisaBngRC5F1g1
Tm0PKigznFvKwM70weQaXBDUSGlkmvjrUxwvXOFf8rLXL4bYs5jSk+FBOMg1LDlw
RDs+EVlYq4dGjiPLmFknGlQiTW33T8WP0JUJRyEpJzhaOJ61irifXF7diOEuLt/o
NC78e5OCZ6UHJzJ1liCUFQ0a5O3C1Zx3laDjp9TfIXnPEvrJGgb+SV8FXhAXoDhx
fv7J5A6ZJuqTXrcOXBdASnGY2GrJxRPj81al/w//7Dbo5sDM9RVadlehWE1l/i2r
UnOgScoOetsTfvAw0+Vo0+eGf5vac93TMHy86PagdvNrBmTo6FctW+Pq6Q7QeXT0
1w5eHp+bAgMBAAECggEAAonP7V17o8+j7iz7kZ2ARBHf8sFgWTw/MVQXZSB+GHY8
hPtmeKyzzXntZWMV8QKYU0zAWnKm2QGIIeLGo9jEcpg2g5jLIS2O0ofcIS7hFNc3
R1+jO6JS95/nhqzUeROhfscDqeQtUzmi/630v7az3fh9ACgR5vjBKF5Ntoo01XHW
Wv1nzR5Miw14WnoDRIcAflq0p36F4XYagxuZlDd2X9vEYZ7UbQKNvWkg6goEnVgS
o/bBncxKkNj1e4d+ylJu3aLOtdoW62TiN/l1051qWxX4Uxm3ZQ6eNdjuyDW4ylq0
+5S5tukCj3J7HD6eHEfyuYAgSZrWPY/6RXPEPMEA0QKBgQDe6w39Nxoi06kXJyxk
tSy0ycRUkfe8UBFgXQTAgGRKpyrXOY1QXmiL0W2AIGy0EjRj3/+9vWk7K7jfY3k8
ozEYZrzzf06OZcYVve4PBbihyx+xosl2h87evBisimFOZ19OZ+KC04j5VJpYYQC+
NgxpsBNaMfN+ltP54TVD2BPEqwKBgQC61pK1MZksArQ/HftuQm2A7z5PYHPg3XgR
PGIJQVoP+fYBumgcPko781cKdw+KT73B6E/WXCcUAwNQY4I3eLNKrHOTybVuAuWx
0C387uFILz7Ehlr4BudqdFzvVp/+EG+8CZwERJPSnpj+ALORMUeVf5LzMbrkH428
0MZMFVEw0QKBgA+ZTy9K7c9GFG0EVrztWKWGAPESDc3lpHGj0LNPyLTYoczRwCvB
j3tJOmpe2nx3Uaczg4fZe0Wit5saMN+nY8YbWlmHrQ2V3Zij48a1VcgsmJkrlQFw
W2+Gpgtc25ZK8YZhCp6xAsK/wtUwZIbq7U9v/Mqw+CMBlu/DbKDEvA1lAoGAFKJ6
FXTi2894pLfk+upvOZwyn4WhhqYvCohGs4r6LWWH2+0Abo4amMBpToiTuMzRwkar
+pq23ijvBsPWr9Wux4KASUQvu3SqdZbuXU7sppJBNmc4SMhKaqFrWiuRA/hAvt24
02fXg51sfDELo+9zXnl2e1F0uJkbiEzueZypGOECgYBp18UfSOLx/+GaEhczbo5j
RzixrPFz8lFVAvLH6ARLurk/lFR7Z6N8AV5/u2nd/oT7PpJdI4h/WCOCTYOgdl7r
BDvBWhFngsRX166x/er91NYcTsIF9xXZKxA0szzOgjtmKAkBZ7Bj6KN4410Rbb/E
qdf4PwkEHeRy29xhMM9jZg==
-----END PRIVATE KEY-----
''';

  late SecureServerSocket upstream;
  late CfReverseProxy proxy;
  var acceptedConnections = 0;

  setUp(() async {
    acceptedConnections = 0;
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certPem))
      ..usePrivateKeyBytes(utf8.encode(keyPem));
    upstream = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4, 0, ctx);
    upstream.listen((socket) {
      acceptedConnections++;
      final buf = <int>[];
      socket.listen((data) {
        buf.addAll(data);
        // 支持一条连接上多个请求（keep-alive）。
        while (true) {
          final end = _headerEnd(buf);
          if (end < 0) break;
          final head = utf8.decode(buf.sublist(0, end));
          buf.removeRange(0, end + 4);
          final path = head.split('\r\n').first.split(' ')[1];
          if (path.startsWith('/chunked')) {
            socket.write('HTTP/1.1 200 OK\r\n'
                'Transfer-Encoding: chunked\r\n'
                'Connection: keep-alive\r\n\r\n'
                '5\r\nABCDE\r\n0\r\n\r\n');
          } else {
            socket.write('HTTP/1.1 200 OK\r\n'
                'Content-Length: 5\r\n'
                'Connection: keep-alive\r\n\r\n'
                'HELLO');
          }
        }
      });
    });

    proxy = CfReverseProxy(
      upstreamScheme: 'https',
      upstreamHost: 'test.local',
      upstreamPort: upstream.port,
      ip: '127.0.0.1',
      allowInsecureTls: true,
    );
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    await upstream.close();
  });

  Future<String> get(HttpClient client, String path) async {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:${proxy.port}$path'));
    final resp = await req.close();
    return utf8.decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)));
  }

  test('复用上游连接：3 个请求只握手/连一次', () async {
    final client = HttpClient(); // 默认对 127.0.0.1:port 开 keep-alive
    for (var i = 0; i < 3; i++) {
      expect(await get(client, '/cl$i'), 'HELLO');
    }
    client.close();
    // 关键断言：优选提速的核心——连接被复用，没有每请求一次 TLS 握手。
    expect(acceptedConnections, 1,
        reason: '上游应只被连一次（keep-alive 复用），实际 $acceptedConnections 次');
  });

  test('Content-Length 响应透传正确', () async {
    final client = HttpClient();
    expect(await get(client, '/cl'), 'HELLO');
    client.close();
  });

  test('chunked 响应正确解码转发', () async {
    final client = HttpClient();
    expect(await get(client, '/chunked'), 'ABCDE');
    client.close();
  });
}

int _headerEnd(List<int> data) {
  for (var i = 0; i + 3 < data.length; i++) {
    if (data[i] == 13 &&
        data[i + 1] == 10 &&
        data[i + 2] == 13 &&
        data[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}
