/// 音乐视听（MoonTVPlus 音乐 v2）相关数据模型
///
/// 对应 MoonTVPlus 后端 `/api/music/v2/*` 的响应结构（LxMusic 数据源）：
/// - `GET  /api/music/v2/search?q=&source=&type=&page=&limit=` → [MusicSong]
/// - `POST /api/music/v2/play`   → [MusicPlayInfo]（含稳定流地址与歌词）
/// - `GET  /api/music/v2/history` → [MusicHistoryRecord]
/// - `GET  /api/music/v2/discovery/hot-search?source=` → 热搜词（仅探测用）
///
/// `fromJson` 一律做防御性解析：字段缺失、类型不符时返回安全默认值，
/// 绝不抛异常（与 `emby_models.dart` 同一套约定）。
library;

/// 支持的音源标识（后端 `isMusicSource` 的白名单）
enum MusicSourceId {
  wy('wy', '网易云'),
  tx('tx', 'QQ音乐'),
  kw('kw', '酷我'),
  kg('kg', '酷狗'),
  mg('mg', '咪咕');

  const MusicSourceId(this.id, this.displayName);

  /// 后端参数里的音源标识
  final String id;

  /// 展示名
  final String displayName;

  /// 后端不认识的标识回退到酷我（与后端默认一致）
  static MusicSourceId parse(String? raw) {
    return MusicSourceId.values.firstWhere(
      (item) => item.id == raw,
      orElse: () => MusicSourceId.kw,
    );
  }
}

/// 把任意 JSON 值安全地转换为 String（null / 复杂类型 → `''`）
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

/// 把任意 JSON 值安全地转换为 int
int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

/// 把任意 JSON 对象安全地转换为 `Map<String, dynamic>`
Map<String, dynamic>? _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

Map<String, dynamic>? _unwrapData(dynamic value) {
  final map = _asMap(value);
  if (map == null) return null;
  final data = map['data'];
  return _asMap(data);
}

/// 一首歌（后端 `MusicV2Song`，由 LxMusic 各音源归一化而来）
class MusicSong {
  /// 歌曲 ID（注意不是纯数字，可能是 `kw_223224586` 这类带前缀的形式）
  final String songId;

  /// 音源标识（wy / tx / kw / kg / mg）
  final String source;

  /// 音源内部歌曲 mid（拼流地址时后端要用）
  final String songmid;

  final String name;
  final String artist;
  final String album;
  final String cover;

  /// 展示用时长，如 `04:35`
  final String durationText;

  /// 秒数（后端经常不给，展示时以 durationText 为准）
  final int durationSec;

  final String hash;
  final String copyrightId;
  final String albumId;

  const MusicSong({
    required this.songId,
    required this.source,
    required this.name,
    required this.artist,
    this.songmid = '',
    this.album = '',
    this.cover = '',
    this.durationText = '',
    this.durationSec = 0,
    this.hash = '',
    this.copyrightId = '',
    this.albumId = '',
  });

  factory MusicSong.fromJson(Map<String, dynamic> json) {
    return MusicSong(
      songId: _asString(json['songId']),
      source: _asString(json['source']),
      songmid: _asString(json['songmid']),
      name: _asString(json['name']),
      artist: _asString(json['artist']),
      album: _asString(json['album']),
      cover: _asString(json['cover']),
      durationText: _asString(json['durationText']),
      durationSec: _asInt(json['durationSec']),
      hash: _asString(json['hash']),
      copyrightId: _asString(json['copyrightId']),
      albumId: _asString(json['albumId']),
    );
  }

  /// 回传给 `/api/music/v2/play`、`/api/music/v2/history` 的负载体
  Map<String, dynamic> toRequestJson() => {
        'songId': songId,
        'source': source,
        'songmid': songmid,
        'name': name,
        'artist': artist,
        'album': album,
        'cover': cover,
        'durationText': durationText,
        'durationSec': durationSec,
        'hash': hash,
        'copyrightId': copyrightId,
        'albumId': albumId,
      };

  /// 显示用：`歌名 - 歌手`
  String get displayTitle => artist.isEmpty ? name : '$name - $artist';

  /// 搜索结果列表解析：`{success, data:{list:[...]}}`
  static List<MusicSong> listFromSearchResponse(dynamic responseData) {
    final data = _unwrapData(responseData) ?? const {};
    final rawList = data['list'];
    if (rawList is! List) return const [];
    return rawList
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(MusicSong.fromJson)
        .where((song) => song.songId.isNotEmpty && song.name.isNotEmpty)
        .toList(growable: false);
  }
}

/// 一行同步歌词（LRC `[mm:ss.xx]` 时间轴解析结果）
class MusicLyricLine {
  /// 歌词对应的时间点（毫秒）
  final int timeMs;
  final String text;

  const MusicLyricLine(this.timeMs, this.text);
}

/// `/api/music/v2/play` 的结果：播放要用的全部信息
class MusicPlayInfo {
  /// 经过服务端的稳定流地址（相对路径，如 `/api/music/v2/stream?...`，
  /// 播放前拼上服务器地址；该接口无鉴权，可直接交给播放器）
  final String streamUrl;

  /// 直链（后端可选给出；只在 stream 失败时考虑）
  final String directUrl;

  /// 实际命中的音质，如 `320k`
  final String quality;

  /// 歌词行（原声）
  final List<MusicLyricLine> lyricLines;

  /// 翻译歌词（与 [lyricLines] 的时间轴对齐，无翻译时为空 Map）
  final Map<int, String> translations;

  const MusicPlayInfo({
    required this.streamUrl,
    required this.directUrl,
    required this.quality,
    required this.lyricLines,
    required this.translations,
  });

  /// LRC 文本 → 时间轴行列表
  ///
  /// 一行可能带多个时间标（`[00:12.00][01:30.00]同一句`）。
  /// 解析失败或纯文本歌词时回退为单行、0ms。
  static List<MusicLyricLine> parseLrc(String lrc) {
    if (lrc.isEmpty) return const [];
    final timeTag = RegExp(r'^((?:\[\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?\])+)(.*)$');
    final lines = <MusicLyricLine>[];
    for (final rawLine in lrc.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = timeTag.firstMatch(line);
      if (match == null) continue;
      final text = match.group(2)?.trim() ?? '';
      for (final tagMatch
          in RegExp(r'\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]')
              .allMatches(match.group(1) ?? '')) {
        final minutes = int.tryParse(tagMatch.group(1) ?? '') ?? 0;
        final seconds = int.tryParse(tagMatch.group(2) ?? '') ?? 0;
        final fractionText = tagMatch.group(3) ?? '0';
        // `.x` / `.xx` / `.xxx` 分别是 10ms / 100ms / 1000ms 单位
        final fraction = switch (fractionText.length) {
          1 => int.parse(fractionText) * 100,
          2 => int.parse(fractionText) * 10,
          _ => fractionText.length == 3 ? int.parse(fractionText) : 0,
        };
        lines.add(MusicLyricLine(
          minutes * 60 * 1000 + seconds * 1000 + fraction,
          text,
        ));
      }
    }
    lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return lines;
  }

  /// 解析 `POST /api/music/v2/play` 的完整响应
  ///
  /// 后端拿不到播放地址时返回 `success:false` + 502，此时由服务层返回 null。
  static MusicPlayInfo? fromPlayResponse(dynamic responseData) {
    final data = _unwrapData(responseData);
    if (data == null) return null;
    final play = _asMap(data['play']);
    if (play == null) return null;
    final lyric = _asMap(data['lyric']) ?? const {};
    final lrcText = _asString(lyric['lyric']);
    final tlyricText = _asString(lyric['tlyric']);
    final translations = <int, String>{};
    for (final line in parseLrc(tlyricText)) {
      if (line.text.isNotEmpty) translations[line.timeMs] = line.text;
    }
    return MusicPlayInfo(
      streamUrl: _asString(play['url']),
      directUrl: _asString(play['directUrl']),
      quality: _asString(play['quality']),
      lyricLines: parseLrc(lrcText),
      translations: translations,
    );
  }
}

/// 最近播放记录（后端 `MusicV2HistoryRecord`）
class MusicHistoryRecord {
  final MusicSong song;

  /// 上次播到的位置（秒）
  final int playProgressSec;
  final int lastPlayedAt;
  final int playCount;

  const MusicHistoryRecord({
    required this.song,
    required this.playProgressSec,
    required this.lastPlayedAt,
    required this.playCount,
  });

  factory MusicHistoryRecord.fromJson(Map<String, dynamic> json) {
    return MusicHistoryRecord(
      song: MusicSong.fromJson(_asMap(json['song']) ?? const {}),
      playProgressSec: _asInt(json['playProgressSec']),
      lastPlayedAt: _asInt(json['lastPlayedAt']),
      playCount: _asInt(json['playCount']),
    );
  }

  /// `GET /api/music/v2/history` → `{success, data:{records:[...]}}`
  static List<MusicHistoryRecord> listFromResponse(dynamic responseData) {
    final data = _unwrapData(responseData) ?? const {};
    final rawList = data['records'];
    if (rawList is! List) return const [];
    return rawList
        .map(_asMap)
        .whereType<Map<String, dynamic>>()
        .map(MusicHistoryRecord.fromJson)
        .where((record) => record.song.songId.isNotEmpty)
        .toList(growable: false);
  }
}
