import 'package:flutter/material.dart';

import '../screens/community_post_screen.dart';
import '../data/user_scope.dart';

/// Deliberately contains no cached post preview or private media.
class CommunityPostChatLink extends StatelessWidget {
  const CommunityPostChatLink({
    super.key,
    required this.postId,
    required this.expectedOwner,
  });
  final String postId;
  final String? expectedOwner;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () {
      if (expectedOwner == null || UserScope.currentUserId() != expectedOwner)
        return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CommunityPostScreen(postId: postId)),
      );
    },
    icon: const Icon(Icons.article_outlined),
    label: const Text('Открыть публикацию сообщества'),
  );
}
