import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import '../models/music_models.dart';
import '../services/music_service.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';

/// 音乐视听（MoonTVPlus 音乐 v2）
///
/// 布局：顶部搜索框 + 音源切换 → 结果列表 / 最近播放 → 底部迷你播放条。
///
/// 播放链路：点歌 → `POST /api/music/v2/play` 换稳定流地址 + 歌词 →
/// media_kit 直接打开（`/api/music/v2/stream` 是无鉴权的服务端代理，
/// 不需要带 cookie）→ 顺手 `POST /api/music/v2/history` 记一次播放。
///
/// 歌词用 LRC 时间轴对播放进度做逐行高亮，有翻译时在原文下追加小字。
/// 播放器由本页持有：离开页面即释放，符合项目里「每个使用处自己
/// new Player、自己 dispose」的既有做法（video_player_widget 同款）。
class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  /// 项目统一强调色
  static const Color _accentColor = Color(0xFF27ae60);

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  /// 当前音源（默认酷我，与后端默认一致）
  MusicSourceId _source = MusicSourceId.kw;

  /// 搜索结果（空 = 还没搜过，用 [_history] 兜底展示）
  List<MusicSong> _results = const [];
  bool _isSearching = false;
  bool _hasSearched = false;

  /// 最近播放（进页面就拉，搜索前先展示它）
  List<MusicHistoryRecord> _history = const [];
  bool _isLoadingHistory = true;

  // ---------- 播放器 ----------
  Player? _player;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _completedSubscription;

  MusicSong? _currentSong;
  MusicPlayInfo? _currentPlayInfo;
  bool _isPreparing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;

  /// 歌词面板展开时命中的行（-1 = 面板未开 / 无歌词）
  int _activeLyricIndex = -1;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _teardownPlayer();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final records = await MusicService.fetchHistory();
    if (!mounted) return;
    setState(() {
      _history = records;
      _isLoadingHistory = false;
    });
  }

  // ================================================================ 播放器

  Future<void> _playSong(MusicSong song) async {
    if (_isPreparing) return;
    setState(() => _isPreparing = true);
    _searchFocusNode.unfocus();

    final playInfo = await MusicService.fetchPlayInfo(song);
    if (!mounted) return;
    if (playInfo == null) {
      setState(() => _isPreparing = false);
      _showSnack('这首歌暂时拿不到播放地址，换个音源或稍后再试');
      return;
    }
    final streamUrl = await MusicService.resolveStreamUrl(playInfo.streamUrl);
    if (!mounted) return;
    if (streamUrl == null) {
      setState(() => _isPreparing = false);
      _showSnack('服务器地址未配置');
      return;
    }

    final player = _player ??= Player();
    try {
      await player.open(Media(streamUrl));
    } catch (e) {
      debugPrint('[MusicScreen] open failed: $e');
      if (!mounted) return;
      setState(() => _isPreparing = false);
      _showSnack('播放失败，请稍后重试');
      return;
    }
    if (!mounted) return;
    setState(() {
      _currentSong = song;
      _currentPlayInfo = playInfo;
      _position = Duration.zero;
      _duration = Duration.zero;
      _activeLyricIndex = -1;
      _isPreparing = false;
    });
    _attachPlayerListeners();
    // 记一次最近播放；失败静默（服务层内部吞掉）
    unawaited(MusicService.recordPlay(song));
  }

  void _attachPlayerListeners() {
    _positionSubscription ??= _player!.stream.position.listen((position) {
      if (!mounted) return;
      setState(() {
        _position = position;
        _activeLyricIndex = _findLyricIndex(position);
      });
    });
    _durationSubscription ??= _player!.stream.duration.listen((duration) {
      if (!mounted) return;
      setState(() => _duration = duration);
    });
    _playingSubscription ??= _player!.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => _isPlaying = playing);
    });
    _completedSubscription ??= _player!.stream.completed.listen((completed) {
      if (!mounted || !completed) return;
      // 播完自动停在原地（单曲循环语义由用户手动点播放控制）
      setState(() => _isPlaying = false);
    });
  }

  int _findLyricIndex(Duration position) {
    final lines = _currentPlayInfo?.lyricLines;
    if (lines == null || lines.isEmpty) return -1;
    final ms = position.inMilliseconds;
    // 时间轴有序：二分找最后一个 timeMs <= 当前进度的行
    var low = 0, high = lines.length - 1, found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (lines[mid].timeMs <= ms) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  Future<void> _togglePlayPause() async {
    final player = _player;
    if (player == null || _currentSong == null) return;
    await player.playOrPause();
  }

  void _teardownPlayer() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    unawaited(_completedSubscription?.cancel());
    _positionSubscription = null;
    _durationSubscription = null;
    _playingSubscription = null;
    _completedSubscription = null;
    unawaited(_player?.dispose());
    _player = null;
  }

  // ================================================================ 搜索

  Future<void> _doSearch() async {
    final keyword = _searchController.text.trim();
    _searchFocusNode.unfocus();
    if (keyword.isEmpty) return;
    setState(() => _isSearching = true);
    final results =
        await MusicService.search(keyword, sourceId: _source.id);
    if (!mounted) return;
    setState(() {
      _results = results;
      _hasSearched = true;
      _isSearching = false;
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ================================================================ 界面

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        final isDark = themeService.isDarkMode;
        return Theme(
          data: isDark ? themeService.darkTheme : themeService.lightTheme,
          child: Scaffold(
            backgroundColor:
                isDark ? const Color(0xFF141414) : const Color(0xFFF4F5F7),
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(isDark),
                  _buildSearchBar(isDark),
                  _buildSourceChips(isDark),
                  Expanded(child: _buildBody(isDark)),
                  if (_currentSong != null) _buildMiniPlayer(isDark),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(bool isDark) {
    final isTablet = DeviceUtils.isTablet(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(isTablet ? 16 : 8, 8, 16, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(LucideIcons.arrowLeft, size: 20),
            color: isDark ? Colors.white : const Color(0xFF2c3e50),
            tooltip: '返回',
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '音乐视听',
                  style: FontUtils.poppins(
                    fontSize: isTablet ? 24 : 20,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF2c3e50),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '搜索并播放在线音乐',
                  style: FontUtils.poppins(
                    fontSize: isTablet ? 13 : 12,
                    color: isDark
                        ? const Color(0xFFb0b0b0)
                        : const Color(0xFF7f8c8d),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _doSearch(),
              style: FontUtils.poppins(
                fontSize: 14,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
              decoration: InputDecoration(
                hintText: '搜歌曲、歌手…',
                hintStyle: FontUtils.poppins(
                  fontSize: 14,
                  color: isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
                ),
                prefixIcon: Icon(
                  LucideIcons.search,
                  size: 18,
                  color: isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
                ),
                filled: true,
                fillColor: isDark ? const Color(0xFF1e1e1e) : Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildSearchButton(isDark),
        ],
      ),
    );
  }

  Widget _buildSearchButton(bool isDark) {
    return GestureDetector(
      onTap: _isSearching ? null : _doSearch,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: _accentColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: _isSearching
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            : Text(
                '搜索',
                style: FontUtils.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }

  /// 音源切换（wy / tx / kw / kg / mg）
  Widget _buildSourceChips(bool isDark) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final source in MusicSourceId.values) ...[
            GestureDetector(
              onTap: () => setState(() => _source = source),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _source == source
                      ? _accentColor
                      : (isDark
                          ? const Color(0xFF1e1e1e)
                          : Colors.white),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  source.displayName,
                  style: FontUtils.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _source == source
                        ? Colors.white
                        : (isDark
                            ? const Color(0xFFb0b0b0)
                            : const Color(0xFF7f8c8d)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_hasSearched) {
      if (_results.isEmpty) {
        return _buildMessageState(
          isDark: isDark,
          icon: LucideIcons.music,
          title: '没有找到相关歌曲',
          description: '换个关键词，或切换上方音源再试。',
          showRetry: false,
        );
      }
      return _buildSongList(isDark, songs: _results.map((s) => s).toList());
    }
    // 还没搜索：展示最近播放
    if (_isLoadingHistory) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_history.isEmpty) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.history,
        title: '最近播放为空',
        description: '搜一首歌开始听吧。',
        showRetry: false,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            '最近播放',
            style: FontUtils.poppins(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? const Color(0xFFb0b0b0) : const Color(0xFF7f8c8d),
            ),
          ),
        ),
        Expanded(
          child: _buildSongList(
            isDark,
            songs: _history.map((record) => record.song).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildSongList(bool isDark, {required List<MusicSong> songs}) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      itemCount: songs.length,
      itemBuilder: (context, index) => _buildSongTile(isDark, songs[index]),
    );
  }

  Widget _buildSongTile(bool isDark, MusicSong song) {
    final isCurrent = _currentSong?.songId == song.songId &&
        _currentSong?.source == song.source;
    final titleColor = isCurrent
        ? _accentColor
        : (isDark ? Colors.white : const Color(0xFF2c3e50));

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: _buildCover(isDark, song),
      title: Text(
        song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: FontUtils.poppins(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: titleColor,
        ),
      ),
      subtitle: Text(
        song.artist.isEmpty ? song.album : '${song.artist} · ${song.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: FontUtils.poppins(
          fontSize: 12,
          color: isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
        ),
      ),
      trailing: _isPreparing && isCurrent
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (song.durationText.isEmpty
              ? null
              : Text(
                  song.durationText,
                  style: FontUtils.poppins(
                    fontSize: 12,
                    color:
                        isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
                  ),
                )),
      onTap: () => _playSong(song),
    );
  }

  Widget _buildCover(bool isDark, MusicSong song) {
    if (song.cover.isEmpty) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          LucideIcons.music,
          size: 20,
          color: isDark ? const Color(0xFF666666) : const Color(0xFFbdc3c7),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: song.cover,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => Container(
          width: 44,
          height: 44,
          color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
          child: Icon(
            LucideIcons.music,
            size: 20,
            color: isDark ? const Color(0xFF666666) : const Color(0xFFbdc3c7),
          ),
        ),
      ),
    );
  }

  // ================================================================ 迷你播放条

  Widget _buildMiniPlayer(bool isDark) {
    final totalMs = _duration.inMilliseconds;
    final positionMs = _position.inMilliseconds.clamp(0, totalMs <= 0 ? 1 : totalMs);
    final progress = totalMs <= 0 ? 0.0 : positionMs / totalMs;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark
                ? const Color(0xFF333333).withValues(alpha: 0.4)
                : const Color(0xFFe0e0e0),
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _showLyricSheet(isDark),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _currentSong?.name ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FontUtils.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : const Color(0xFF2c3e50),
                        ),
                      ),
                      Text(
                        _currentSong?.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FontUtils.poppins(
                          fontSize: 12,
                          color: isDark
                              ? const Color(0xFF808080)
                              : const Color(0xFF95a5a6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed:
                    _isPreparing ? null : () => _togglePlayPause(),
                icon: Icon(
                  _isPlaying ? LucideIcons.pause : LucideIcons.play,
                  size: 26,
                ),
                color: _accentColor,
              ),
              IconButton(
                onPressed: () => _showLyricSheet(isDark),
                icon: const Icon(LucideIcons.quote, size: 20),
                color: isDark
                    ? const Color(0xFF808080)
                    : const Color(0xFF95a5a6),
                tooltip: '歌词',
              ),
            ],
          ),
          SizedBox(
            height: 24,
            child: Row(
              children: [
                Text(
                  _formatDuration(_position),
                  style: FontUtils.poppins(
                    fontSize: 11,
                    color: isDark
                        ? const Color(0xFF808080)
                        : const Color(0xFF95a5a6),
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                      activeTrackColor: _accentColor,
                      inactiveTrackColor: isDark
                          ? const Color(0xFF333333)
                          : const Color(0xFFe0e0e0),
                    ),
                    child: Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChangeEnd: (value) {
                        if (totalMs <= 0) return;
                        unawaited(_player?.seek(
                          Duration(milliseconds: (value * totalMs).round()),
                        ));
                      },
                      onChanged: (_) {},
                    ),
                  ),
                ),
                Text(
                  _formatDuration(_duration),
                  style: FontUtils.poppins(
                    fontSize: 11,
                    color: isDark
                        ? const Color(0xFF808080)
                        : const Color(0xFF95a5a6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// 歌词面板（ModalBottomSheet）：逐行高亮 + 翻译
  void _showLyricSheet(bool isDark) {
    final lines = _currentPlayInfo?.lyricLines ?? const <MusicLyricLine>[];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF1e1e1e) : Colors.white,
      builder: (sheetContext) {
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.7;
        return SizedBox(
          height: maxHeight,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _currentSong?.name ?? '',
                            style: FontUtils.poppins(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color:
                                  isDark ? Colors.white : const Color(0xFF2c3e50),
                            ),
                          ),
                          Text(
                            _currentSong?.artist ?? '',
                            style: FontUtils.poppins(
                              fontSize: 12,
                              color: isDark
                                  ? const Color(0xFF808080)
                                  : const Color(0xFF95a5a6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(LucideIcons.x, size: 20),
                      color: isDark
                          ? const Color(0xFF808080)
                          : const Color(0xFF95a5a6),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: lines.isEmpty
                    ? Center(
                        child: Text(
                          '暂无歌词',
                          style: FontUtils.poppins(
                            fontSize: 14,
                            color: isDark
                                ? const Color(0xFF808080)
                                : const Color(0xFF95a5a6),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        itemCount: lines.length,
                        itemBuilder: (context, index) {
                          final isActive = index == _activeLyricIndex;
                          final translation =
                              _currentPlayInfo?.translations[lines[index].timeMs];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  lines[index].text,
                                  style: FontUtils.poppins(
                                    fontSize: isActive ? 17 : 14,
                                    fontWeight:
                                        isActive ? FontWeight.w700 : FontWeight.w400,
                                    color: isActive
                                        ? _accentColor
                                        : (isDark
                                            ? const Color(0xFFb0b0b0)
                                            : const Color(0xFF7f8c8d)),
                                  ),
                                ),
                                if (translation != null &&
                                    translation.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      translation,
                                      style: FontUtils.poppins(
                                        fontSize: 12,
                                        color: isDark
                                            ? const Color(0xFF808080)
                                            : const Color(0xFF95a5a6),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ================================================================ 空态

  Widget _buildMessageState({
    required bool isDark,
    required IconData icon,
    required String title,
    required String description,
    required bool showRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 44,
              color: isDark ? const Color(0xFF666666) : const Color(0xFFbdc3c7),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: FontUtils.poppins(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: FontUtils.poppins(
                fontSize: 13,
                color: isDark
                    ? const Color(0xFF808080)
                    : const Color(0xFF95a5a6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
