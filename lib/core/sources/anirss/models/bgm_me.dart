/// 当前 BGM 账号信息（`/api/meBgm`）。未授权时各字段为空，UI 据此判断是否已登录 BGM。
class BgmMeModel {
  final int? id;
  final String? username;
  final String? nickname;
  final String? sign;
  final String? url;
  final String? avatar;
  final String? userGroup;
  final String? email;

  const BgmMeModel({
    this.id,
    this.username,
    this.nickname,
    this.sign,
    this.url,
    this.avatar,
    this.userGroup,
    this.email,
  });

  static BgmMeModel fromJson(Object? json) {
    if (json is! Map) return const BgmMeModel();
    final m = json.cast<String, dynamic>();
    final av = m['avatar'];
    String? avatar;
    if (av is Map) {
      avatar =
          (av['large'] ?? av['medium'] ?? av['small'])?.toString();
    } else if (av is String) {
      avatar = av;
    }
    return BgmMeModel(
      id: (m['id'] as num?)?.toInt(),
      username: m['username']?.toString(),
      nickname: m['nickname']?.toString(),
      sign: m['sign']?.toString(),
      url: m['url']?.toString(),
      avatar: (avatar != null && avatar.startsWith('http')) ? avatar : null,
      userGroup: m['userGroup']?.toString(),
      email: m['email']?.toString(),
    );
  }

  /// 是否已绑定 BGM（有昵称/用户名即视为已登录）。
  bool get isLoggedIn =>
      (nickname != null && nickname!.isNotEmpty) ||
      (username != null && username!.isNotEmpty);

  String get displayName {
    if (nickname != null && nickname!.isNotEmpty) return nickname!;
    if (username != null && username!.isNotEmpty) return username!;
    return '未登录';
  }
}
