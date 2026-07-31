import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Cloudflare 官方公开的 IPv4 段（https://www.cloudflare.com/ips-v4）。
///
/// CF 优选的本质：CF 是 anycast，按 **SNI + Host** 调度回源——无论连到哪个
/// CF 边缘 IP，只要 TLS SNI / HTTP Host 仍是你的域名，就能正确回源。于是从
/// 这些段里随机抽样、就近测速，挑出对**本地网络**最快的边缘 IP 即可。
///
/// 这里内置一份（IPv4，覆盖绝大多数家宽场景；IPv6 暂不处理）。
const List<String> kCloudflareIpv4Cidrs = [
  '173.245.48.0/20',
  '103.21.244.0/22',
  '103.22.200.0/22',
  '103.31.4.0/22',
  '141.101.64.0/18',
  '108.162.192.0/18',
  '190.93.240.0/20',
  '188.114.96.0/20',
  '197.234.240.0/22',
  '198.41.128.0/17',
  '162.158.0.0/15',
  '104.16.0.0/13',
  '104.24.0.0/14',
  '172.64.0.0/13',
  '131.0.72.0/22',
];

class _Cidr {
  final int base; // 网络号（32 位整数）
  final int size; // 主机数
  const _Cidr(this.base, this.size);
}

_Cidr? _parseCidr(String cidr) {
  final parts = cidr.split('/');
  if (parts.length != 2) return null;
  final octets = parts[0].split('.');
  if (octets.length != 4) return null;
  var ip = 0;
  for (final o in octets) {
    final v = int.tryParse(o);
    if (v == null || v < 0 || v > 255) return null;
    ip = (ip << 8) | v;
  }
  final prefix = int.tryParse(parts[1]);
  if (prefix == null || prefix < 0 || prefix > 32) return null;
  final hostBits = 32 - prefix;
  final size = hostBits >= 31 ? (1 << 31) : (1 << hostBits);
  final mask = hostBits >= 32 ? 0 : (0xFFFFFFFF << hostBits) & 0xFFFFFFFF;
  return _Cidr(ip & mask, size);
}

String _intToIp(int v) {
  return '${(v >> 24) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 8) & 0xFF}.${v & 0xFF}';
}

/// 从 CF IPv4 段里随机抽样 [count] 个互不相同的 IP。
///
/// 抽样而非全量扫描：CF 段共数百万地址，全测不现实；随机抽样足以覆盖到
/// 就近边缘。会跳过每段的网络号/广播号附近，避免抽到不可用地址。
List<String> sampleCloudflareIps(int count, {Random? rng, List<String>? cidrs}) {
  final r = rng ?? Random();
  final ranges = <_Cidr>[];
  for (final c in (cidrs ?? kCloudflareIpv4Cidrs)) {
    final parsed = _parseCidr(c);
    if (parsed != null) ranges.add(parsed);
  }
  if (ranges.isEmpty || count <= 0) return const [];

  // 按段大小加权随机，避免小段被过度采样。
  final totalWeight = ranges.fold<int>(0, (s, c) => s + c.size);
  final seen = <int>{};
  final out = <String>[];
  var guard = 0;
  final maxGuard = count * 12 + 64;
  while (out.length < count && guard < maxGuard) {
    guard++;
    var pick = r.nextInt(totalWeight);
    _Cidr? chosen;
    for (final c in ranges) {
      if (pick < c.size) {
        chosen = c;
        break;
      }
      pick -= c.size;
    }
    chosen ??= ranges.last;
    // 段内随机偏移；> /24 的段跳过头尾 1 个，避开网络号/广播号。
    final span = chosen.size;
    final offset = span > 2 ? 1 + r.nextInt(span - 2) : r.nextInt(span);
    final ipInt = (chosen.base + offset) & 0xFFFFFFFF;
    if (seen.add(ipInt)) out.add(_intToIp(ipInt));
  }
  return out;
}

// ============================ IPv6 ============================

/// Cloudflare 优选 IPv6 段（取自 XIU2/CloudflareSpeedTest 的 ipv6.txt）。
///
/// 不是整段 /32（那是 2^96 个地址，随机命中率几乎为 0），而是社区已**优选过**的
/// 一批活跃 /48 块。配合下方「只随机化低 32 位」的采样（即 `前缀::xxxx:xxxx`，
/// 正是真实 CF v6 优选 IP 的形态），命中率高得多。
const List<String> kCloudflareIpv6Cidrs = [
  '2400:cb00:2049::/48', '2400:cb00:f00e::/48', '2606:4700::/32',
  '2606:4700:10::/48', '2606:4700:130::/48',
  '2606:4700:3000::/48', '2606:4700:3001::/48', '2606:4700:3002::/48',
  '2606:4700:3003::/48', '2606:4700:3004::/48', '2606:4700:3005::/48',
  '2606:4700:3006::/48', '2606:4700:3007::/48', '2606:4700:3008::/48',
  '2606:4700:3009::/48', '2606:4700:3010::/48', '2606:4700:3011::/48',
  '2606:4700:3012::/48', '2606:4700:3013::/48', '2606:4700:3014::/48',
  '2606:4700:3015::/48', '2606:4700:3016::/48', '2606:4700:3017::/48',
  '2606:4700:3018::/48', '2606:4700:3019::/48', '2606:4700:3020::/48',
  '2606:4700:3021::/48', '2606:4700:3022::/48', '2606:4700:3023::/48',
  '2606:4700:3024::/48', '2606:4700:3025::/48', '2606:4700:3026::/48',
  '2606:4700:3027::/48', '2606:4700:3028::/48', '2606:4700:3029::/48',
  '2606:4700:3030::/48', '2606:4700:3031::/48', '2606:4700:3032::/48',
  '2606:4700:3033::/48', '2606:4700:3034::/48', '2606:4700:3035::/48',
  '2606:4700:3036::/48', '2606:4700:3037::/48', '2606:4700:3038::/48',
  '2606:4700:3039::/48',
  '2606:4700:a0::/48', '2606:4700:a1::/48', '2606:4700:a8::/48',
  '2606:4700:a9::/48', '2606:4700:a::/48', '2606:4700:b::/48',
  '2606:4700:c::/48', '2606:4700:d0::/48', '2606:4700:d1::/48',
  '2606:4700:d::/48', '2606:4700:e0::/48', '2606:4700:e1::/48',
  '2606:4700:e2::/48', '2606:4700:e3::/48', '2606:4700:e4::/48',
  '2606:4700:e5::/48', '2606:4700:e6::/48', '2606:4700:e7::/48',
  '2606:4700:e::/48', '2606:4700:f1::/48', '2606:4700:f2::/48',
  '2606:4700:f3::/48', '2606:4700:f4::/48', '2606:4700:f5::/48',
  '2606:4700:f::/48',
  '2803:f800:50::/48', '2803:f800:51::/48',
  '2a06:98c1:3100::/48', '2a06:98c1:3101::/48', '2a06:98c1:3102::/48',
  '2a06:98c1:3103::/48', '2a06:98c1:3104::/48', '2a06:98c1:3105::/48',
  '2a06:98c1:3106::/48', '2a06:98c1:3107::/48', '2a06:98c1:3108::/48',
  '2a06:98c1:3109::/48', '2a06:98c1:310a::/48', '2a06:98c1:310b::/48',
  '2a06:98c1:310c::/48', '2a06:98c1:310d::/48', '2a06:98c1:310e::/48',
  '2a06:98c1:310f::/48', '2a06:98c1:3120::/48', '2a06:98c1:3121::/48',
  '2a06:98c1:3122::/48', '2a06:98c1:3123::/48', '2a06:98c1:3200::/48',
  '2a06:98c1:50::/48', '2a06:98c1:51::/48', '2a06:98c1:54::/48',
  '2a06:98c1:58::/48',
];

BigInt _bytesToBigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b & 0xff);
  }
  return v;
}

Uint8List _bigIntToBytes(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  final mask = BigInt.from(0xff);
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & mask).toInt();
    x = x >> 8;
  }
  return out;
}

BigInt _randomBigInt(int bits, Random r) {
  var v = BigInt.zero;
  var remaining = bits;
  while (remaining > 0) {
    final take = remaining >= 24 ? 24 : remaining; // r.nextInt 上限 1<<32
    v = (v << take) | BigInt.from(r.nextInt(1 << take));
    remaining -= take;
  }
  return v;
}

/// 真实 CF v6 优选 IP 形如 `<前缀>::xxxx:xxxx`（低 32 位有值，中间全 0），
/// 所以只随机化**低 32 位**——既贴合活跃地址形态、命中率高，又在每个已优选
/// /48 块内有足够多样性。各前缀**等概率**抽取（不按段大小加权，避免被那条
/// 宽 /32 吃掉名额）。
List<String> sampleCloudflareIpv6(int count, {Random? rng, List<String>? cidrs}) {
  final r = rng ?? Random();
  if (count <= 0) return const [];
  final full = (BigInt.one << 128) - BigInt.one;

  // 解析每段为「网络号 BigInt」（主机位清零）。
  final bases = <BigInt>[];
  for (final c in (cidrs ?? kCloudflareIpv6Cidrs)) {
    final slash = c.split('/');
    if (slash.length != 2) continue;
    final prefix = int.tryParse(slash[1]);
    if (prefix == null || prefix < 0 || prefix > 96) continue; // 需 ≥32 主机位
    final addr = InternetAddress.tryParse(slash[0]);
    if (addr == null || addr.rawAddress.length != 16) continue;
    final hostBits = 128 - prefix;
    final mask = full ^ ((BigInt.one << hostBits) - BigInt.one);
    bases.add(_bytesToBigInt(addr.rawAddress) & mask);
  }
  if (bases.isEmpty) return const [];

  final seen = <String>{};
  final out = <String>[];
  var guard = 0;
  final maxGuard = count * 12 + 64;
  while (out.length < count && guard < maxGuard) {
    guard++;
    final base = bases[r.nextInt(bases.length)];
    final ipInt = base | _randomBigInt(32, r); // 仅低 32 位
    try {
      final ip =
          InternetAddress.fromRawAddress(_bigIntToBytes(ipInt, 16)).address;
      if (seen.add(ip)) out.add(ip);
    } catch (_) {}
  }
  return out;
}
