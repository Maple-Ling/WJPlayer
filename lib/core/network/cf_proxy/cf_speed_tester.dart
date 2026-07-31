import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'cf_ip_ranges.dart';

/// 默认测速文件：社区托管在 Cloudflare R2 上的 100MB 文件（自定义域名、走 CF 边缘、
/// 已开缓存、R2 出站免费）。相比 speed.cloudflare.com 在国内更稳。可在设置里换成
/// 自己的测速文件或任意公共 CF 测速链接（下载测速会自动跟随重定向）。
const String kDefaultCfTestUrl =
    'https://speedtest.291277.xyz/%E6%96%87%E4%BB%B6-100MB.bin';

/// 优选的 IP 协议族。
/// - [auto]：探测本机是否有 IPv6，有则双栈测速，否则仅 IPv4。
/// - [v4] / [v6]：强制只测对应协议族。
/// - [dual]：强制双栈（即便探测不到 v6 也会尝试）。
enum CfIpMode { auto, v4, v6, dual }

CfIpMode cfIpModeFromName(String? name) {
  switch (name) {
    case 'v4':
      return CfIpMode.v4;
    case 'v6':
      return CfIpMode.v6;
    case 'dual':
      return CfIpMode.dual;
    default:
      return CfIpMode.auto;
  }
}

/// 取消令牌：测速过程中置 [canceled] 即尽快中止。
class CfCancelToken {
  bool canceled = false;
  void cancel() => canceled = true;
}

enum CfTestPhase { sampling, latency, validate, download, done, error }

/// 单个 IP 的测速结果。
class CfTestResult {
  final String ip;

  /// 平均 TCP 握手延迟（成功样本的均值）。
  final Duration latency;

  /// 丢包率 0..1（失败样本 / 总样本）。
  final double lossRate;

  /// 下载速度（KB/s）。未做下载测速时为 null。
  final double? downloadKBps;

  const CfTestResult({
    required this.ip,
    required this.latency,
    required this.lossRate,
    this.downloadKBps,
  });

  CfTestResult copyWith({double? downloadKBps}) => CfTestResult(
        ip: ip,
        latency: latency,
        lossRate: lossRate,
        downloadKBps: downloadKBps ?? this.downloadKBps,
      );

  int get latencyMs => latency.inMilliseconds;

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'latencyMs': latencyMs,
        'lossRate': lossRate,
        if (downloadKBps != null) 'downloadKBps': downloadKBps,
      };

  static CfTestResult? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final ip = j['ip'] as String?;
    if (ip == null) return null;
    return CfTestResult(
      ip: ip,
      latency: Duration(milliseconds: (j['latencyMs'] as num?)?.toInt() ?? 0),
      lossRate: (j['lossRate'] as num?)?.toDouble() ?? 0,
      downloadKBps: (j['downloadKBps'] as num?)?.toDouble(),
    );
  }
}

/// 进度回调载荷。
class CfTestProgress {
  final CfTestPhase phase;
  final int tested;
  final int total;
  final CfTestResult? best;
  final String? message;

  const CfTestProgress({
    required this.phase,
    this.tested = 0,
    this.total = 0,
    this.best,
    this.message,
  });
}

/// 测速参数（均有合理默认值）。
class CfSpeedTestOptions {
  final int sampleCount; // 抽样多少个候选 IP
  final int latencyConcurrency; // 延迟测速并发
  final int pingSamples; // 每个 IP 的 TCP 握手采样次数
  final Duration pingTimeout; // 单次握手超时
  final double maxLossRate; // 丢包率超过则淘汰
  final int maxLatencyMs; // 延迟上限：超过视为不可用，直接淘汰（默认 500ms）
  final int latencyTierMs; // 排名时的延迟分档粒度（同档内才比速度）
  final int latencyKeepTop; // 延迟排序后保留多少个进入下载测速
  final int downloadWanted; // 下载测速命中多少个达标 IP 后提前停止
  final Duration downloadDuration; // 单个 IP 的下载测速时长
  final double minDownloadKBps; // 达标速度阈值（KB/s），0 = 不设阈值取最快
  final String testUrl; // 下载测速地址
  final CfIpMode ipMode; // 优选协议族
  // HTTP 校验域名：通常是 Emby 域名。用 https://<域名>/cdn-cgi/trace 验证候选 IP
  // 是否真的能为该域名提供 HTTP 服务（trace 由 CF 边缘直接应答，不回源、不加载 Emby）。
  // 借此剔除「TCP 通但 HTTP 死」的 IP，并确认该域名确实走 Cloudflare。空=跳过校验。
  final String validateHost;

  const CfSpeedTestOptions({
    this.sampleCount = 256,
    this.latencyConcurrency = 64,
    this.pingSamples = 4,
    this.pingTimeout = const Duration(milliseconds: 1000),
    this.maxLossRate = 0.5,
    this.maxLatencyMs = 500,
    this.latencyTierMs = 50,
    this.latencyKeepTop = 24,
    this.downloadWanted = 4,
    this.downloadDuration = const Duration(seconds: 6),
    this.minDownloadKBps = 0,
    this.testUrl = kDefaultCfTestUrl,
    this.ipMode = CfIpMode.auto,
    this.validateHost = '',
  });

  CfSpeedTestOptions copyWith({
    int? sampleCount,
    String? testUrl,
    Duration? downloadDuration,
    double? minDownloadKBps,
    CfIpMode? ipMode,
    String? validateHost,
  }) =>
      CfSpeedTestOptions(
        sampleCount: sampleCount ?? this.sampleCount,
        latencyConcurrency: latencyConcurrency,
        pingSamples: pingSamples,
        pingTimeout: pingTimeout,
        maxLossRate: maxLossRate,
        maxLatencyMs: maxLatencyMs,
        latencyTierMs: latencyTierMs,
        latencyKeepTop: latencyKeepTop,
        downloadWanted: downloadWanted,
        downloadDuration: downloadDuration ?? this.downloadDuration,
        minDownloadKBps: minDownloadKBps ?? this.minDownloadKBps,
        testUrl: testUrl ?? this.testUrl,
        ipMode: ipMode ?? this.ipMode,
        validateHost: validateHost ?? this.validateHost,
      );
}

/// 排名规则：体现「延迟低优先，然后才是速度」。
/// 先按延迟分档（默认每 50ms 一档）——档低者优先；同一档内才比下载速度（高者优先）。
/// 这样既不会让一个 480ms 但很快的 IP 压过 60ms 的，又能在延迟相近时挑最快的。
int _rankCompare(CfTestResult a, CfTestResult b, CfSpeedTestOptions o) {
  final tier = o.latencyTierMs <= 0 ? 1 : o.latencyTierMs;
  final ta = a.latencyMs ~/ tier;
  final tb = b.latencyMs ~/ tier;
  if (ta != tb) return ta.compareTo(tb);
  return (b.downloadKBps ?? 0).compareTo(a.downloadKBps ?? 0);
}

/// CF 优选测速引擎。流程对标 XIU2/CloudflareSpeedTest：
/// 1) 随机抽样 CF IP；2) TCP 握手延迟 + 丢包筛选并排序；
/// 3) 对延迟最优的若干个做 HTTPS 下载测速（SNI=测速域名）；
/// 4) 按下载速度排序返回（无下载速度时退回延迟）。
class CfSpeedTester {
  Future<List<CfTestResult>> run({
    CfSpeedTestOptions options = const CfSpeedTestOptions(),
    void Function(CfTestProgress)? onProgress,
    CfCancelToken? cancel,
  }) async {
    bool canceled() => cancel?.canceled == true;

    onProgress?.call(const CfTestProgress(
        phase: CfTestPhase.sampling, message: '正在抽样 Cloudflare IP…'));
    final ips = await _gatherIps(options);
    if (ips.isEmpty) {
      onProgress?.call(const CfTestProgress(
          phase: CfTestPhase.error, message: '无可用 IP 段（或本机无 IPv6）'));
      return const [];
    }

    // ---- 阶段一：TCP 握手延迟 + 丢包 ----
    final latencyResults = <CfTestResult>[];
    var tested = 0;
    CfTestResult? bestSoFar;

    final queue = List<String>.from(ips);
    var index = 0;
    Future<void> worker() async {
      while (true) {
        if (canceled()) return;
        final int i;
        if (index >= queue.length) return;
        i = index++;
        final ip = queue[i];
        final r = await _measureLatency(ip, options);
        tested++;
        // 丢包过高、或延迟 > 上限（默认 500ms，基本卡到不能用）直接淘汰。
        if (r != null &&
            r.lossRate <= options.maxLossRate &&
            r.latencyMs <= options.maxLatencyMs) {
          latencyResults.add(r);
          if (bestSoFar == null || r.latency < bestSoFar!.latency) {
            bestSoFar = r;
          }
        }
        if (tested % 3 == 0 || tested == ips.length) {
          onProgress?.call(CfTestProgress(
            phase: CfTestPhase.latency,
            tested: tested,
            total: ips.length,
            best: bestSoFar,
            message: '测延迟 $tested/${ips.length}',
          ));
        }
      }
    }

    final workers = List.generate(
      min(options.latencyConcurrency, queue.length),
      (_) => worker(),
    );
    await Future.wait(workers);
    if (canceled()) return const [];

    if (latencyResults.isEmpty) {
      onProgress?.call(CfTestProgress(
          phase: CfTestPhase.error,
          message: '没有延迟 ≤ ${options.maxLatencyMs}ms 的可用 IP'));
      return const [];
    }

    // 延迟低优先（丢包做次级 tiebreak）→ 下载测速先测延迟最低的那批。
    latencyResults.sort((a, b) {
      final cmp = a.latency.compareTo(b.latency);
      if (cmp != 0) return cmp;
      return a.lossRate.compareTo(b.lossRate);
    });
    var candidates =
        latencyResults.take(options.latencyKeepTop).toList(growable: false);
    int rank(CfTestResult a, CfTestResult b) => _rankCompare(a, b, options);

    // ---- 阶段二：HTTP 校验（并发）----
    // 用 https://<域名>/cdn-cgi/trace 验证候选 IP 是否真能为该域名提供 HTTP 服务。
    // trace 由 CF 边缘直接应答（不回源、不加载 Emby），既能剔除「TCP 通但 HTTP 死」
    // 的 IP（如只应 ping 不应 HTTP 的边缘），也能确认该域名确实走 Cloudflare。
    final host = options.validateHost.trim();
    if (host.isNotEmpty) {
      final validated = <CfTestResult>[];
      var vIndex = 0;
      var vDone = 0;
      Future<void> vWorker() async {
        while (true) {
          if (canceled()) return;
          if (vIndex >= candidates.length) return;
          final c = candidates[vIndex++];
          final ok = await _httpValidate(c.ip, host);
          vDone++;
          if (ok) validated.add(c);
          onProgress?.call(CfTestProgress(
            phase: CfTestPhase.validate,
            tested: vDone,
            total: candidates.length,
            best: validated.isEmpty
                ? null
                : (validated.toList()..sort((a, b) => a.latency.compareTo(b.latency)))
                    .first,
            message: 'HTTP 校验 $vDone/${candidates.length}',
          ));
        }
      }

      await Future.wait(
          List.generate(min(16, candidates.length), (_) => vWorker()));
      if (canceled()) return const [];
      if (validated.isEmpty) {
        onProgress?.call(CfTestProgress(
            phase: CfTestPhase.error,
            message: '没有能为 $host 提供 HTTP 服务的优选 IP（该域名是否走 Cloudflare？）'));
        return const [];
      }
      validated.sort((a, b) => a.latency.compareTo(b.latency));
      candidates = validated;
    }

    // ---- 阶段三：下载测速 ----
    final downloaded = <CfTestResult>[];
    final testUri = Uri.parse(options.testUrl);
    for (var i = 0; i < candidates.length; i++) {
      if (canceled()) break;
      if (downloaded.length >= options.downloadWanted) break;
      final c = candidates[i];
      onProgress?.call(CfTestProgress(
        phase: CfTestPhase.download,
        tested: i,
        total: candidates.length,
        best: downloaded.isEmpty ? null : downloaded.first,
        message: '下载测速 ${c.ip}（${c.latencyMs}ms）',
      ));
      final kbps = await _measureDownload(c.ip, testUri, options);
      if (kbps != null && kbps > 0) {
        final res = c.copyWith(downloadKBps: kbps);
        downloaded.add(res);
        downloaded.sort(rank);
        onProgress?.call(CfTestProgress(
          phase: CfTestPhase.download,
          tested: i + 1,
          total: candidates.length,
          best: downloaded.first,
          message:
              '${c.ip}: ${(kbps / 1024).toStringAsFixed(2)} MB/s',
        ));
      }
    }

    final List<CfTestResult> finalList;
    if (downloaded.isNotEmpty) {
      // 满足阈值的优先；都不满足则按速度取最快。
      final qualified = options.minDownloadKBps > 0
          ? downloaded
              .where((r) => (r.downloadKBps ?? 0) >= options.minDownloadKBps)
              .toList()
          : downloaded;
      finalList = (qualified.isNotEmpty ? qualified : downloaded);
    } else {
      // 下载测速全失败（如测速文件被墙）：退回**已通过 HTTP 校验**的 IP（按延迟排序）。
      // 这些 IP 已确认能为该域名提供 HTTP 服务，可安全反代，只是没测出带宽。
      finalList = candidates;
    }

    onProgress?.call(CfTestProgress(
      phase: CfTestPhase.done,
      tested: ips.length,
      total: ips.length,
      best: finalList.first,
      message: '完成',
    ));
    return finalList;
  }

  /// 按 [CfSpeedTestOptions.ipMode] 抽样候选 IP（v4 / v6 / 双栈 / 自动探测）。
  Future<List<String>> _gatherIps(CfSpeedTestOptions options) async {
    var mode = options.ipMode;
    if (mode == CfIpMode.auto) {
      mode = await _hasIpv6() ? CfIpMode.dual : CfIpMode.v4;
    }
    switch (mode) {
      case CfIpMode.v4:
        return sampleCloudflareIps(options.sampleCount);
      case CfIpMode.v6:
        return sampleCloudflareIpv6(options.sampleCount);
      case CfIpMode.dual:
      case CfIpMode.auto:
        final half = (options.sampleCount / 2).ceil();
        return [
          ...sampleCloudflareIps(half),
          ...sampleCloudflareIpv6(half),
        ];
    }
  }

  /// 快速探测本机是否有可用 IPv6（连 Cloudflare 公共 DNS 的 v6）。
  Future<bool> _hasIpv6() async {
    for (final ip in const ['2606:4700:4700::1111', '2606:4700:4700::1001']) {
      try {
        final s = await Socket.connect(InternetAddress(ip), 443,
            timeout: const Duration(milliseconds: 800));
        s.destroy();
        return true;
      } catch (_) {}
    }
    return false;
  }

  /// TCP 握手延迟 + 丢包。多次握手取均值；任一成功即记录。
  Future<CfTestResult?> _measureLatency(
      String ip, CfSpeedTestOptions options) async {
    final addr = InternetAddress.tryParse(ip);
    if (addr == null) return null;
    var success = 0;
    var totalMs = 0;
    for (var i = 0; i < options.pingSamples; i++) {
      final sw = Stopwatch()..start();
      try {
        final socket =
            await Socket.connect(addr, 443, timeout: options.pingTimeout);
        sw.stop();
        success++;
        totalMs += sw.elapsedMilliseconds;
        socket.destroy();
      } catch (_) {
        sw.stop();
      }
    }
    if (success == 0) return null;
    return CfTestResult(
      ip: ip,
      latency: Duration(milliseconds: (totalMs / success).round()),
      lossRate: (options.pingSamples - success) / options.pingSamples,
    );
  }

  /// 用 `https://<host>/cdn-cgi/trace` 校验候选 IP 能否为该域名提供 HTTP 服务。
  /// 成功（拿到 2xx/3xx 状态行）返回 true；首字节超时/连接关闭/握手失败/4xx+ 返回 false。
  /// trace 由 CF 边缘直接应答，不回源、不加载 Emby。
  Future<bool> _httpValidate(String ip, String host) async {
    final addr = InternetAddress.tryParse(ip);
    if (addr == null) return false;
    Socket? raw;
    SecureSocket? tls;
    try {
      raw = await Socket.connect(addr, 443,
          timeout: const Duration(seconds: 4));
      tls = await SecureSocket.secure(
        raw,
        host: host,
        supportedProtocols: const ['http/1.1'],
        onBadCertificate: (_) => true,
      ).timeout(const Duration(seconds: 4));
      tls.write('GET /cdn-cgi/trace HTTP/1.1\r\n'
          'Host: $host\r\n'
          'User-Agent: WJPlayer-CFTest\r\n'
          'Connection: close\r\n\r\n');
      await tls.flush();

      final header = <int>[];
      final completer = Completer<bool>();
      final to = Timer(const Duration(seconds: 4), () {
        if (!completer.isCompleted) completer.complete(false);
      });
      late StreamSubscription sub;
      sub = tls.listen(
        (chunk) {
          header.addAll(chunk);
          final idx = _indexOfHeaderEnd(header);
          if (idx >= 0 && !completer.isCompleted) {
            completer.complete(_isReachableStatus(header, idx));
            sub.cancel();
            tls?.destroy();
          } else if (header.length > 8192 && !completer.isCompleted) {
            completer.complete(false);
            sub.cancel();
            tls?.destroy();
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
        cancelOnError: true,
      );
      final ok = await completer.future;
      to.cancel();
      await sub.cancel();
      return ok;
    } catch (_) {
      return false;
    } finally {
      try {
        tls?.destroy();
      } catch (_) {}
      try {
        raw?.destroy();
      } catch (_) {}
    }
  }

  /// HTTPS 下载测速：连到候选 IP:443，TLS 用测速域名做 SNI，GET 测速文件，
  /// 在 [options.downloadDuration] 时间窗内统计吞吐（首字节后开始计时）。
  /// **要求最终 HTTP 200**（剔除 403/404 等错误页）并至少下到 64KB；遇到 3xx 会
  /// **跟随重定向**（最多 2 跳，仍钉同一候选 IP）——许多公共测速链接（如 XIU2 的
  /// `cf.xiu2.xyz/url`）都是重定向。返回 KB/s，失败 null。
  Future<double?> _measureDownload(String ip, Uri testUri,
      CfSpeedTestOptions options,
      [int depth = 0]) async {
    final host = testUri.host;
    // 用**已编码**的 origin-form 作请求目标（testUri.path 是解码后的，含中文等
    // 非 ASCII 会让请求行非法、被部分 CDN 拒或行为不定）。
    final pathQuery = _originForm(testUri);
    final addr = InternetAddress.tryParse(ip);
    if (addr == null) return null;
    Socket? raw;
    SecureSocket? tls;
    try {
      raw = await Socket.connect(addr, 443,
          timeout: const Duration(seconds: 4));
      tls = await SecureSocket.secure(
        raw,
        host: host,
        supportedProtocols: const ['http/1.1'],
        onBadCertificate: (_) => true, // 测速只看吞吐，不校验证书
      ).timeout(const Duration(seconds: 4));

      tls.write('GET $pathQuery HTTP/1.1\r\n'
          'Host: $host\r\n'
          'User-Agent: Mozilla/5.0 WJPlayer-CFTest\r\n'
          'Accept: */*\r\n'
          'Connection: close\r\n\r\n');
      await tls.flush();

      final header = <int>[];
      var headerDone = false;
      var measuring = false; // 状态行是否 2xx，开始计吞吐
      var bytes = 0;
      Stopwatch? sw;
      Uri? redirectTo;
      final completer = Completer<double?>();

      double? tput() {
        final s = sw;
        if (!measuring || s == null) return null;
        final secs = s.elapsedMilliseconds / 1000.0;
        if (secs <= 0.05 || bytes < 65536) return null; // 太短/太小不可信
        return (bytes / 1024.0) / secs;
      }

      void finish(double? v) {
        if (!completer.isCompleted) completer.complete(v);
      }

      // 首字节 4s 超时：没拿到响应头视为不可用（剔除 TCP 通但 HTTP 死的 IP）。
      final ttfb = Timer(const Duration(seconds: 4), () {
        if (!headerDone) finish(null);
      });
      final deadline = Timer(
          options.downloadDuration + const Duration(seconds: 2),
          () => finish(tput()));

      late StreamSubscription sub;
      sub = tls.listen(
        (chunk) {
          if (!headerDone) {
            header.addAll(chunk);
            final idx = _indexOfHeaderEnd(header);
            if (idx >= 0) {
              headerDone = true;
              ttfb.cancel();
              final code = _statusCode(header, idx);
              if (code >= 300 && code < 400 && depth < 2) {
                redirectTo = _parseLocation(header, idx, testUri);
                finish(null); // 跳出后递归跟随
                sub.cancel();
                tls?.destroy();
                return;
              }
              if (!(code >= 200 && code < 300)) {
                finish(null);
                sub.cancel();
                tls?.destroy();
                return;
              }
              measuring = true;
              sw = Stopwatch()..start();
              bytes += header.length - (idx + 4);
            }
          } else if (measuring) {
            bytes += chunk.length;
          }
          final s = sw;
          if (s != null && s.elapsed >= options.downloadDuration) {
            finish(tput());
            sub.cancel();
            tls?.destroy();
          }
        },
        onError: (_) => finish(tput()),
        onDone: () => finish(tput()),
        cancelOnError: true,
      );

      final result = await completer.future;
      ttfb.cancel();
      deadline.cancel();
      await sub.cancel();

      final rt = redirectTo;
      if (rt != null && depth < 2) {
        // 仍钉同一候选 IP 跟随重定向（CF→CF 时有效；跳到非 CF 主机则 TLS 失败→null）。
        return _measureDownload(ip, rt, options, depth + 1);
      }
      return result;
    } catch (_) {
      return null;
    } finally {
      try {
        tls?.destroy();
      } catch (_) {}
      try {
        raw?.destroy();
      } catch (_) {}
    }
  }

  /// 取 URL 的 origin-form 请求目标（path+query，**保留百分号编码**，ASCII 安全）。
  /// 用 Uri.toString() 而非 uri.path，避免中文等非 ASCII 被解码进 HTTP 请求行。
  String _originForm(Uri u) {
    final s = u.toString();
    final i = s.indexOf('://');
    if (i < 0) return u.path.isEmpty ? '/' : u.path;
    final rest = s.substring(i + 3);
    final slash = rest.indexOf('/');
    if (slash < 0) return '/';
    var target = rest.substring(slash);
    final hash = target.indexOf('#'); // 去掉 fragment
    if (hash >= 0) target = target.substring(0, hash);
    return target.isEmpty ? '/' : target;
  }

  /// 从响应头里解析 Location（相对/绝对都支持），解析成对 [base] 的绝对 URL。
  Uri? _parseLocation(List<int> header, int headerEnd, Uri base) {
    final text = String.fromCharCodes(header.take(headerEnd));
    for (final line in text.split('\r\n')) {
      final c = line.indexOf(':');
      if (c > 0 && line.substring(0, c).trim().toLowerCase() == 'location') {
        final loc = line.substring(c + 1).trim();
        if (loc.isEmpty) return null;
        try {
          return base.resolve(loc);
        } catch (_) {
          return null;
        }
      }
    }
    return null;
  }

  int _statusCode(List<int> header, int headerEnd) {
    final line = String.fromCharCodes(header.take(headerEnd)).split('\r\n').first;
    final m = RegExp(r'HTTP/\d\.\d\s+(\d{3})').firstMatch(line);
    return m != null ? int.parse(m.group(1)!) : 0;
  }

  bool _isReachableStatus(List<int> header, int headerEnd) {
    final code = _statusCode(header, headerEnd);
    return code >= 200 && code < 400; // 2xx/3xx = 边缘确实在为该域名服务
  }

  int _indexOfHeaderEnd(List<int> data) {
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
}
