import 'package:flutter/foundation.dart';

import '../models/manga_models.dart';
import 'api_service.dart';
import 'user_data_service.dart';

/// 漫画展馆（MoonTVPlus 漫画，Suwayomi 后端）服务
///
/// 链路：源列表 → 搜漫画 → 详情（含章节）→ 章节页列表 → 逐页图片。
/// 图片统一走 `/api/manga/image?path=` 代理且**需要登录 cookie**，
/// 所以图片加载必须带 [imageHeaders]。
///
/// 所有方法失败时返回空结果而不抛异常；「空」同时覆盖了
/// 「后端未配置 Suwayomi」与「请求失败」两种情况。
class MangaService {
  static const String _logPrefix = '[MangaService]';

  static void _log(String message) => debugPrint('$_logPrefix $message');

  /// 源列表缓存（可用性探测与页面首屏共用一次请求）
  static List<MangaSource>? _sourcesCache;

  static void resetSourcesCache() => _sourcesCache = null;

  /// 拉取漫画源列表（Suwayomi 的 extension sources）
  static Future<List<MangaSource>> fetchSources() async {
    final cached = _sourcesCache;
    if (cached != null) return cached;

    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/manga/sources',
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('获取漫画源失败: ${response.message}');
      return const [];
    }
    final sources = MangaSource.listFromResponse(response.data);
    _sourcesCache = sources;
    return sources;
  }

  /// 漫画功能是否可用（有可用源即算可用）
  ///
  /// 后端未配置 Suwayomi 时 `/api/manga/sources` 回 500，无权限回 403，
  /// 这里统一变成 false。
  static Future<bool> isAvailable() async => (await fetchSources()).isNotEmpty;

  /// 搜漫画（[sourceId] 为空时后端在全部源里搜）
  static Future<List<MangaItem>> search(
    String query, {
    String? sourceId,
    int page = 1,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];

    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/manga/search',
      queryParameters: {
        'q': keyword,
        if (sourceId != null && sourceId.isNotEmpty) 'sourceId': sourceId,
        'page': '$page',
      },
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('搜索漫画失败: ${response.message}');
      return const [];
    }
    return MangaItem.listFromSearchResponse(response.data);
  }

  /// 漫画详情（含章节列表）
  ///
  /// 后端在 Suwayomi 抓不到详情时会用搜索结果里带来的元数据兜底，
  /// 因此把 [item] 的字段一并回传，保证标题 / 封面一定有。
  static Future<MangaDetail?> fetchDetail(MangaItem item) async {
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/manga/detail',
      queryParameters: {
        'mangaId': item.id,
        'sourceId': item.sourceId,
        if (item.title.isNotEmpty) 'title': item.title,
        if (item.cover.isNotEmpty) 'cover': item.cover,
        if (item.sourceName.isNotEmpty) 'sourceName': item.sourceName,
        if (item.description.isNotEmpty) 'description': item.description,
        if (item.author.isNotEmpty) 'author': item.author,
        if (item.status.isNotEmpty) 'status': item.status,
      },
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('获取漫画详情失败: ${response.message}');
      return null;
    }
    final detail = MangaDetail.fromJson(response.data!);
    if (detail.id.isEmpty || detail.sourceId.isEmpty) return null;
    // 章节抓取失败时详情还有元数据可用，别整体判失败
    return MangaDetail.fromItem(detail, detail.chapters);
  }

  /// 章节的页列表（返回相对代理路径）
  static Future<MangaPages> fetchPages(String chapterId) async {
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/manga/pages',
      queryParameters: {'chapterId': chapterId},
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('获取章节页失败: ${response.message}');
      return const MangaPages([]);
    }
    return MangaPages.fromResponse(response.data);
  }

  /// 把 `/api/manga/image?path=...` 相对路径拼成完整 URL
  ///
  /// 后端只回相对路径；返回 null 表示服务器地址未配置。
  static Future<String?> resolveImageUrl(String path) async {
    if (path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final baseUrl = await UserDataService.getServerUrl();
    if (baseUrl == null || baseUrl.isEmpty) return null;
    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$cleanBase${path.startsWith('/') ? path : '/$path'}';
  }

  /// 图片加载要带的请求头（`/api/manga/image` 校验登录 cookie）
  static Future<Map<String, String>?> imageHeaders() async {
    final cookies = await UserDataService.getCookies();
    if (cookies == null || cookies.isEmpty) return null;
    return {'Cookie': cookies};
  }
}
