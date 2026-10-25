import '../models/activity_type.dart';
import '../models/saved_route.dart';

enum RouteSort { recent, shortest, longest, climb }

List<SavedRoute> filterRoutes(
  Iterable<SavedRoute> routes, {
  String query = '',
  ActivityType? activity,
  bool favorites = false,
  String? collection,
  double? maxKm,
  RouteSort sort = RouteSort.recent,
}) {
  final words = query.toLowerCase().trim().split(RegExp(r'\s+'));
  final result = routes.where((route) {
    final text =
        '${route.title} ${route.collection} ${route.routeNotes} ${route.activityType.label}'
            .toLowerCase();
    return words.every(text.contains) &&
        (activity == null || route.activityType == activity) &&
        (!favorites || route.isFavorite) &&
        (collection == null || route.collection == collection) &&
        (maxKm == null || route.distanceKm <= maxKm);
  }).toList();
  result.sort((a, b) {
    final comparison = switch (sort) {
      RouteSort.recent =>
        (b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
          a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
      RouteSort.shortest => a.distanceKm.compareTo(b.distanceKm),
      RouteSort.longest => b.distanceKm.compareTo(a.distanceKm),
      RouteSort.climb => b.elevationGainMeters.compareTo(a.elevationGainMeters),
    };
    return comparison != 0 ? comparison : a.localId.compareTo(b.localId);
  });
  return result;
}
