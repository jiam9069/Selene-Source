import 'package:flutter/foundation.dart';

import '../models/book_models.dart';
import 'api_service.dart';

/// 电子书馆（MoonTVPlus 图书，OPDS + Legado 双引擎）服务
///
/// MVP 只实现 Legado 文本链路：
/// 源列表 → 搜书 → 章节目录 → 章节正文（服务端已清洗为纯文本）。
/// OPDS 源的 epub / pdf 需要额外的渲染依赖，留到后续版本；
/// 入口探测对**任何**书源都放行，页面里只列 Legado 源，
/// 只有 OPDS 源时展示「暂不支持」的说明，不隐藏入口
/// （否则配了书源的用户会以为客户端坏了）。
///
/// 所有方法失败时返回空结果而不抛异常，与 [MangaService] 同一套约定。
class BooksService {
  static const String _logPrefix = '[BooksService]';

  static void _log(String message) => debugPrint('$_logPrefix $message');

  /// 源列表缓存（可用性探测与页面首屏共用一次请求）
  static List<BookSource>? _sourcesCache;

  static void resetSourcesCache() => _sourcesCache = null;

  /// 拉取书源列表
  ///
  /// [onlyLegado] 为 true 时只保留 Legado 源（文本链路可用的那些）。
  static Future<List<BookSource>> fetchSources({bool onlyLegado = false}) async {
    final cached = _sourcesCache;
    if (cached != null) {
      return onlyLegado
          ? cached.where((s) => s.isLegado).toList(growable: false)
          : cached;
    }
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/books/sources',
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('获取书源失败: ${response.message}');
      return const [];
    }
    final sources = BookSource.listFromResponse(response.data);
    _sourcesCache = sources;
    return onlyLegado
        ? sources.where((s) => s.isLegado).toList(growable: false)
        : sources;
  }

  /// 电子书功能是否可用（配置了任何书源即算可用，含纯 OPDS）
  static Future<bool> isAvailable() async =>
      (await fetchSources()).isNotEmpty;

  /// 是否存在可走文本链路的 Legado 源
  static Future<bool> hasLegadoSources() async =>
      (await fetchSources(onlyLegado: true)).isNotEmpty;

  /// 搜书（[sourceId] 为空时后端在全部源里搜，OPDS 结果会混进来，
  /// 界面层负责按源过滤或标注）
  static Future<List<BookListItem>> search(
    String query, {
    String? sourceId,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];

    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/books/search',
      queryParameters: {
        'q': keyword,
        if (sourceId != null && sourceId.isNotEmpty) 'sourceId': sourceId,
      },
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('搜书失败: ${response.message}');
      return const [];
    }
    return BookListItem.listFromSearchResponse(response.data);
  }

  /// 章节目录（Legado 链路）
  ///
  /// 定位方式有讲究：`bookId` 路径要求书源规则里有 id 模板
  /// （`{{$.id}}` / `{id}`），很多 Legado 书源没有，后端会直接抛
  /// 「无法通过 bookId 定位详情」；而搜索结果自带的 [BookListItem.detailHref]
  /// 是直连详情地址，可靠得多。所以**有 detailHref 一律走 href**，
  /// 只有缺 detailHref 的脏数据才退回 bookId。
  static Future<BookChapterList> fetchChapters(
    BookListItem book,
  ) async {
    final useHref = book.detailHref.isNotEmpty;
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/books/read/chapters',
      queryParameters: {
        'sourceId': book.sourceId,
        if (useHref)
          'href': book.detailHref
        else if (book.id.isNotEmpty)
          'bookId': book.id,
      },
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('获取章节目录失败: ${response.message}');
      return const BookChapterList([]);
    }
    return BookChapterList.fromResponse(response.data);
  }

  /// 章节正文（Legado 链路，服务端清洗后的文本）
  static Future<BookChapterContent?> fetchChapterContent(
    String sourceId,
    String href,
  ) async {
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/books/read/chapter',
      queryParameters: {'sourceId': sourceId, 'href': href},
      fromJson: (data) => data as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      _log('获取章节正文失败: ${response.message}');
      return null;
    }
    return BookChapterContent.fromResponse(response.data);
  }
}
