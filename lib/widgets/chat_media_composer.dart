import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/chat_media_draft.dart';
import '../widgets/chat_photo_editor.dart';
import '../widgets/chat_video_player.dart';
import 'video_poster.dart';

class ChatMediaSelection {
  const ChatMediaSelection(this.items, this.caption);
  final List<ChatMediaDraft> items;
  final String caption;
}

class ChatMediaComposer extends StatefulWidget {
  const ChatMediaComposer({
    super.key,
    required this.items,
    required this.onAddPhotos,
    required this.onAddVideo,
  });
  final List<ChatMediaDraft> items;
  final Future<List<ChatMediaDraft>> Function() onAddPhotos;
  final Future<List<ChatMediaDraft>> Function() onAddVideo;
  @override
  State<ChatMediaComposer> createState() => _ChatMediaComposerState();
}

class _ChatMediaComposerState extends State<ChatMediaComposer> {
  late final List<ChatMediaDraft> _items = List.of(widget.items);
  int _selected = 0;
  bool _busy = false;
  final _caption = TextEditingController();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<Uint8List>? _preview;
  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  void _loadPreview() {
    final item = _items.isEmpty ? null : _items[_selected];
    _preview = item == null || item.isVideo
        ? null
        : item.editedBytes != null
        ? Future.value(item.editedBytes)
        : item.file.readAsBytes();
  }

  void _error(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _add(Future<List<ChatMediaDraft>> Function() pick) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final added = await pick();
      if (!mounted || added.isEmpty) return;
      final error = ChatMediaDraft.validateBatch([..._items, ...added]);
      if (error != null) {
        _error(error);
        return;
      }
      setState(() {
        _items.addAll(added);
        _selected = _items.length - added.length;
        _loadPreview();
      });
    } catch (_) {
      if (mounted) _error('Не удалось выбрать вложение');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    if (_busy || _items.isEmpty || _items[_selected].isVideo) return;
    final index = _selected;
    setState(() => _busy = true);
    try {
      final bytes = await _preview!;
      if (!mounted) return;
      final result = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(builder: (_) => ChatPhotoEditor(bytes: bytes)),
      );
      if (result == null || !mounted) return;
      final edited = _items[index].edited(result);
      final next = List<ChatMediaDraft>.of(_items)..[index] = edited;
      final error = ChatMediaDraft.validateBatch(next);
      if (error != null) {
        _error(error);
        return;
      }
      setState(() {
        _items[index] = edited;
        _loadPreview();
      });
    } catch (_) {
      if (mounted) _error('Не удалось открыть редактор фото');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remove() {
    if (_busy || _items.isEmpty) return;
    setState(() {
      _items.removeAt(_selected);
      _selected = _items.isEmpty ? 0 : _selected.clamp(0, _items.length - 1);
      _loadPreview();
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _items.isEmpty ? null : _items[_selected];
    final error = ChatMediaDraft.validateBatch(_items);
    const foreground = Colors.white;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: const Color(0xff181818),
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Назад',
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back, color: foreground),
                  ),
                  Expanded(
                    child: Text(
                      'Предпросмотр · ${_items.length}/${ChatMediaDraft.maxItems}',
                      style: const TextStyle(
                        color: foreground,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Убрать выбранное',
                    onPressed: _busy || selected == null ? null : _remove,
                    icon: const Icon(Icons.delete_outline, color: foreground),
                  ),
                ],
              ),
              Expanded(
                child: Center(
                  child: selected == null
                      ? const Text(
                          'Добавьте фото или видео',
                          style: TextStyle(color: foreground),
                        )
                      : selected.isVideo
                      ? ChatVideoPlayer(
                          key: ValueKey(selected.file.path),
                          source: selected.file.path,
                          embedded: true,
                        )
                      : FutureBuilder<Uint8List>(
                          future: _preview,
                          builder: (context, snapshot) => snapshot.hasData
                              ? InteractiveViewer(
                                  key: ValueKey(
                                    '${selected.file.path}-$_selected',
                                  ),
                                  minScale: 1,
                                  maxScale: 4,
                                  child: Image.memory(
                                    snapshot.data!,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) => const Text(
                                      'Фото не удалось показать',
                                      style: TextStyle(color: foreground),
                                    ),
                                  ),
                                )
                              : snapshot.hasError
                              ? const Text(
                                  'Не удалось прочитать фото',
                                  style: TextStyle(color: foreground),
                                )
                              : const CircularProgressIndicator(),
                        ),
                ),
              ),
              if (_items.length > 1)
                SizedBox(
                  height: 64,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    scrollDirection: Axis.horizontal,
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 7),
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return Semantics(
                        button: true,
                        selected: index == _selected,
                        label: 'Вложение ${index + 1} из ${_items.length}',
                        child: InkWell(
                          onTap: _busy
                              ? null
                              : () => setState(() {
                                  _selected = index;
                                  _loadPreview();
                                }),
                          child: Container(
                            width: 56,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: index == _selected
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.transparent,
                                width: 3,
                              ),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: item.isVideo
                                  ? VideoPoster(
                                      localSource: item.file.path,
                                      small: true,
                                    )
                                  : FutureBuilder<Uint8List>(
                                      future: item.editedBytes != null
                                          ? Future.value(item.editedBytes)
                                          : item.file.readAsBytes(),
                                      builder: (_, snapshot) => snapshot.hasData
                                          ? Image.memory(
                                              snapshot.data!,
                                              fit: BoxFit.cover,
                                              cacheWidth: 160,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                    Icons.broken_image,
                                                    color: foreground,
                                                  ),
                                            )
                                          : const Icon(
                                              Icons.photo,
                                              color: foreground,
                                            ),
                                    ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              if (error != null && _items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    error,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                child: TextField(
                  controller: _caption,
                  enabled: !_busy,
                  maxLength: 4000,
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(color: foreground),
                  decoration: InputDecoration(
                    hintText: 'Добавить подпись…',
                    hintStyle: const TextStyle(color: Colors.white70),
                    counterText: '',
                    filled: true,
                    fillColor: const Color(0xff383838),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 12, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Ещё фото',
                      onPressed: _busy || _items.length >= 20
                          ? null
                          : () => _add(widget.onAddPhotos),
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      color: foreground,
                    ),
                    IconButton(
                      tooltip: 'Ещё видео',
                      onPressed: _busy || _items.length >= 20
                          ? null
                          : () => _add(widget.onAddVideo),
                      icon: const Icon(Icons.video_library_outlined),
                      color: foreground,
                    ),
                    if (selected != null && !selected.isVideo)
                      IconButton(
                        tooltip: 'Обрезать или рисовать',
                        onPressed: _busy ? null : _edit,
                        icon: const Icon(Icons.tune),
                        color: foreground,
                      ),
                    if (selected?.editedBytes != null)
                      IconButton(
                        tooltip: 'Вернуть оригинал',
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _items[_selected] = ChatMediaDraft(
                                  file: selected!.file,
                                  isVideo: false,
                                  size: selected.size,
                                );
                                _loadPreview();
                              }),
                        icon: const Icon(Icons.restore),
                        color: foreground,
                      ),
                    const Spacer(),
                    IconButton.filled(
                      tooltip: 'Отправить ${_items.length}',
                      onPressed: _busy || error != null
                          ? null
                          : () => Navigator.pop(
                              context,
                              ChatMediaSelection(
                                List<ChatMediaDraft>.unmodifiable(_items),
                                _caption.text.trim(),
                              ),
                            ),
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
