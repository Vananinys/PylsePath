import 'package:flutter/material.dart';

import '../models/ride_media.dart';
import '../services/ride_media_service.dart';
import 'chat_photo.dart';
import 'video_poster.dart';

/// A frame, never a video download/player, inside a small map marker.
class TrackMediaThumbnail extends StatefulWidget {
  const TrackMediaThumbnail({
    super.key,
    this.local,
    this.shared,
    this.selected = false,
    this.count = 1,
    this.onTap,
  });
  final RideMedia? local;
  final SharedRideMedia? shared;
  final bool selected;
  final int count;
  final VoidCallback? onTap;
  @override
  State<TrackMediaThumbnail> createState() => _TrackMediaThumbnailState();
}

class _TrackMediaThumbnailState extends State<TrackMediaThumbnail> {
  Future<String>? _url;
  String? get _reference => widget.shared?.kind == RideMediaKind.video
      ? widget.shared?.posterReference
      : widget.shared?.reference;
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(TrackMediaThumbnail old) {
    super.didUpdateWidget(old);
    if (old.shared?.reference != widget.shared?.reference ||
        old.shared?.posterReference != widget.shared?.posterReference) {
      _resolve();
    }
  }

  void _resolve() {
    final reference = _reference;
    _url = reference == null ? null : RideMediaService.signedUrl(reference);
  }

  @override
  Widget build(BuildContext context) {
    final video =
        (widget.local?.kind ?? widget.shared?.kind) == RideMediaKind.video;
    final caption = widget.local?.caption ?? widget.shared?.caption ?? '';
    return Semantics(
      button: true,
      label:
          '${video ? 'Видео' : 'Фото'}${widget.count > 1 ? ', ${widget.count} материалов здесь' : ''}${caption.isEmpty ? '' : ', $caption'}',
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade800,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white,
              width: widget.selected ? 3 : 2,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.local != null)
                if (video)
                  VideoPoster(localSource: widget.local!.localPath, small: true)
                else
                  ChatPhoto(
                    source: widget.local!.localPath,
                    decodeWidth: 192,
                    compact: true,
                    onRetry: () async {},
                  )
              else
                FutureBuilder<String>(
                  future: _url,
                  builder: (context, snapshot) => snapshot.hasData
                      ? ChatPhoto(
                          source: snapshot.data!,
                          decodeWidth: 192,
                          compact: true,
                          onRetry: () async {
                            setState(_resolve);
                          },
                        )
                      : ColoredBox(
                          color: Colors.blueGrey.shade800,
                          child: Icon(
                            video ? Icons.videocam : Icons.photo,
                            color: Colors.white,
                          ),
                        ),
                ),
              if (video)
                const Center(
                  child: Icon(
                    Icons.play_circle_fill,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              if (widget.count > 1)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    color: Colors.black87,
                    child: Text(
                      '+${widget.count - 1}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class TrackMediaStrip extends StatefulWidget {
  const TrackMediaStrip({
    super.key,
    this.local = const [],
    this.shared = const [],
    this.selectedId,
    required this.onSelect,
    required this.onOpen,
  });
  final List<RideMedia> local;
  final List<SharedRideMedia> shared;
  final String? selectedId;
  final void Function(String) onSelect, onOpen;
  @override
  State<TrackMediaStrip> createState() => _TrackMediaStripState();
}

class _TrackMediaStripState extends State<TrackMediaStrip> {
  final _scroll = ScrollController();
  List<RideMedia> get local => widget.local;
  List<SharedRideMedia> get shared => widget.shared;
  String? get selectedId => widget.selectedId;
  void onSelect(String id) => widget.onSelect(id);
  void onOpen(String id) => widget.onOpen(id);
  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(TrackMediaStrip old) {
    super.didUpdateWidget(old);
    if (old.selectedId != selectedId) _follow();
  }

  void _follow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || selectedId == null) return;
      final ids = [...local.map((m) => m.id), ...shared.map((m) => m.id)];
      final index = ids.indexOf(selectedId!);
      if (index < 0) return;
      _scroll.animateTo(
        (index * 112.0).clamp(0.0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = [
      for (final item in local)
        (id: item.id, caption: item.caption, local: item, shared: null),
      for (final item in shared)
        (id: item.id, caption: item.caption, local: null, shared: item),
    ];
    return SizedBox(
      height:
          144 + (MediaQuery.textScalerOf(context).scale(12) - 12).clamp(0, 36),
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = entries[index];
          return SizedBox(
            width: 104,
            child: Column(
              children: [
                SizedBox(
                  height: 72,
                  child: TrackMediaThumbnail(
                    local: item.local,
                    shared: item.shared,
                    selected: item.id == selectedId,
                    onTap: () => onSelect(item.id),
                  ),
                ),
                Text(
                  item.caption.isEmpty ? 'Место ${index + 1}' : item.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                SizedBox(
                  height: 36,
                  child: TextButton(
                    onPressed: () => onOpen(item.id),
                    child: const Text('Открыть', maxLines: 1),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
