import 'package:flutter/material.dart';

import '../models/saved_route.dart';
import '../services/community_route_choices.dart';

Future<SavedRoute?> showCommunityRoutePicker(
  BuildContext context, {
  SavedRoute? selected,
  CommunityRouteSource? source,
  ValueChanged<CommunityRouteChoice>? onSelectedChoice,
  CommunityRouteChoices? choicesService,
}) => showDialog<SavedRoute>(
  context: context,
  barrierDismissible: false,
  builder: (_) => CommunityRoutePicker(
    selected: selected,
    source: source,
    onSelectedChoice: onSelectedChoice,
    choicesService: choicesService,
  ),
);

class CommunityRoutePicker extends StatefulWidget {
  const CommunityRoutePicker({
    super.key,
    this.selected,
    this.source,
    this.onSelectedChoice,
    this.choicesService,
  });
  final SavedRoute? selected;
  final CommunityRouteSource? source;
  final ValueChanged<CommunityRouteChoice>? onSelectedChoice;
  final CommunityRouteChoices? choicesService;
  @override
  State<CommunityRoutePicker> createState() => _CommunityRoutePickerState();
}

class _CommunityRoutePickerState extends State<CommunityRoutePicker> {
  late final CommunityRouteChoices _service =
      widget.choicesService ?? CommunityRouteChoices();
  List<CommunityRouteChoice> _choices = [];
  CommunityRouteChoice? _selected;
  bool _loading = true;
  String? _error;
  String _query = '';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final choices = await _service.loadChoices();
      if (!mounted) return;
      if (!_service.isCurrentOwner) throw StateError("Account changed");
      setState(() {
        _choices = choices;
        _loading = false;
        _selected = choices
            .where(
              (choice) =>
                  choice.route.localId == widget.selected?.localId &&
                  (widget.source == null || choice.source == widget.source),
            )
            .firstOrNull;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _choices = [];
          _selected = null;
          _error = _service.isCurrentOwner
              ? 'Не удалось загрузить маршруты и тренировки. Повторите попытку.'
              : 'Аккаунт изменился. Откройте выбор маршрута заново.';
        });
      }
    }
  }

  String _title(SavedRoute route) =>
      route.title.trim().isEmpty ? 'Без названия' : route.title;
  String _details(BuildContext context, SavedRoute route) {
    final date = route.recordedDateTime;
    final stamp = date == null
        ? 'Дата не указана'
        : '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
    return '${route.distanceKm.toStringAsFixed(1)} км · ${route.activityType.label} · $stamp';
  }

  Widget _list(CommunityRouteSource source) {
    final items = _choices
        .where(
          (choice) =>
              choice.source == source &&
              _title(choice.route)
                  .toLowerCase()
                  .contains(_query.trim().toLowerCase()),
        )
        .toList();
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _query.trim().isNotEmpty
                ? 'Ничего не найдено. Попробуйте другое название.'
                : source == CommunityRouteSource.saved
                ? 'Сохранённых маршрутов пока нет'
                : 'Тренировок пока нет',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final choice = items[index];
        return Card(
          child: ListTile(
            isThreeLine: true,
            leading: Icon(
              choice.source == CommunityRouteSource.saved
                  ? Icons.route_outlined
                  : Icons.directions_bike,
            ),
            title: Text(_title(choice.route)),
            subtitle: Text(_details(context, choice.route)),
            trailing: _selected?.key == choice.key
                ? const Icon(Icons.check_circle)
                : null,
            onTap: () {
              FocusScope.of(context).unfocus();
              setState(() => _selected = choice);
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Прикрепить маршрут'),
          leading: IconButton(
            tooltip: 'Закрыть',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Название маршрута или тренировки',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (query) => setState(() => _query = query),
              ),
            ),
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Сохранённые маршруты'),
                Tab(text: 'Тренировки'),
              ],
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: _service.isCurrentOwner ? _load : null,
                              child: const Text('Повторить'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : TabBarView(
                      children: [
                        _list(CommunityRouteSource.saved),
                        _list(CommunityRouteSource.workout),
                      ],
                    ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              12 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_selected != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Выбрано: ${_title(_selected!.route)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                FilledButton(
                  onPressed: _selected == null || !_service.isCurrentOwner
                      ? null
                      : () {
                          if (!_service.isCurrentOwner) {
                            setState(() {
                              _selected = null;
                              _error = 'Аккаунт изменился. Откройте выбор маршрута заново.';
                            });
                            return;
                          }
                          final selected = _selected!;
                          widget.onSelectedChoice?.call(selected);
                          Navigator.pop(context, selected.route);
                        },
                  child: const Text('Прикрепить'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
