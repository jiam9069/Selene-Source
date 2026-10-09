import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../models/book_models.dart';
import '../services/books_service.dart';
import '../services/theme_service.dart';
import '../utils/font_utils.dart';

/// 电子书阅读器（Legado 文本链路）
///
/// 一个页面承载三样东西：书目元数据、章节目录（底部弹出）、当前章正文。
/// 进页自动加载章节目录并打开第一章。
///
/// 字号调节是会话级的（进程内共享一个静态值），不做持久化——
/// 持久化需要动 UserDataService，留到后续版本一起做。
class BookReaderScreen extends StatefulWidget {
  final BookListItem book;

  const BookReaderScreen({super.key, required this.book});

  @override
  State<BookReaderScreen> createState() => _BookReaderScreenState();
}

class _BookReaderScreenState extends State<BookReaderScreen> {
  /// 项目统一强调色
  static const Color _accentColor = Color(0xFF27ae60);

  /// 会话级字号（进程内共享）
  static double _sessionFontSize = 17;

  final ScrollController _scrollController = ScrollController();

  List<BookChapter> _chapters = const [];
  bool _isLoadingChapters = true;
  bool _chaptersFailed = false;

  int _chapterIndex = -1;
  BookChapterContent? _content;
  bool _isLoadingContent = false;

  double get _fontSize => _sessionFontSize.clamp(12.0, 26.0);

  @override
  void initState() {
    super.initState();
    _loadChapters();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadChapters() async {
    setState(() {
      _isLoadingChapters = true;
      _chaptersFailed = false;
    });
    final result = await BooksService.fetchChapters(widget.book);
    if (!mounted) return;
    setState(() {
      _chapters = result.chapters;
      _isLoadingChapters = false;
      _chaptersFailed = result.chapters.isEmpty;
    });
    if (result.chapters.isNotEmpty) {
      unawaited(_openChapter(0));
    }
  }

  Future<void> _openChapter(int index) async {
    if (index < 0 || index >= _chapters.length) return;
    final chapter = _chapters[index];
    setState(() {
      _chapterIndex = index;
      _isLoadingContent = true;
      _content = null;
    });
    final content =
        await BooksService.fetchChapterContent(widget.book.sourceId, chapter.href);
    if (!mounted) return;
    setState(() {
      _content = content;
      _isLoadingContent = false;
    });
    // initState 直通首章时列表还没 build，控制器尚未挂载，
    // hasClients 守卫避免 'not attached to any scroll views' 断言崩溃
    if (_scrollController.hasClients) {
      unawaited(_scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ));
    }
  }

  bool get _hasPrev => _chapterIndex > 0;
  bool get _hasNext => _chapterIndex >= 0 && _chapterIndex < _chapters.length - 1;

  BookChapter? get _currentChapter =>
      _chapterIndex >= 0 && _chapterIndex < _chapters.length
          ? _chapters[_chapterIndex]
          : null;

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

  Widget _buildHeader(bool isDark) {
    final chapter = _currentChapter;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
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
                  chapter?.title ?? widget.book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: FontUtils.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF2c3e50),
                  ),
                ),
                Text(
                  '${widget.book.title}${chapter == null ? '' : ' · ${widget.book.author.isEmpty ? '' : '${widget.book.author} · '}${_chapterIndex + 1}/${_chapters.length}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
          if (_chapters.isNotEmpty)
            IconButton(
              onPressed: () => _showChapterSheet(isDark),
              icon: const Icon(LucideIcons.list, size: 20),
              color: isDark ? Colors.white : const Color(0xFF2c3e50),
              tooltip: '章节目录',
            ),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoadingChapters) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_chaptersFailed) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.list,
        title: '没有拿到章节目录',
        description: '该书源可能暂时不可用，或缺少目录规则。稍后重试。',
        showRetry: true,
        onRetry: _loadChapters,
      );
    }
    if (_isLoadingContent) {
      return const Center(child: CircularProgressIndicator());
    }
    final content = _content;
    if (content == null || content.paragraphs.isEmpty) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.bookOpen,
        title: '本章没有内容',
        description: '正文抓取失败或该源缺少正文规则。稍后重试。',
        showRetry: true,
        onRetry: () => _openChapter(_chapterIndex),
      );
    }

    final paragraphs = content.paragraphs;
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      itemCount: paragraphs.length,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          paragraphs[index],
          style: FontUtils.poppins(
            fontSize: _fontSize,
            height: 1.7,
            color: isDark ? const Color(0xFFe8e8e8) : const Color(0xFF2c3e50),
          ),
          textAlign: TextAlign.justify,
        ),
      ),
    );
  }

  /// 底部：上一章 / 字号 / 下一章
  Widget _buildBottomBar(bool isDark) {
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: _hasPrev
                  ? () => unawaited(_openChapter(_chapterIndex - 1))
                  : null,
              child: const Text('上一章'),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _sessionFontSize = (_fontSize - 1).clamp(12.0, 26.0);
            }),
            child: Text(
              'A-',
              style: FontUtils.poppins(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(() {
              _sessionFontSize = (_fontSize + 1).clamp(12.0, 26.0);
            }),
            child: Text(
              'A+',
              style: FontUtils.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: _hasNext
                  ? () => unawaited(_openChapter(_chapterIndex + 1))
                  : null,
              child: const Text('下一章'),
            ),
          ),
        ],
      ),
    );
  }

  /// 章节目录（底部弹出，当前章高亮）
  void _showChapterSheet(bool isDark) {
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
                      child: Text(
                        '章节目录（${_chapters.length}）',
                        style: FontUtils.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color:
                              isDark ? Colors.white : const Color(0xFF2c3e50),
                        ),
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
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: _chapters.length,
                  itemBuilder: (context, index) {
                    final isCurrent = index == _chapterIndex;
                    return ListTile(
                      dense: true,
                      title: Text(
                        _chapters[index].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FontUtils.poppins(
                          fontSize: 13.5,
                          fontWeight:
                              isCurrent ? FontWeight.w700 : FontWeight.w400,
                          color: isCurrent
                              ? _accentColor
                              : (isDark
                                  ? Colors.white
                                  : const Color(0xFF2c3e50)),
                        ),
                      ),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_openChapter(index));
                      },
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

  Widget _buildMessageState({
    required bool isDark,
    required IconData icon,
    required String title,
    required String description,
    required bool showRetry,
    required VoidCallback onRetry,
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
                color:
                    isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
              ),
            ),
            if (showRetry) ...[
              const SizedBox(height: 16),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}