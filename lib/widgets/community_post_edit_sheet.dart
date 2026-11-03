import 'package:flutter/material.dart';

import '../models/community_post.dart';
import 'community_composer_frame.dart';

Future<bool> showCommunityPostEditor(
  BuildContext context, {
  required CommunityPost post,
  required String? Function() currentUserId,
  required Future<void> Function(String body) onSave,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CommunityPostEditSheet(
        post: post,
        currentUserId: currentUserId,
        onSave: onSave,
      ),
    ) ??
    false;

/// Updates only text. Existing media, geometry consent and audience stay attached.
class CommunityPostEditSheet extends StatefulWidget {
  const CommunityPostEditSheet({
    super.key,
    required this.post,
    required this.currentUserId,
    required this.onSave,
  });
  final CommunityPost post;
  final String? Function() currentUserId;
  final Future<void> Function(String body) onSave;
  @override
  State<CommunityPostEditSheet> createState() => _CommunityPostEditSheetState();
}

class _CommunityPostEditSheetState extends State<CommunityPostEditSheet> {
  late final TextEditingController _body = TextEditingController(
    text: widget.post.body,
  )..addListener(_changed);
  bool _saving = false, _allowClose = false;
  String? _error;
  bool get _owned => widget.currentUserId() == widget.post.authorId;
  bool get _dirty => _body.text != widget.post.body;
  bool get _hasAttachments =>
      widget.post.hasVideo ||
      widget.post.photoUrls.isNotEmpty ||
      widget.post.privatePhotoPaths.isNotEmpty ||
      widget.post.rideId != null ||
      widget.post.routeAttachment != null;
  bool get _valid =>
      _body.text.characters.length <= 1000 &&
      (_body.text.trim().isNotEmpty || _hasAttachments);
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_saving) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Выйти без сохранения?'),
          content: const Text(
            'Изменённый текст не сохранится. Опубликованный пост останется прежним.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Продолжить'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Выйти'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() => _allowClose = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, false);
    });
  }

  Future<void> _save() async {
    if (_saving || !_dirty || !_valid) return;
    if (!_owned) {
      setState(() => _error = 'Аккаунт изменился. Откройте публикацию заново.');
      return;
    }
    final body = _body.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(body);
      if (!mounted) return;
      if (!_owned) {
        setState(() {
          _saving = false;
          _error = 'Аккаунт изменился. Откройте публикацию заново.';
        });
        return;
      }
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _owned
            ? 'Не удалось сохранить текст. Проверьте подключение и повторите.'
            : 'Аккаунт изменился. Откройте публикацию заново.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving && (!_dirty || _allowClose),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: CommunityComposerFrame(
      title: const Text('Редактировать пост'),
      busy: _saving || !_owned,
      onClose: _saving ? null : _close,
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.post.audience == CommunityPostAudience.friends
                  ? 'Аудитория: только друзья'
                  : 'Аудитория: все пользователи',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            if (_hasAttachments)
              const Text(
                'Фотографии и прикреплённый заезд сохранятся вместе с публикацией.',
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _body,
              enabled: !_saving && _owned,
              minLines: 5,
              maxLines: 12,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Текст публикации',
                alignLabelWithHint: true,
              ),
            ),
            if (_error != null || !_owned)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error ?? 'Редактировать публикацию может только её автор.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _close,
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _saving || !_owned || !_valid || !_dirty ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Сохранить'),
        ),
      ],
    ),
  );
}
