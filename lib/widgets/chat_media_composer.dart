import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/chat_media_draft.dart';
import '../widgets/chat_photo_editor.dart';
import '../widgets/chat_video_player.dart';
import 'video_poster.dart';

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

  @override
  Widget build(BuildContext context) {
    final selected = _items.isEmpty ? null : _items[_selected];
    final error = ChatMediaDraft.validateBatch(_items);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: Text('Вложения · ${_items.length}/20')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: selected == null
                      ? const Text('Добавьте фото или видео')
                      : selected.isVideo
                      ? ChatVideoPlayer(
                          key: ValueKey(selected.file.path),
                          source: selected.file.path,
                          embedded: true,
                        )
                      : FutureBuilder<Uint8List>(
                          future: _preview,
                          builder: (context, snapshot) => snapshot.hasData
                              ? Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Image.memory(
                                    snapshot.data!,
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) =>
                                        const Text('Фото не удалось показать'),
                                  ),
                                )
                              : snapshot.hasError
                              ? const Text('Не удалось прочитать фото')
                              : const CircularProgressIndicator(),
                        ),
                ),
              ),
              SizedBox(
                height: 76,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  scrollDirection: Axis.horizontal,
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) => ChoiceChip(
                    selected: _selected == index,
                    avatar: _items[index].isVideo
                        ? VideoPoster(
                            localSource: _items[index].file.path,
                            small: true,
                          )
                        : const Icon(Icons.photo),
                    label: Text('${index + 1}'),
                    onSelected: _busy
                        ? null
                        : (_) => setState(() {
                            _selected = index;
                            _loadPreview();
                          }),
                  ),
                ),
              ),
              Flexible(
                flex: 0,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (selected != null)
                          Text(
                            selected.file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (error != null && _items.isNotEmpty)
                          Text(
                            error,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        const Text(
                          'До 20 файлов · фото до 20 МБ · видео до 50 МБ · всего до 100 МБ',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton.icon(
                              onPressed: _busy || _items.length >= 20
                                  ? null
                                  : () => _add(widget.onAddPhotos),
                              icon: const Icon(Icons.add_photo_alternate),
                              label: const Text('Ещё фото'),
                            ),
                            TextButton.icon(
                              onPressed: _busy || _items.length >= 20
                                  ? null
                                  : () => _add(widget.onAddVideo),
                              icon: const Icon(Icons.video_library),
                              label: const Text('Ещё видео'),
                            ),
                            if (selected != null && !selected.isVideo)
                              TextButton.icon(
                                onPressed: _busy ? null : _edit,
                                icon: const Icon(Icons.edit),
                                label: const Text('Редактировать'),
                              ),
                            if (selected?.editedBytes != null)
                              TextButton(
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
                                child: const Text('Оригинал'),
                              ),
                            if (selected != null)
                              TextButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => setState(() {
                                        _items.removeAt(_selected);
                                        _selected = _items.isEmpty
                                            ? 0
                                            : _selected.clamp(
                                                0,
                                                _items.length - 1,
                                              );
                                        _loadPreview();
                                      }),
                                icon: const Icon(Icons.remove_circle_outline),
                                label: const Text('Убрать'),
                              ),
                            FilledButton.icon(
                              onPressed: _busy || error != null
                                  ? null
                                  : () => Navigator.pop(
                                      context,
                                      List<ChatMediaDraft>.unmodifiable(_items),
                                    ),
                              icon: const Icon(Icons.send),
                              label: Text('Отправить ${_items.length}'),
                            ),
                          ],
                        ),
                      ],
                    ),
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
