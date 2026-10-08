// 直播频道数据模型
class LiveChannel {
  final String id; // 频道ID
  final String tvgId; // TVG ID
  final String name; // 频道名称
  final String logo; // 频道图标
  final String group; // 分组名称
  final String url; // 视频源地址
  bool isFavorite; // 是否收藏

  /// 播放该频道时需要附加的请求头
  ///
  /// MoonTVPlus 的网络直播走站内代理（`/api/web-live/proxy/*`），
  /// 该路径需要登录 Cookie，故在此透传给播放器。
  final Map<String, String> headers;

  LiveChannel({
    required this.id,
    required this.tvgId,
    required this.name,
    required this.logo,
    required this.group,
    required this.url,
    this.isFavorite = false,
    this.headers = const <String, String>{},
  });

  factory LiveChannel.fromJson(Map<String, dynamic> json) {
    return LiveChannel(
      id: json['id'] as String? ?? '',
      tvgId: json['tvgId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      logo: json['logo'] as String? ?? '',
      group: json['group'] as String? ?? '',
      url: json['url'] as String? ?? '',
      isFavorite: json['isFavorite'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'tvgId': tvgId,
      'name': name,
      'logo': logo,
      'group': group,
      'url': url,
      'isFavorite': isFavorite,
    };
  }

  LiveChannel copyWith({
    String? id,
    String? tvgId,
    String? name,
    String? logo,
    String? group,
    String? url,
    bool? isFavorite,
    Map<String, String>? headers,
  }) {
    return LiveChannel(
      id: id ?? this.id,
      tvgId: tvgId ?? this.tvgId,
      name: name ?? this.name,
      logo: logo ?? this.logo,
      group: group ?? this.group,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }
}

// 直播频道分组
class LiveChannelGroup {
  final String name;
  final List<LiveChannel> channels;

  LiveChannelGroup({
    required this.name,
    required this.channels,
  });
}
