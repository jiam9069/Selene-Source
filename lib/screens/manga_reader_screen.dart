import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../models/manga_models.dart';
import '../services/manga_service.dart';
import '../services/theme_service.dart';
import '../utils/font_utils.dart';

/// 漫画阅读器：一次一章、竖向连续滚动
///
/// 页面图片全部走 `/api/manga/image?path=` 代理且要带登录 cookie，
/// 所以 [CachedNetworkImage] 统一挂 [MangaService.imageHeaders]。
/// 大图按屏幕宽度原比例渲染（Suwayomi 返回的原始尺寸，不强制裁切）。
///
/// 章节切换用底部按钮（上一章 / 下一章），列表顺序沿用详情页传进来的
/// 排列方向；顶部横幅显示当前章节名与页码进度。
class MangaReaderScreen extends StatefulWidget {
  final String title;
  final List<MangaChapter> chapters;
  final int initialIndex;

  const MangaReaderScreen({
    super.key,
    required this.title,
    required this.chapters,
    required this.initialIndex,
  });

  @override
  State<MangaReaderScreen> createState() => _MangaReaderScreenState();
}

class _MangaReaderScreenState extends State<MangaReaderScreen> {
  final ScrollController _scrollController = ScrollController();

  int _chapterIndex = 0;
  List<String> _pageUrls = const [];
  bool _isLoading = true;
  bool _loadFailed = false;
  Map<String, String>? _imageHeaders;

  @override
  void initState() {
    super.initState();
    _chapterIndex = widget.initialIndex;
    _loadHeaders();
    _loadChapter();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadHeaders() async {
    final headers = await MangaService.imageHeaders();
    if (!mounted) return;
    setState(() => _imageHeaders = headers);
  }

  Future<void> _loadChapter() async {
    final chapter = _currentChapter;
    if (chapter == null) return;
    setState(() {
      _isLoading = true;
      _loadFailed = false;
      _pageUrls = const [];
    });
    final pages = await MangaService.fetchPages(chapter.id);
    final resolved = <String>[];
    for (final path in pages.paths) {
      final url = await MangaService.resolveImageUrl(path);
      if (url != null) resolved.add(url);
    }
    if (!mounted) return;
    setState(() {
      _pageUrls = resolved;
      _isLoading = false;
      _loadFailed = resolved.isEmpty;
    });
    if (_scrollController.hasClients) {
      unawaited(_scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ));
    }
  }

  MangaChapter? get _currentChapter =>
      widget.chapters.isEmpty ? null : widget.chapters[_chapterIndex];

  bool get _hasPrev => _chapterIndex > 0;
  bool get _hasNext => _chapterIndex < widget.chapters.length - 1;

  void _switchChapter(int newIndex) {
    if (newIndex < 0 || newIndex >= widget.chapters.length) return;
    setState(() => _chapterIndex = newIndex);
    _loadChapter();
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
            backgroundColor: isDark ? Colors.black : Colors.white,
            body: SafeArea(
              top: false,
              child: Column(
                children: [
                  _buildTopBar(isDark),
                  Expanded(child: _buildBody(isDark)),
                  _buildBottomBar(isDark),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 顶部横幅：返回 + 章节名（点击返回详情）
  Widget _buildTopBar(bool isDark) {
    final chapter = _currentChapter;
    return Container(
      color: isDark
          ? const Color(0xFF141414).withValues(alpha: 0.92)
          : Colors.white.withValues(alpha: 0.92),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(LucideIcons.arrowLeft, size: 20),
            color: isDark ? Colors.white : const Color(0xFF2c3e50),
            tooltip: '返回',
          ),
          Expanded(
            child: Text(
              '${widget.title} · ${chapter?.name ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: FontUtils.poppins(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              _pageUrls.isEmpty ? '' : '${_pageUrls.length} 页',
              style: FontUtils.poppins(
                fontSize: 12,
                color:
                    isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }
    if (_loadFailed || _pageUrls.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.imageOff,
                size: 44,
                color: isDark ? const Color(0xFF666666) : const Color(0xFFbdc3c7),
              ),
              const SizedBox(height: 16),
              Text(
                '本话没有加载到图片',
                style: FontUtils.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF2c3e50),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '源站可能暂时无法访问，稍后重试。',
                style: FontUtils.poppins(
                  fontSize: 13,
                  color: isDark
                      ? const Color(0xFF808080)
                      : const Color(0xFF95a5a6),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(onPressed: _loadChapter, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      // 图片逐张原比例；用占位高度防止加载中列表塌陷
      itemCount: _pageUrls.length,
      itemBuilder: (context, index) {
        final url = _pageUrls[index];
        return CachedNetworkImage(
          imageUrl: url,
          httpHeaders: _imageHeaders,
          fit: BoxFit.fitWidth,
          placeholder: (_, __) => SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: const Center(child: CircularProgressIndicator()),
          ),
          errorWidget: (_, __, ___) => Container(
            height: 240,
            color: isDark ? const Color(0xFF1e1e1e) : const Color(0xFFecf0f1),
            child: Icon(
              LucideIcons.imageOff,
              size: 32,
              color: isDark ? const Color(0xFF666666) : const Color(0xFFbdc3c7),
            ),
          ),
        );
      },
    );
  }

  /// 底部：上一章 / 下一章
  Widget _buildBottomBar(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF141414).withValues(alpha: 0.92)
            : Colors.white.withValues(alpha: 0.92),
        border: Border(
          top: BorderSide(
            color: isDark
                ? const Color(0xFF333333).withValues(alpha: 0.4)
                : const Color(0xFFe0e0e0),
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: _hasPrev
                  ? () => _switchChapter(_chapterIndex - 1)
                  : null,
              child: const Text('上一章'),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: _hasNext
                  ? () => _switchChapter(_chapterIndex + 1)
                  : null,
              child: const Text('下一章'),
            ),
          ),
        ],
      ),
    );
  }
}
