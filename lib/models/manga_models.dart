/// 漫画展馆（MoonTVPlus 漫画，Suwayomi 后端）相关数据模型
///
/// 对应 MoonTVPlus 后端 `/api/manga/*` 的响应结构：
/// - `GET /api/manga/sources`  → [MangaSource]
/// - `GET /api/manga/search?q=&sourceId=&page=` → [MangaItem]
/// - `GET /api/manga/detail?mangaId=&sourceId=` → [MangaDetail]
/// - `GET /api/manga/pages?chapterId=` → `{pages:[String]}`（相对代理路径）
///
/// 页面图片统一走 `/api/manga/image?path=`（需要登录 cookie），
/// 拼地址与带头逻辑在 `MangaService`。
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

Map<String, dynamic>? _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

/// 漫画源（Suwayomi 的 extension source）
class MangaSource {
  final String id;
  final String name;

  /// 源语言（如 `zh`），仅展示用
  final String lang;

  const MangaSource({
    required this.id,
    required this.name,
    this.lang = '',
  });

  factory MangaSource.fromJson(Map<String, dynamic> json) {
    return MangaSource(
      id: _asString(json['id']),
      name: _asString(json['displayName']).isNotEmpty
          ? _asString(json['displayName'])
          : _asString(json['name']),
      lang: _asString(json['lang']),
    );
  }

  String get displayName => name.isNotEmpty ? name : id;

  /// `GET /api/manga/sources` → `{sources:[...]}`
  static List<MangaSource> listFromResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return const [];
    final rawList = map['sources'];
    if (rawList is! List) return const [];
    return rawList
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(MangaSource.fromJson)
        .where((source) => source.id.isNotEmpty)
        .toList(growable: false);
  }
}

/// 搜索结果 / 推荐里的一部漫画（后端 `MangaSearchItem`）
class MangaItem {
  final String id;
  final String sourceId;
  final String sourceName;
  final String title;
  final String cover;
  final String description;
  final String author;
  final String status;

  const MangaItem({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.title,
    required this.cover,
    required this.description,
    required this.author,
    required this.status,
  });

  factory MangaItem.fromJson(Map<String, dynamic> json) {
    return MangaItem(
      id: _asString(json['id']),
      sourceId: _asString(json['sourceId']),
      sourceName: _asString(json['sourceName']),
      title: _asString(json['title']),
      cover: _asString(json['cover']),
      description: _asString(json['description']),
      author: _asString(json['author']),
      status: _asString(json['status']),
    );
  }

  bool get isValid => id.isNotEmpty && sourceId.isNotEmpty && title.isNotEmpty;

  /// `GET /api/manga/search` → `{results:[...], failedSources:[...]}`
  static List<MangaItem> listFromSearchResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return const [];
    final rawList = map['results'];
    if (rawList is! List) return const [];
    return rawList
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(MangaItem.fromJson)
        .where((item) => item.isValid)
        .toList(growable: false);
  }

  /// 推荐响应 `{mangas:[...], hasNextPage}` 复用同一结构
  static List<MangaItem> listFromRecommendResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return const [];
    final rawList = map['mangas'];
    if (rawList is! List) return const [];
    return rawList
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(MangaItem.fromJson)
        .where((item) => item.isValid)
        .toList(growable: false);
  }
}

/// 一个章节（后端 `MangaChapter`）
class MangaChapter {
  final String id;
  final String mangaId;
  final String name;

  const MangaChapter({
    required this.id,
    required this.mangaId,
    required this.name,
  });

  factory MangaChapter.fromJson(Map<String, dynamic> json) {
    return MangaChapter(
      id: _asString(json['id']),
      mangaId: _asString(json['mangaId']),
      name: _asString(json['name']),
    );
  }

  bool get isValid => id.isNotEmpty && name.isNotEmpty;
}

/// 漫画详情（后端 `MangaDetail` = 搜索项 + 章节列表）
class MangaDetail extends MangaItem {
  final List<MangaChapter> chapters;

  const MangaDetail({
    required super.id,
    required super.sourceId,
    required super.sourceName,
    required super.title,
    required super.cover,
    required super.description,
    required super.author,
    required super.status,
    required this.chapters,
  });

  factory MangaDetail.fromJson(Map<String, dynamic> json) {
    final rawChapters = json['chapters'];
    final chapters = rawChapters is List
        ? rawChapters
            .map(_asMap)
            .whereType<Map<String, dynamic>>()
            .map(MangaChapter.fromJson)
            .where((chapter) => chapter.isValid)
            .toList(growable: false)
        : const <MangaChapter>[];
    return MangaDetail(
      id: _asString(json['id']),
      sourceId: _asString(json['sourceId']),
      sourceName: _asString(json['sourceName']),
      title: _asString(json['title']),
      cover: _asString(json['cover']),
      description: _asString(json['description']),
      author: _asString(json['author']),
      status: _asString(json['status']),
      chapters: chapters,
    );
  }

  factory MangaDetail.fromItem(
    MangaItem item,
    List<MangaChapter> chapters,
  ) {
    return MangaDetail(
      id: item.id,
      sourceId: item.sourceId,
      sourceName: item.sourceName,
      title: item.title,
      cover: item.cover,
      description: item.description,
      author: item.author,
      status: item.status,
      chapters: chapters,
    );
  }
}

/// `GET /api/manga/pages?chapterId=` 的结果：一串图片代理路径
class MangaPages {
  final List<String> paths;

  const MangaPages(this.paths);

  /// `{pages:[...]}` → 相对路径列表（每项形如 `/api/manga/image?path=...`）
  static MangaPages fromResponse(dynamic responseData) {
    final map = _asMap(responseData);
    if (map == null) return const MangaPages([]);
    final rawList = map['pages'];
    if (rawList is! List) return const MangaPages([]);
    final paths = rawList
        .map(_asString)
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    return MangaPages(paths);
  }
}
