import 'dart:async';

import 'package:flutter/material.dart';

/// Photos remain in memory only; viewing never downloads files to storage.
class CommunityPhotoViewer extends StatefulWidget {
  const CommunityPhotoViewer({
    super.key,
    required this.urls,
    this.initialIndex = 0,
    this.onRefreshPhotoUrls,
  });
  final List<String> urls;
  final int initialIndex;
  final Future<List<String>> Function()? onRefreshPhotoUrls;
  @override
  State<CommunityPhotoViewer> createState() => _CommunityPhotoViewerState();
}

class _CommunityPhotoViewerState extends State<CommunityPhotoViewer> {
  late List<String> urls = widget.urls;
  bool refreshing = false;
  @override
  void initState() {
    super.initState();
    if (widget.onRefreshPhotoUrls != null) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final refresh = widget.onRefreshPhotoUrls;
    if (refresh == null || refreshing) return;
    setState(() => refreshing = true);
    try {
      final fresh = await refresh();
      if (!mounted) return;
      setState(() {
        urls = fresh;
        index = fresh.isEmpty ? 0 : index.clamp(0, fresh.length - 1);
        zoomed = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && controller.hasClients && urls.isNotEmpty)
          controller.jumpToPage(index);
      });
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось обновить доступ к фотографиям. Попробуйте ещё раз.',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  late final PageController controller = PageController(initialPage: index);
  late int index = urls.isEmpty
      ? 0
      : widget.initialIndex.clamp(0, urls.length - 1);
  bool zoomed = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      leading: IconButton(
        tooltip: 'Закрыть фото',
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.pop(context),
      ),
      bottom: refreshing
          ? const PreferredSize(
              preferredSize: Size.fromHeight(3),
              child: LinearProgressIndicator(),
            )
          : null,
      title: Text('Фото ${urls.isEmpty ? 0 : index + 1} из ${urls.length}'),
    ),
    body: urls.isEmpty
        ? const Center(
            child: Text(
              'Фотографий нет',
              style: TextStyle(color: Colors.white),
            ),
          )
        : PageView.builder(
            controller: controller,
            physics: zoomed ? const NeverScrollableScrollPhysics() : null,
            itemCount: urls.length,
            onPageChanged: (value) => setState(() {
              index = value;
              zoomed = false;
            }),
            itemBuilder: (context, page) => _ZoomPhoto(
              key: ValueKey('${urls[page]}-$page-$index'),
              url: urls[page],
              onRetry: widget.onRefreshPhotoUrls == null ? null : _refresh,
              onZoom: (value) {
                if (page == index && value != zoomed) {
                  setState(() => zoomed = value);
                }
              },
            ),
          ),
    bottomNavigationBar: urls.length < 2
        ? null
        : SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  tooltip: 'Предыдущее фото',
                  color: Colors.white,
                  onPressed: index == 0
                      ? null
                      : () => controller.previousPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        ),
                  icon: const Icon(Icons.chevron_left),
                ),
                const Flexible(
                  child: Text(
                    'Листайте фото · увеличивайте двумя пальцами',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                IconButton(
                  tooltip: 'Следующее фото',
                  color: Colors.white,
                  onPressed: index == urls.length - 1
                      ? null
                      : () => controller.nextPage(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeOut,
                        ),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
  );
}

class _ZoomPhoto extends StatefulWidget {
  const _ZoomPhoto({
    super.key,
    required this.url,
    required this.onZoom,
    this.onRetry,
  });
  final String url;
  final ValueChanged<bool> onZoom;
  final Future<void> Function()? onRetry;
  @override
  State<_ZoomPhoto> createState() => _ZoomPhotoState();
}

class _ZoomPhotoState extends State<_ZoomPhoto> {
  int retry = 0;
  final transform = TransformationController();
  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => InteractiveViewer(
    transformationController: transform,
    minScale: 1,
    maxScale: 5,
    onInteractionUpdate: (_) =>
        widget.onZoom(transform.value.getMaxScaleOnAxis() > 1.01),
    child: Center(
      child: Image.network(
        widget.url,
        key: ValueKey(retry),
        fit: BoxFit.contain,
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
        errorBuilder: (context, error, stack) => SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 40,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Не удалось загрузить фото',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () async {
                    if (widget.onRetry != null) {
                      await widget.onRetry!();
                    }
                    if (!mounted) return;
                    await NetworkImage(widget.url).evict();
                    if (mounted) setState(() => retry++);
                  },
                  child: const Text(
                    'Повторить',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
