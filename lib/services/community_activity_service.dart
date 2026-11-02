import '../data/workout_history_repository.dart';
import '../models/community_activity.dart';
import '../models/community_post.dart';
import '../models/saved_route.dart';
import 'community_service.dart';

import '../data/user_scope.dart';

class CommunityActivityService {
  CommunityActivityService({
    this.historyLoader,
    this.friendsLoader,
    String? Function()? currentOwner,
  }) : _activityOwner = currentOwner ?? UserScope.currentUserId;
  final Future<List<SavedRoute>> Function()? historyLoader;
  final Future<List<CommunityPost>> Function()? friendsLoader;
  final String? Function() _activityOwner;
  String? get userId => _activityOwner();
  void _checkActivityOwner(String? owner) {
    if (owner == null || owner != userId) throw StateError('Аккаунт изменился');
  }

  Future<CommunityWeekActivity> loadMyWeek({DateTime? now}) async {
    final owner = userId;
    _checkActivityOwner(owner);
    final rows = historyLoader != null
        ? await historyLoader!()
        : await _history();
    _checkActivityOwner(owner);
    return CommunityWeekActivity.fromHistory(rows, now: now ?? DateTime.now());
  }

  Future<List<SavedRoute>> _history() async {
    final repo = WorkoutHistoryRepository();
    await repo.load();
    return repo.workoutHistoryDesc;
  }

  Future<List<CommunityPost>> loadFriendRides() async {
    final owner = userId;
    _checkActivityOwner(owner);
    final rows = friendsLoader != null
        ? await friendsLoader!()
        : await CommunityService().fetchFeed(
            scope: CommunityFeedScope.friends,
            type: CommunityPostType.rides,
            limit: 5,
            strict: true,
          );
    _checkActivityOwner(owner);
    return rows
        .where(
          (p) =>
              p.authorId != owner &&
              ((p.routeAttachment?.kind == 'ride') || p.rideId != null),
        )
        .take(3)
        .toList();
  }
}
