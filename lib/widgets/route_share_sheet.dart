import 'package:flutter/material.dart';

import '../models/shared_route.dart';
import '../models/friend_profile.dart';
import '../data/workout_history_repository.dart';
import '../data/saved_routes_repository.dart';
import '../services/friend_service.dart';
import '../services/chat_service.dart';

Future<void> showRouteShareSheet(BuildContext context, SharedRoute route) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ShareSheet(route: route),
    );

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.route});
  final SharedRoute route;
  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  late final _friends = FriendService().fetchFriends();
  String? _sending;
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
                            await ChatService().sendMessage(
                              friend.id,
                              text:
                                  '${widget.route.label}: ${widget.route.title}',
                              routeAttachment: widget.route,
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
