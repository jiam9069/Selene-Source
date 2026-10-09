/// 电子书馆（MoonTVPlus 图书，OPDS + Legado 双引擎）相关数据模型
///
/// 对应 MoonTVPlus 后端 `/api/books/*` 的响应结构：
/// - `GET /api/books/sources` → [BookSource]
/// - `GET /api/books/search?q=&sourceId=` → [BookListItem]
/// - `GET /api/books/read/chapters?sourceId=&bookId=` → [BookChapter]
/// - `GET /api/books/read/chapter?sourceId=&href=` → [BookChapterContent]
///
/// MVP 只实现 Legado 文本链路（章节正文由服务端抓取并清洗为纯文本）；
/// OPDS 的 epub / pdf 需要额外的渲染依赖，留到后续版本。
///
/// `fromJson` 一律做防御性解析，字段缺失 / 类型不符时返回安全默认值，
/// 绝不抛异常（与 `emby_models.dart` 同一套约定）。
library;

String _asString(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num) {
    if (value is double && value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }
  if (value is bool) return value.toString();
  return '';
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

Map<String, dynamic>? _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

/// 书源（OPDS 目录源或 Legado 规则源）
class BookSource {
  final String id;
  final String name;

  /// `opds` / `legado`，缺失时由服务层按 id 前缀猜测
  final String type;

  const BookSource({
    required this.id,
    required this.name,
    this.type = '',
  });

  factory BookSource.fromJson(Map<String, dynamic> json) {
    return BookSource(
      id: _asString(json['id']),
      name: _asString(json['name']),
      type: _asString(json['type']),
    );
  }

  String get displayName => name.isNotEmpty ? name : id;

  bool get isLegado => type == 'legado';

  /// `GET /api/books/sources` → `{sources:[...]}`
  ///
  /// 后端把 OPDS 源与 Legado 源合并返回；只有 Legado 源能走文本章节链路，
  /// `onlyLegado` 为 true 时过滤出 Legado 源（OPDS 源留给后续 epub 版本）。
  static List<BookSource> listFromResponse(
    dynamic responseData, {
    bool onlyLegado = false,
  }) {
    final map = _asMap(responseData);
    if (map == null) return const [];
    final rawList = map['sources'];
    if (rawList is! List) return const [];
    final sources = rawList
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(BookSource.fromJson)
        .where((source) => source.id.isNotEmpty);
    if (!onlyLegado) {
      return sources.toList(growable: false);
    }
    return sources.where((source) => source.isLegado).toList(growable: false);
  }
}

/// 搜索结果里的一本书（后端 `BookListItem`）
class BookListItem {
  final String id;
  final String sourceId;
  final String sourceName;
  final String title;
  final String author;
  final String cover;
  final String summary;

  /// 详情页地址（Legado 源的正文规则要靠它定位目录）
  final String detailHref;

  const BookListItem({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.title,
    required this.author,
    required this.cover,
    required this.summary,
    required this.detailHref,
  });

  factory BookListItem.fromJson(Map<String, dynamic> json) {
    return BookListItem(
      id: _asString(json['id']),
      sourceId: _asString(json['sourceId']),
      sourceName: _asString(json['sourceName']),
      title: _asString(json['title']),
      author: _asString(json['author']),
      cover: _asString(json['cover']),
      summary: _asString(json['summary']),
      detailHref: _asString(json['detailHref']),
    );
  }

  bool get isValid => id.isNotEmpty && sourceId.isNotEmpty && title.isNotEmpty;

  /// `GET /api/books/search` → `{results:[...], failedSources:[...]}`
  static List<BookListItem> listFromSearchResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return const [];
    final rawList = map['results'];
    if (rawList is! List) return const [];
    return rawList
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(BookListItem.fromJson)
        .where((item) => item.isValid)
        .toList(growable: false);
  }
}

/// 目录里的一章（后端 `BookChapter`）
class BookChapter {
  final String id;
  final String title;
  final String href;
  final int order;

  const BookChapter({
    required this.id,
    required this.title,
    required this.href,
    required this.order,
  });

  factory BookChapter.fromJson(Map<String, dynamic> json) {
    return BookChapter(
      id: _asString(json['id']),
      title: _asString(json['title']),
      href: _asString(json['href']),
      order: _asInt(json['order']),
    );
  }

  bool get isValid => href.isNotEmpty && title.isNotEmpty;
}

/// 章节目录（`GET /api/books/read/chapters`）
class BookChapterList {
  final List<BookChapter> chapters;

  const BookChapterList(this.chapters);

  static BookChapterList fromResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return const BookChapterList([]);
    final rawList = map['chapters'];
    if (rawList is! List) return const BookChapterList([]);
    final chapters = rawList
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(BookChapter.fromJson)
        .where((chapter) => chapter.isValid)
        .toList(growable: false);
    return BookChapterList(chapters);
  }
}

/// 章节正文（`GET /api/books/read/chapter`，后端 `BookChapterContent`）
///
/// 正文是服务端清洗后的文本，可能残留少量 `<img>` 标签（图片经
/// `/api/books/image` 代理）；MVP 阅读器只渲染纯文本，标签行做剔除。
class BookChapterContent {
  final String id;
  final String title;
  final String href;

  /// 纯文本正文（段落间以 `\n` 分隔）
  final String content;

  final String previousHref;
  final String nextHref;

  const BookChapterContent({
    required this.id,
    required this.title,
    required this.href,
    required this.content,
    required this.previousHref,
    required this.nextHref,
  });

  factory BookChapterContent.fromJson(Map<String, dynamic> json) {
    return BookChapterContent(
      id: _asString(json['id']),
      title: _asString(json['title']),
      href: _asString(json['href']),
      content: _asString(json['content']),
      previousHref: _asString(json['previousHref']),
      nextHref: _asString(json['nextHref']),
    );
  }

  static BookChapterContent? fromResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return null;
    return BookChapterContent.fromJson(map);
  }

  /// 渲染用段落列表：去掉 `<img>` / `<br>` 等残留标签并按空行分段
  List<String> get paragraphs {
    if (content.isEmpty) return const [];
    return content
        .replaceAll(RegExp(r'<img[^>]*>'), '')
        .replaceAll(RegExp(r'</?(?:p|div|span|br)[^>]*>'), '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }
}
