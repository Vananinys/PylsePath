import '../data/saved_routes_repository.dart';
import '../data/workout_history_repository.dart';
import '../data/user_scope.dart';
import '../models/saved_route.dart';

enum CommunityRouteSource { saved, workout }

class CommunityRouteChoice {
  const CommunityRouteChoice({required this.route, required this.source});
  final SavedRoute route;
  final CommunityRouteSource source;
  String get kind => source == CommunityRouteSource.workout ? 'ride' : 'route';
  String get key => '${source.name}:${route.localId}';
}

/// Reads the two existing account-scoped libraries without copying their data.
class CommunityRouteChoices {
  CommunityRouteChoices({
    String? Function()? currentUserId,
    Future<List<SavedRoute>> Function()? savedLoader,
    Future<List<SavedRoute>> Function()? workoutLoader,
  }) : _currentUserId = currentUserId ?? UserScope.currentUserId,
       _savedLoader = savedLoader ?? _saved,
       _workoutLoader = workoutLoader ?? _workouts {
    _owner = _currentUserId();
  }
  final String? Function() _currentUserId;
  final Future<List<SavedRoute>> Function() _savedLoader, _workoutLoader;
  late final String? _owner;
  bool get isCurrentOwner => _owner != null && _owner == _currentUserId();
  void _requireOwner() {
    if (!isCurrentOwner) {
      throw StateError('Аккаунт изменился. Откройте выбор маршрута заново.');
    }
  }

  static Future<List<SavedRoute>> _saved() =>
      SavedRoutesRepository().getSavedRoutes();
  static Future<List<SavedRoute>> _workouts() async {
    final repo = WorkoutHistoryRepository();
    await repo.load();
    return repo.workoutHistoryDesc;
  }

  Future<List<CommunityRouteChoice>> loadChoices() async {
    _requireOwner();
    final saved = await _savedLoader();
    _requireOwner();
    final workouts = await _workoutLoader();
    _requireOwner();
    final result = <CommunityRouteChoice>[
      for (final route in saved)
        CommunityRouteChoice(route: route, source: CommunityRouteSource.saved),
      for (final route in workouts)
        CommunityRouteChoice(
          route: route,
          source: CommunityRouteSource.workout,
        ),
    ];
    final seen = <String>{};
    return result.where((choice) => seen.add(choice.key)).toList();
  }
}
