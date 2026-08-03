import 'dart:io';

import 'package:wjplayer/core/services/tmdb_crypto.dart';

/// 把明文 TMDB 密钥用内置口令 AES-256-CBC 加密为 base64 密文。
///
/// 用法：
///   dart run tool/tmdb_encrypt.dart <TMDB_API_KEY>
///   echo <TMDB_API_KEY> | dart run tool/tmdb_encrypt.dart
///
/// 输出即密文（无换行），可直接喂给 `--dart-define=TMDB_API_KEY_ENC=...`。
/// CI 用它把 GitHub Secret 里的明文密钥加密后注入构建产物，明文不进产物。
Future<void> main(List<String> args) async {
  var plain = args.isNotEmpty ? args.first : (stdin.readLineSync() ?? '');
  plain = plain.trim();
  if (plain.isEmpty) {
    stderr.writeln('用法: dart run tool/tmdb_encrypt.dart <TMDB_API_KEY>');
    exitCode = 2;
    return;
  }
  stdout.write(await TmdbCrypto.encrypt(plain));
}
