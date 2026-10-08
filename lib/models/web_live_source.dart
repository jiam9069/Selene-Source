/// MoonTVPlus 网络直播源（WebLive）
///
/// 对应 `GET /api/web-live/sources`，返回数组：
/// `[{key, name, platform, roomId, from, disabled}]`
/// 其中 `platform` 为 `huya` / `bilibili` / `douyin`，播放地址由
/// `GET /api/web-live/stream?platform=&roomId=` 实时解析得到。
class WebLiveSource {
  final String key;
  final String name;
  final String platform;
  final String roomId;
  final String from;
  final bool disabled;

  WebLiveSource({
    required this.key,
    required this.name,
    required this.platform,
    required this.roomId,
    required this.from,
    required this.disabled,
  });

  factory WebLiveSource.fromJson(Map<String, dynamic> json) {
    return WebLiveSource(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      roomId: json['roomId']?.toString() ?? '',
      from: json['from'] as String? ?? '',
      disabled: json['disabled'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'name': name,
      'platform': platform,
      'roomId': roomId,
      'from': from,
      'disabled': disabled,
    };
  }

  /// 合并进本地直播源列表时使用的 key
  ///
  /// 形如 `weblive|huya|660000`，用于和普通 M3U 直播源区分。
  String get liveSourceKey => buildLiveSourceKey(platform, roomId);

  static const String keyPrefix = 'weblive|';

  static String buildLiveSourceKey(String platform, String roomId) =>
      '$keyPrefix$platform|$roomId';

  /// 是否为网络直播源 key
  static bool isWebLiveKey(String key) => key.startsWith(keyPrefix);

  /// 解析出平台，非网络直播源返回 null
  static String? platformFromKey(String key) {
    if (!isWebLiveKey(key)) return null;
    final parts = key.substring(keyPrefix.length).split('|');
    return parts.isNotEmpty && parts[0].isNotEmpty ? parts[0] : null;
  }

  /// 解析出房间号，非网络直播源返回 null
  static String? roomIdFromKey(String key) {
    if (!isWebLiveKey(key)) return null;
    final parts = key.substring(keyPrefix.length).split('|');
    return parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
  }

  /// 平台显示名
  String get platformLabel {
    switch (platform) {
      case 'huya':
        return '虎牙';
      case 'bilibili':
        return 'B站';
      case 'douyin':
        return '抖音';
      default:
        return platform;
    }
  }
}

/// 网络直播流信息
///
/// 对应 `GET /api/web-live/stream`：
/// `{url, originalUrl, name, title}`
/// `url` 是站内相对地址（如 `/api/web-live/proxy/proxy.m3u8?url=...`），
/// 播放前需补全为绝对地址；该代理地址需要携带登录 Cookie。
class WebLiveStream {
  final String url;
  final String originalUrl;
  final String name;
  final String title;

  WebLiveStream({
    required this.url,
    required this.originalUrl,
    required this.name,
    required this.title,
  });

  factory WebLiveStream.fromJson(Map<String, dynamic> json) {
    return WebLiveStream(
      url: json['url'] as String? ?? '',
      originalUrl: json['originalUrl'] as String? ?? '',
      name: json['name'] as String? ?? '',
      title: json['title'] as String? ?? '',
    );
  }
}
