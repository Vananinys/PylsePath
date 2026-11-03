import 'package:flutter/material.dart';

import '../models/community_post.dart';
import '../models/friend_profile.dart';
import '../services/chat_service.dart';
import '../services/friend_service.dart';
import '../utils/ride_id.dart';

typedef CommunityPostSender = Future<void> Function(
  String friendId,
  String postId,
  String owner,
  String messageId,
);

Future<bool> showCommunityPostShare(
  BuildContext context, {
  required CommunityPost post,
  Future<List<FriendProfile>> Function()? loadFriends,
  CommunityPostSender? send,
  String? Function()? currentOwner,
}) async {
  String? ownerNow() =>
      currentOwner != null ? currentOwner() : ChatService().userId;
  final owner = ownerNow();
  final sent =
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        builder: (_) => CommunityPostShareSheet(
          postId: post.id,
          loadFriends: loadFriends,
          send: send,
          currentOwner: currentOwner,
        ),
      ) ??
      false;
  if (sent && context.mounted && owner != null && ownerNow() == owner) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Публикация отправлена')));
  }
  return sent;
}

class CommunityPostShareSheet extends StatefulWidget {
  const CommunityPostShareSheet({
    super.key,
    required this.postId,
    this.loadFriends,
    this.send,
    this.currentOwner,
  });
  final String postId;
  final Future<List<FriendProfile>> Function()? loadFriends;
  final CommunityPostSender? send;
  final String? Function()? currentOwner;
  @override
  State<CommunityPostShareSheet> createState() =>
      _CommunityPostShareSheetState();
}

class _CommunityPostShareSheetState extends State<CommunityPostShareSheet> {
  String? get _current => widget.currentOwner != null
      ? widget.currentOwner!()
      : ChatService().userId;
  late final String? _owner = _current;
  bool get _sameOwner => _owner != null && _current == _owner;
  List<FriendProfile>? _friends;
  String? _error, _sending;
  int _generation = 0;
  final _messageIds = <String, String>{};
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (!_sameOwner) return;
    setState(() {
      _friends = null;
      _error = null;
    });
    try {
      final friends =
          await (widget.loadFriends?.call() ??
              FriendService().fetchFriends(strict: true));
      if (!mounted || generation != _generation) return;
      setState(() {
        _friends = _sameOwner
            ? friends.where((f) => f.id != _owner).toList()
            : null;
      });
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() => _error = 'Не удалось загрузить друзей');
    }
  }

  Future<void> _send(FriendProfile friend) async {
    if (_sending != null || !_sameOwner) return;
    setState(() {
      _sending = friend.id;
      _error = null;
    });
    try {
      final id = _messageIds.putIfAbsent(friend.id, newRideId);
      if (widget.send != null) {
        await widget.send!(friend.id, widget.postId, _owner!, id);
      } else {
        await ChatService().shareCommunityPost(
          friend.id,
          widget.postId,
          expectedOwner: _owner!,
          messageId: id,
        );
      }
      if (!mounted) return;
      if (!_sameOwner) {
        setState(() => _sending = null);
        return;
      }
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted)
        setState(() {
          _sending = null;
          _error = 'Не удалось отправить. Пост может быть недоступен другу. Проверьте интернет и повторите.';
        });
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: !_sameOwner
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Аккаунт изменился. Закройте окно и откройте отправку заново.',
                ),
              ),
            )
          : SingleChildScrollView(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Отправить другу',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Закрыть',
                          onPressed: _sending == null
                              ? () => Navigator.pop(context, false)
                              : null,
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Text(
                      'Выберите друга. Он получит ссылку; содержимое откроется, только если автор разрешил доступ.',
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  _friends == null
                      ? Center(
                          child: _error == null
                              ? const CircularProgressIndicator()
                              : TextButton.icon(
                                  onPressed: _load,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Повторить загрузку'),
                                ),
                        )
                      : _friends!.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Пока нет друзей. Добавьте их в разделе «Сообщество».',
                            ),
                          ),
                        )
                      : Column(
                          children: [
                            for (final friend in _friends!)
                              ListTile(
                                title: Text(friend.username),
                                subtitle: const Text(
                                  'Отправить ссылку на пост',
                                ),
                                trailing: _sending == friend.id
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(),
                                      )
                                    : const Icon(Icons.send_outlined),
                                enabled: _sending == null,
                                onTap: () => _send(friend),
                              ),
                          ],
                        ),
                ],
              ),
            ),
    ),
  );
}
