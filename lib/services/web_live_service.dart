import '../models/web_live_source.dart';
import 'api_service.dart';
import 'user_data_service.dart';

/// 网络直播服务（MoonTVPlus WebLive）
///
/// 原版 MoonTV 只有 M3U 直播源；MoonTVPlus 额外提供「网络直播」——
/// 按平台 + 房间号实时解析虎牙 / B站 / 抖音的直播流。
/// 相关接口只存在于 MoonTVPlus，原版后端会返回 404，此时静默降级为空列表。
class WebLiveService {
  /// 网络直播源缓存（列表很小，直接常驻内存）
  static List<WebLiveSource>? _sourcesCache;

  /// 已解析的流地址缓存，避免每次播放都重新解析
  static final Map<String, _StreamCacheItem> _streamCache = {};

  static const Duration _streamCacheDuration = Duration(minutes: 2);

  /// 获取网络直播源列表
  ///
  /// 后端不支持（原版 MoonTV）或无条目时返回空列表，不抛异常。
  static Future<List<WebLiveSource>> getSources({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _sourcesCache != null) {
      return _sourcesCache!;
    }

    final response = await ApiService.get<List<WebLiveSource>>(
      '/api/web-live/sources',
      fromJson: (data) {
        final list = data as List<dynamic>;
        return list
            .map((item) =>
                WebLiveSource.fromJson(item as Map<String, dynamic>))
            .where((source) => !source.disabled)
            .where((source) => source.platform.isNotEmpty &&
                source.roomId.isNotEmpty)
            .toList();
      },
    );

    if (!response.success || response.data == null) {
      // 后端不支持该能力时保持空列表，不影响普通直播源
      _sourcesCache = <WebLiveSource>[];
      return _sourcesCache!;
    }

    _sourcesCache = response.data!;
    return _sourcesCache!;
  }

  /// 解析指定房间的直播流
  ///
  /// 返回的 [WebLiveStream.url] 已补全为绝对地址。
  /// 房间未开播、房间号失效或平台不支持时返回 null（由调用方给出提示）。
  static Future<WebLiveStream?> resolveStream(
    String platform,
    String roomId, {
    bool forceRefresh = false,
  }) async {
    final cacheKey = '$platform|$roomId';

    if (!forceRefresh) {
      final cached = _streamCache[cacheKey];
      if (cached != null &&
          DateTime.now().difference(cached.time) < _streamCacheDuration) {
        return cached.stream;
      }
    }

    final response = await ApiService.get<WebLiveStream>(
      '/api/web-live/stream',
      queryParameters: {
        'platform': platform,
        'roomId': roomId,
      },
      fromJson: (data) =>
          WebLiveStream.fromJson(data as Map<String, dynamic>),
    );

    if (!response.success || response.data == null) {
      return null;
    }

    final stream = response.data!;
    if (stream.url.isEmpty) return null;

    // 后端返回的是站内相对地址，播放器需要绝对地址
    final absolute = WebLiveStream(
      url: await ApiService.absolutize(stream.url),
      originalUrl: stream.originalUrl,
      name: stream.name,
      title: stream.title,
    );

    _streamCache[cacheKey] = _StreamCacheItem(absolute, DateTime.now());
    return absolute;
  }

  /// 播放网络直播所需的请求头
  ///
  /// `/api/web-live/proxy/*` 不在后端的免鉴权白名单里，必须带上登录 Cookie，
  /// 否则播放器请求会拿到 401。
  static Future<Map<String, String>> playbackHeaders() async {
    final cookies = await UserDataService.getCookies();
    return <String, String>{
      if (cookies != null && cookies.isNotEmpty) 'Cookie': cookies,
    };
  }

  /// 清理缓存
  static void clearCache() {
    _sourcesCache = null;
    _streamCache.clear();
  }

  static void clearStreamCache(String platform, String roomId) {
    _streamCache.remove('$platform|$roomId');
  }
}

class _StreamCacheItem {
  final WebLiveStream stream;
  final DateTime time;

  _StreamCacheItem(this.stream, this.time);
}
