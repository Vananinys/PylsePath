import 'package:flutter/material.dart';

import '../services/moderation_service.dart';

Future<bool> showModerationAction(
  BuildContext context, {
  String? userId,
  String? userName,
  String? contentId,
  String kind = 'post',
  bool restore = false,
  bool unban = false,
}) async {
  var reason = '';
  final form = GlobalKey<FormState>();
  int hours = 168;
  bool busy = false;
  String? error;
  final isContent = contentId != null;
  final title = isContent
      ? (restore ? 'Восстановить публикацию?' : 'Удалить из сообщества?')
      : (unban ? 'Снять бан сообщества?' : 'Заблокировать в сообществе?');
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (c, update) => PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (userName != null)
                    Text(userName, style: Theme.of(c).textTheme.titleMedium),
                  Text(
                    isContent
                        ? (restore
                              ? 'Запись снова станет видна в сообществе.'
                              : 'Запись исчезнет из ленты. Её можно восстановить в панели модерации.')
                        : 'Бан ограничивает публикации, комментарии и новые лайки. Личные заезды, шаги и вход в аккаунт сохраняются.',
                  ),
                  if (!isContent && !unban)
                    DropdownButtonFormField<int>(
                      initialValue: hours,
                      decoration: const InputDecoration(labelText: 'Срок бана'),
                      items: const [
                        DropdownMenuItem(value: 24, child: Text('24 часа')),
                        DropdownMenuItem(value: 168, child: Text('7 дней')),
                        DropdownMenuItem(value: 720, child: Text('30 дней')),
                        DropdownMenuItem(value: 0, child: Text('Бессрочно')),
                      ],
                      onChanged: busy
                          ? null
                          : (v) => update(() => hours = v ?? 168),
                    ),
                  TextFormField(
                    initialValue: reason,
                    onChanged: (value) => reason = value,
                    enabled: !busy,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Причина (обязательно)',
                    ),
                    validator: (v) => (v?.trim().length ?? 0) < 3
                        ? 'Укажите причину, минимум 3 символа'
                        : null,
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(color: Theme.of(c).colorScheme.error),
                    ),
                  if (busy) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      update(() => busy = true);
                      try {
                        final service = ModerationService();
                        if (isContent) {
                          await service.content(
                            kind,
                            contentId,
                            hide: !restore,
                            reason: reason,
                          );
                        } else if (unban) {
                          await service.unban(userId!, reason: reason);
                        } else {
                          await service.ban(
                            userId!,
                            reason: reason,
                            hours: hours == 0 ? null : hours,
                          );
                        }
                        if (dialogContext.mounted)
                          Navigator.pop(dialogContext, true);
                      } catch (e) {
                        if (dialogContext.mounted)
                          update(() {
                            busy = false;
                            error = e is ModerationException
                                ? e.message
                                : 'Нет связи с сервером. Повторите попытку.';
                          });
                      }
                    },
              child: Text(
                isContent
                    ? (restore ? 'Восстановить' : 'Удалить')
                    : (unban ? 'Снять бан' : 'Заблокировать'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  // TextFormField owns its controller until the route transition finishes.
  return result == true;
}

Future<bool> showPostModeration(
  BuildContext context, {
  required String contentId,
  required String authorId,
  required String authorName,
  String kind = 'post',
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.hide_source),
            title: Text(
              kind == 'post' ? 'Удалить публикацию' : 'Удалить комментарий',
            ),
            onTap: () => Navigator.pop(c, 'hide'),
          ),
          ListTile(
            leading: const Icon(Icons.block),
            title: Text('Бан сообщества: $authorName'),
            onTap: () => Navigator.pop(c, 'ban'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return false;
  return showModerationAction(
    context,
    userId: authorId,
    userName: authorName,
    contentId: action == 'hide' ? contentId : null,
    kind: kind,
  );
}
