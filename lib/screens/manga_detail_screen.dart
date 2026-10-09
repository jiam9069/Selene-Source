import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../models/manga_models.dart';
import '../services/manga_service.dart';
import '../services/theme_service.dart';
import '../utils/device_utils.dart';
import '../utils/font_utils.dart';
import 'manga_reader_screen.dart';

/// 漫画详情页：元数据 + 章节列表
///
/// 详情接口在 Suwayomi 抓不到时会用搜索结果带来的元数据兜底，
/// 所以标题 / 封面一定有；章节列表可能为空（此时提示稍后重试）。
/// 点章节进 [MangaReaderScreen]（带上完整章节列表，方便上一章 / 下一章）。
class MangaDetailScreen extends StatefulWidget {
  final MangaItem item;

  const MangaDetailScreen({super.key, required this.item});

  @override
  State<MangaDetailScreen> createState() => _MangaDetailScreenState();
}

class _MangaDetailScreenState extends State<MangaDetailScreen> {
  MangaDetail? _detail;
  bool _isLoading = true;

  /// 章节列表默认倒序展示（最新章在最上），与主流漫画 App 一致
  bool _descending = true;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    final detail = await MangaService.fetchDetail(widget.item);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _isLoading = false;
    });
  }

  List<MangaChapter> get _chapters {
    final chapters = _detail?.chapters ?? const <MangaChapter>[];
    return _descending ? chapters.reversed.toList(growable: false) : chapters;
  }

  void _openChapter(int index) {
    final chapters = _chapters;
    if (chapters.isEmpty || index < 0 || index >= chapters.length) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => MangaReaderScreen(
          title: _detail?.title ?? widget.item.title,
          chapters: chapters,
          initialIndex: index,
        ),
      ),
    );
  }

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
            child: Text(
              _detail?.title ?? widget.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: FontUtils.poppins(
                fontSize: isTablet ? 20 : 17,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final detail = _detail;
    if (detail == null) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.imageOff,
        title: '详情加载失败',
        description: '可能是源站临时不可用，稍后重试。',
        showRetry: true,
      );
    }
    if (detail.chapters.isEmpty) {
      return _buildMessageState(
        isDark: isDark,
        icon: LucideIcons.list,
        title: '没有拿到章节列表',
        description: '源站可能暂时无法访问，稍后重试。',
        showRetry: true,
      );
    }

    final chapters = _chapters;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMetaSection(isDark, detail),
        _buildChapterToolbar(isDark, detail.chapters.length),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: chapters.length,
            itemBuilder: (context, index) => _buildChapterTile(
              isDark,
              chapters[index],
              index,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMetaSection(bool isDark, MangaDetail detail) {
    final mutedColor =
        isDark ? const Color(0xFFb0b0b0) : const Color(0xFF7f8c8d);
    final description = detail.description.trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 86,
              height: 118,
              child: detail.cover.isEmpty
                  ? Container(
                      color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
                      child: Icon(
                        LucideIcons.imageOff,
                        size: 28,
                        color: isDark
                            ? const Color(0xFF666666)
                            : const Color(0xFFbdc3c7),
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: detail.cover,
                      fit: BoxFit.cover,
                      httpHeaders: const {},
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detail.title,
                  style: FontUtils.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white : const Color(0xFF2c3e50),
                  ),
                ),
                const SizedBox(height: 4),
                if (detail.author.isNotEmpty)
                  Text(
                    '作者：${detail.author}',
                    style: FontUtils.poppins(fontSize: 12, color: mutedColor),
                  ),
                if (detail.status.isNotEmpty)
                  Text(
                    '状态：${detail.status}',
                    style: FontUtils.poppins(fontSize: 12, color: mutedColor),
                  ),
                Text(
                  '来源：${detail.sourceName}',
                  style: FontUtils.poppins(fontSize: 12, color: mutedColor),
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: FontUtils.poppins(
                      fontSize: 12,
                      color: isDark
                          ? const Color(0xFF808080)
                          : const Color(0xFF95a5a6),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 章节列表工具栏：章数 + 倒序切换
  Widget _buildChapterToolbar(bool isDark, int total) {
    final mutedColor =
        isDark ? const Color(0xFFb0b0b0) : const Color(0xFF7f8c8d);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '章节（$total）',
              style: FontUtils.poppins(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : const Color(0xFF2c3e50),
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _descending = !_descending),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1e1e1e) : Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _descending
                        ? LucideIcons.arrowDownNarrowWide
                        : LucideIcons.arrowUpWideNarrow,
                    size: 14,
                    color: mutedColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _descending ? '新→旧' : '旧→新',
                    style: FontUtils.poppins(fontSize: 12, color: mutedColor),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterTile(bool isDark, MangaChapter chapter, int index) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      dense: true,
      title: Text(
        chapter.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: FontUtils.poppins(
          fontSize: 13.5,
          color: isDark ? Colors.white : const Color(0xFF2c3e50),
        ),
      ),
      trailing: Icon(
        LucideIcons.chevronRight,
        size: 16,
        color:
            isDark ? const Color(0xFF666666) : const Color(0xFFbdc3c7),
      ),
      onTap: () => _openChapter(index),
    );
  }

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
                color:
                    isDark ? const Color(0xFF808080) : const Color(0xFF95a5a6),
              ),
            ),
            if (showRetry) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  setState(() => _isLoading = true);
                  _loadDetail();
                },
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
