import 'package:flutter/material.dart';

import '../models/saved_route.dart';

class CommunityComposerFrame extends StatelessWidget {
  const CommunityComposerFrame({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    required this.onClose,
    this.busy = false,
  });
  final bool busy;
  final Widget title, content;
  final List<Widget> actions;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: title,
        leading: IconButton(
          tooltip: 'Закрыть',
          onPressed: onClose,
          icon: const Icon(Icons.close),
        ),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: IgnorePointer(ignoring: busy, child: content),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            12,
            12,
            12,
            12 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: actions,
          ),
        ),
      ),
    ),
  );
}

class CommunityRidePicker extends StatelessWidget {
  const CommunityRidePicker({
    super.key,
    required this.rides,
    required this.selectedId,
    required this.onChanged,
    this.busy = false,
  });
  final List<SavedRoute> rides;
  final String? selectedId;
  final ValueChanged<String?> onChanged;
  final bool busy;
  String title(SavedRoute route) =>
      route.title.trim().isEmpty ? 'Тренировка' : route.title;
  String details(BuildContext context, SavedRoute route) =>
      '${MaterialLocalizations.of(context).formatMediumDate(route.dateTime)} · ${route.distanceKm.toStringAsFixed(1)} км · ${route.duration}';
  @override
  Widget build(BuildContext context) {
    final selected = rides.where((r) => r.localId == selectedId).firstOrNull;
    return Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.route_outlined),
            title: Text(
              selected == null ? 'Прикрепить заезд' : title(selected),
            ),
            subtitle: Text(
              selected == null
                  ? 'Необязательно · выберите из истории'
                  : details(context, selected),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy
                ? null
                : () async {
                    final id = await showModalBottomSheet<String>(
                      context: context,
                      useSafeArea: true,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (context) => SizedBox(
                        height: MediaQuery.sizeOf(context).height * .7,
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                'Выберите заезд',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            Expanded(
                              child: ListView(
                                children: [
                                  for (final ride in rides)
                                    ListTile(
                                      title: Text(title(ride)),
                                      subtitle: Text(details(context, ride)),
                                      trailing: selectedId == ride.localId
                                          ? const Icon(Icons.check_circle)
                                          : null,
                                      onTap: () =>
                                          Navigator.pop(context, ride.localId),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                    if (id != null) onChanged(id);
                  },
          ),
          if (selected != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: busy ? null : () => onChanged(null),
                child: const Text('Не прикреплять заезд'),
              ),
            ),
        ],
      ),
    );
  }
}
