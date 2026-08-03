import 'package:flutter_test/flutter_test.dart';
import 'package:wjplayer/core/providers/server_providers.dart';
import 'package:wjplayer/core/services/config_transfer.dart';

void main() {
  test('二维码载荷 encode/decode 往返保留凭据', () async {
    final servers = [
      ServerConfig(
          id: 'a',
          name: 'Home',
          baseUrl: 'https://x',
          userId: 'u1',
          authToken: 't1'),
      ServerConfig(
          id: 'b',
          name: 'Work',
          baseUrl: 'https://y',
          userId: 'u2',
          authToken: 't2'),
    ];
    final payload = await ConfigTransfer.encode(servers);
    expect(payload.startsWith('LPSYNC1:'), true);

    final back = await ConfigTransfer.decode(payload);
    expect(back.length, 2);
    expect(back.firstWhere((s) => s.id == 'a').authToken, 't1');
    expect(back.firstWhere((s) => s.id == 'b').userId, 'u2');
  });

  test('非本 App 二维码被拒', () async {
    expect(() => ConfigTransfer.decode('https://example.com'),
        throwsA(isA<FormatException>()));
  });

  test('merge 按 id 去重(导入项覆盖旧项,新项追加)', () {
    final existing = [
      ServerConfig(id: 'a', name: 'old', baseUrl: 'https://x')
    ];
    final incoming = [
      ServerConfig(id: 'a', name: 'new', baseUrl: 'https://x2'),
      ServerConfig(id: 'c', name: 'c', baseUrl: 'https://z'),
    ];
    final merged = ConfigTransfer.merge(existing, incoming);
    expect(merged.length, 2);
    expect(merged.firstWhere((s) => s.id == 'a').name, 'new');
    expect(merged.any((s) => s.id == 'c'), true);
  });
}
