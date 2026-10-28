import 'package:flutter/material.dart';

import '../models/shared_route.dart';
import '../models/friend_profile.dart';
import '../data/workout_history_repository.dart';
import '../data/saved_routes_repository.dart';
import '../services/friend_service.dart';
import '../services/chat_service.dart';
import '../models/saved_route.dart';
import '../services/ride_media_service.dart';
import 'ride_media_selection.dart';
import 'track_privacy_picker.dart';

Future<void> showRouteShareSheet(
  BuildContext context,
  SharedRoute route, {
  SavedRoute? source,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _ShareSheet(route: route, source: source),
);

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.route, this.source});
  final SharedRoute route;
  final SavedRoute? source;
  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _owner = ChatService().userId;
  late final _friends = FriendService().fetchFriends();
  String? _sending;
  bool _includeTrack = true;
  int _radius = 0;
  Set<String> _mediaIds = {};
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .65,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Отправить в чат',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          if (widget.source != null)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .27,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    children: [
                      TrackPrivacyPicker(
                        route: widget.source!,
                        enabled: _includeTrack,
                        radius: _radius,
                        onEnabled: (value) {
                          if (_sending == null) {
                            setState(() => _includeTrack = value);
                          }
                        },
                        onRadius: (value) {
                          if (_sending == null) setState(() => _radius = value);
                        },
                      ),
                      RideMediaSelection(
                        rideId: widget.source!.localId,
                        enabled: _includeTrack,
                        busy: _sending != null,
                        onChanged: (ids) => _mediaIds = ids,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Друг получит карточку со статистикой и доступным треком.',
            ),
          ),
          Expanded(
            child: FutureBuilder<List<FriendProfile>>(
              future: _friends,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.data!.isEmpty) {
                  return const Center(
                    child: Text('Сначала добавьте друга в сообществе'),
                  );
                }
                return ListView(
                  children: [
                    for (final friend in snapshot.data!)
                      ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.person_outline),
                        ),
                        title: Text(friend.username),
                        trailing: _sending == friend.id
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(),
                              )
                            : const Icon(Icons.send),
                        enabled: _sending == null,
                        onTap: () async {
                          setState(() => _sending = friend.id);
                          try {
                            final owner = _owner;
                            if (owner == null || owner != ChatService().userId) {
                              throw StateError('Аккаунт изменился. Откройте отправку заново.');
                            }
                            final snapshot = widget.source == null
                                ? widget.route
                                : await RideMediaService.prepareShare(
                                    widget.source!,
                                    selectedIds: _includeTrack ? _mediaIds : {},
                                    includeTrack: _includeTrack,
                                    hideRadiusMeters: _radius.toDouble(),
                                    kind: widget.route.kind,
                                  );
                            if (!mounted || owner != ChatService().userId) {
                              return;
                            }
                            await ChatService().sendMessage(
                              friend.id,
                              text:
                                  '${widget.route.label}: ${widget.route.title}',
                              routeAttachment: snapshot,
                            );
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Карточка отправлена в чат'),
                              ),
                            );
                          } catch (_) {
                            if (mounted) {
                              setState(() => _sending = null);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Не удалось отправить. Повторите.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

Future<SharedRoute?> showLocalRoutePicker(BuildContext context) async {
  final history = WorkoutHistoryRepository(), saved = SavedRoutesRepository();
  try {
    await Future.wait([history.load(), saved.load()]);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось прочитать поездки и маршруты'),
        ),
      );
    }
    return null;
  }
  if (!context.mounted) return null;
  return showModalBottomSheet<SharedRoute>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheet).height * .65,
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Выберите заезд или маршрут',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
              ),
            ),
            if (history.workoutHistory.isEmpty && saved.savedRoutes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Здесь появятся завершённые заезды и сохранённые маршруты',
                ),
              ),
            for (final route in history.workoutHistory.reversed)
              ListTile(
                leading: const Icon(Icons.directions_bike),
                title: Text(route.title),
                subtitle: Text(
                  'Заезд · ${route.distanceKm.toStringAsFixed(1)} км',
                ),
                onTap: () =>
                    Navigator.pop(sheet, SharedRoute.fromSavedRoute(route)),
              ),
            for (final route in saved.savedRoutes.reversed)
              ListTile(
                leading: const Icon(Icons.route),
                title: Text(route.title),
                subtitle: Text(
                  'Маршрут · ${route.distanceKm.toStringAsFixed(1)} км',
                ),
                onTap: () => Navigator.pop(
                  sheet,
                  SharedRoute.fromSavedRoute(route, kind: 'route'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
