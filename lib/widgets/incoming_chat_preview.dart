import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../utils/ride_id.dart';

class IncomingChatItem {
  const IncomingChatItem(this.message, this.title, this.preview);
  final ChatMessage message;
  final String title;
  final String preview;
}

/// A single queue keeps new arrivals from replacing a reply being composed.
class IncomingChatPreview extends StatefulWidget {
  const IncomingChatPreview({
    super.key,
    required this.items,
    required this.visible,
    required this.onReply,
    required this.onRead,
    required this.onOpen,
  });

  final ValueNotifier<List<IncomingChatItem>> items;
  final ValueNotifier<bool> visible;
  final Future<void> Function(IncomingChatItem, String, String) onReply;
  final Future<void> Function(IncomingChatItem) onRead;
  final Future<void> Function(IncomingChatItem) onOpen;

  @override
  State<IncomingChatPreview> createState() => _IncomingChatPreviewState();
}

class _IncomingChatPreviewState extends State<IncomingChatPreview> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  Timer? _timer;
  String? _activeId;
  String? _attemptId;
  String? _attemptText;
  String? _error;
  bool _expanded = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.items.addListener(_changed);
    _changed();
    _focus.addListener(_hold);
    _text.addListener(_hold);
  }

  void _hold() {
    if (_focus.hasFocus || _text.text.isNotEmpty) _timer?.cancel();
  }

  void _changed() {
    final id = widget.items.value.firstOrNull?.message.id;
    if (_activeId != id) {
      _activeId = id;
      _text.clear();
      _focus.unfocus();
      _expanded = false;
      _error = null;
      _attemptId = null;
      _attemptText = null;
      _timer?.cancel();
      if (id != null) {
        _timer = Timer(const Duration(seconds: 10), () {
          if (mounted && !_sending && !_expanded && _text.text.isEmpty) {
            _dismiss();
          }
        });
      }
    }
    if (mounted) setState(() {});
  }

  void _dismiss() {
    if (_sending) return;
    _timer?.cancel();
    widget.items.value = widget.items.value.skip(1).toList();
  }

  Future<void> _send(IncomingChatItem item) async {
    final text = _attemptText ?? _text.text.trim();
    if (_sending || text.isEmpty) return;
    _timer?.cancel();
    _attemptId ??= newRideId();
    _attemptText = text;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.onReply(item, text, _attemptId!);
      if (!mounted) return;
      _sending = false;
      _dismiss();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Не удалось отправить. Ответ сохранён — повторите отправку.';
      });
    }
  }

  @override
  void dispose() {
    widget.items.removeListener(_changed);
    _timer?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items.value.firstOrNull;
    if (item == null) return const SizedBox.shrink();
    final media = MediaQuery.of(context);
    return Positioned(
      top: media.padding.top + 8,
      left: 12,
      right: 12,
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.visible,
        builder: (context, visible, child) => Offstage(
          offstage: !visible,
          child: TickerMode(enabled: visible, child: child!),
        ),
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          color: Theme.of(context).colorScheme.surface,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  (media.size.height -
                          media.padding.top -
                          media.viewInsets.bottom -
                          24)
                      .clamp(100.0, 480.0),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.chat_bubble_outline,
                        color: Colors.deepOrange,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (widget.items.value.length > 1)
                        Text('+${widget.items.value.length - 1}'),
                      IconButton(
                        tooltip: 'Закрыть',
                        onPressed: _sending ? null : _dismiss,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text(
                    item.preview,
                    maxLines: _expanded ? null : 4,
                    overflow: _expanded ? null : TextOverflow.ellipsis,
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() => _expanded = true);
                          _timer?.cancel();
                          _focus.requestFocus();
                        },
                        child: const Text('Ответить'),
                      ),
                      TextButton(
                        onPressed: _sending
                            ? null
                            : () async {
                                _timer?.cancel();
                                setState(() => _expanded = true);
                                try {
                                  await widget.onRead(item);
                                } catch (_) {
                                  if (mounted) {
                                    setState(
                                      () => _error =
                                          'Не удалось отметить прочитанным',
                                    );
                                  }
                                }
                              },
                        child: const Text('Прочитано'),
                      ),
                      TextButton(
                        onPressed: _sending
                            ? null
                            : () {
                                _dismiss();
                                unawaited(widget.onOpen(item));
                              },
                        child: const Text('В чат'),
                      ),
                    ],
                  ),
                  if (_expanded)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _text,
                            focusNode: _focus,
                            readOnly: _sending || _attemptId != null,
                            minLines: 1,
                            maxLines: 4,
                            maxLength: 4000,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(
                              hintText: 'Быстрый ответ…',
                              counterText: '',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: _error == null ? 'Отправить' : 'Повторить',
                          onPressed: _sending ? null : () => _send(item),
                          icon: _sending
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.send,
                                  color: Colors.deepOrange,
                                ),
                        ),
                      ],
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
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
}
