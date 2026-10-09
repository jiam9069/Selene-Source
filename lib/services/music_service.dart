import 'package:flutter/foundation.dart';

import '../models/music_models.dart';
import 'api_service.dart';
import 'user_data_service.dart';

/// 音乐视听（MoonTVPlus 音乐 v2）服务
///
/// 后端由 LxMusic 数据源驱动，链路：
/// `GET /api/music/v2/discovery/hot-search`（探测可用性）
/// `GET /api/music/v2/search`（搜歌）
/// `POST /api/music/v2/play`（换取稳定流地址 + 歌词）
/// `GET/POST /api/music/v2/history`（最近播放）
///
/// 流地址 `/api/music/v2/stream` 是无鉴权的服务端代理，播放器可直接打开。
/// 所有方法失败时返回空结果 / null 而不抛异常，空结果同时覆盖
/// 「后端未配置」与「请求失败」两种情况，由界面层展示统一的友好空态。
class MusicService {
  static const String _logPrefix = '[MusicService]';

  static void _log(String message) => debugPrint('$_logPrefix $message');

  /// 可用性缓存：用户菜单每次打开都要探测，别真打后端
  static bool? _availabilityCache;

  /// 音乐功能是否可用（`/api/music/v2/discovery/hot-search` 返回成功）
  ///
  /// 后端音乐服务未配置 / 无权限（401）/ 上游 LxMusic 服务失联（5xx）时，
  /// 这里都会得到 false——即「配置过但挂了」也隐藏入口，和网页端
  /// `MUSIC_ENABLED` 只看配置不同：客户端多看一眼真实可用性，
  /// 避免入口点进去永远是报错。
  static Future<bool> isAvailable() async {
    final cached = _availabilityCache;
    if (cached != null) return cached;

    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/music/v2/discovery/hot-search',
      queryParameters: {'source': 'kw'},
      fromJson: (data) => data as Map<String, dynamic>,
    );
    // 后端约定的成功包是 {success:true, data:{...}}；老版本可能直接回数组，
    // 这里宽松处理：HTTP 成功且没显式说失败即算可用
    final available =
        response.success && (response.data?['success'] != false);
    _availabilityCache = available;
    if (!available) _log('音乐不可用: ${response.message}');
    return available;
  }

  /// 清除可用性缓存（退出登录 / 切换服务器后由界面层调用）
  static void resetAvailabilityCache() => _availabilityCache = null;

  /// 搜歌
  ///
  /// [sourceId] 见 [MusicSourceId.id]；[type] 后端支持 song / singer / album，
  /// MVP 只用 song。失败返回空列表。
  static Future<List<MusicSong>> search(
    String query, {
    String sourceId = 'kw',
    String type = 'song',
    int page = 1,
    int limit = 30,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];

    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/music/v2/search',
      queryParameters: {
        'q': keyword,
        'source': sourceId,
        'type': type,
        'page': '$page',
        'limit': '$limit',
      },
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('搜索失败: ${response.message}');
      return const [];
    }
    return MusicSong.listFromSearchResponse(response.data);
  }

  /// 换取播放信息（稳定流地址 + 歌词）
  ///
  /// 后端拿不到播放地址时返回 502（`success:false`），这里返回 null，
  /// 界面层提示「该曲目暂时无法播放」。
  static Future<MusicPlayInfo?> fetchPlayInfo(
    MusicSong song, {
    String quality = '320k',
  }) async {
    final response = await ApiService.post<Map<String, dynamic>>(
      '/api/music/v2/play',
      body: {
        'song': song.toRequestJson(),
        'quality': quality,
        'includeUrl': true,
      },
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('获取播放信息失败: ${response.message}');
      return null;
    }
    final playInfo = MusicPlayInfo.fromPlayResponse(response.data);
    if (playInfo == null || playInfo.streamUrl.isEmpty) {
      _log('播放信息缺少流地址');
      return null;
    }
    return playInfo;
  }

  /// 播放器拉流要带的请求头
  ///
  /// 实测（2026-10-09，zt_jp_plus / v226.1.0）：`/api/music/v2/stream`
  /// **必须带登录 cookie**——middleware 对所有未豁免的 `/api/*` 统一鉴权，
  /// stream 不在豁免名单里（裸访问 401）。media_kit 拉流同样要带头。
  static Future<Map<String, String>?> mediaHeaders() async {
    final cookies = await UserDataService.getCookies();
    if (cookies == null || cookies.isEmpty) return null;
    return {'Cookie': cookies};
  }

  /// 把后端返回的相对流地址拼成完整 URL
  ///
  /// 返回 null 表示服务器地址还没配置（理论上登录后不会发生）。
  static Future<String?> resolveStreamUrl(String path) async {
    if (path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final baseUrl = await UserDataService.getServerUrl();
    if (baseUrl == null || baseUrl.isEmpty) return null;
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$cleanBase${path.startsWith('/') ? path : '/$path'}';
  }

  /// 最近播放记录
  static Future<List<MusicHistoryRecord>> fetchHistory() async {
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/music/v2/history',
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('获取播放历史失败: ${response.message}');
      return const [];
    }
    return MusicHistoryRecord.listFromResponse(response.data);
  }

  /// 记一次播放（写最近播放；失败静默，不打扰用户）
  static Future<void> recordPlay(MusicSong song) async {
    try {
      await ApiService.post<Map<String, dynamic>>(
        '/api/music/v2/history',
        body: {'song': song.toRequestJson()},
      );
    } catch (e) {
      _log('记录播放历史失败: $e');
    }
  }
}
