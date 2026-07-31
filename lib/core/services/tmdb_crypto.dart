import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// TMDB API 密钥的 AES-256-CBC 混淆加解密。
///
/// 用途：TMDB 密钥不进源码、不以明文进构建产物。CI 用同一把内置口令把明文密钥
/// 加密成 base64 密文，经 `--dart-define=TMDB_API_KEY_ENC` 注入；运行时用本类解回。
///
/// 安全说明：这是**混淆级**加密——口令编译进客户端，能挡住 `strings` 直接抓取
/// 明文、也让密钥不出现在公开仓库，但**不防**被提取口令后解密（离线客户端密钥的
/// 固有天花板）。与 [CommonConfig] 同思路：抬高滥用门槛，非绝对安全。
class TmdbCrypto {
  TmdbCrypto._();

  /// 内置口令（32 字节 = AES-256）。与 tool/tmdb_encrypt.dart 必须一致。
  static final List<int> _key =
      utf8.encode('WJPlayer-tmdb-ranking-key-v1!!!');

  static final AesCbc _aes =
      AesCbc.with256bits(macAlgorithm: MacAlgorithm.empty);

  /// 解密 base64 密文为明文密钥。空/失败返回空串（上层据此判定“未配置”）。
  static Future<String> decrypt(String b64) async {
    if (b64.trim().isEmpty) return '';
    try {
      final clear = await _aes.decrypt(
        SecretBox(base64Decode(b64.trim()),
            nonce: _key.sublist(0, 16), mac: Mac.empty),
        secretKey: SecretKey(_key),
      );
      return utf8.decode(clear).trim();
    } catch (_) {
      return '';
    }
  }

  /// 加密明文密钥为 base64 密文（供 CI / tool 使用）。IV 取口令前 16 字节。
  static Future<String> encrypt(String plaintext) async {
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(_key),
      nonce: _key.sublist(0, 16),
    );
    return base64Encode(box.cipherText);
  }
}
