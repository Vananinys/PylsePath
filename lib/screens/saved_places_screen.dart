import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../data/saved_places_repository.dart';
import '../models/saved_place.dart';

Future<SavedPlace?> showSavedPlaceEditor(
  BuildContext context, {
  required LatLng point,
  SavedPlace? existing,
}) => showDialog<SavedPlace>(
  context: context,
  builder: (_) => _PlaceEditor(point: point, existing: existing),
);

class SavedPlacesScreen extends StatefulWidget {
  const SavedPlacesScreen({super.key, this.repository, this.locate});
  final SavedPlacesRepository? repository;
  final Future<LatLng> Function()? locate;
  @override
  State<SavedPlacesScreen> createState() => _SavedPlacesScreenState();
}

class _SavedPlacesScreenState extends State<SavedPlacesScreen> {
  late final _repository = widget.repository ?? SavedPlacesRepository();
  List<SavedPlace> _places = [];
  bool _loading = true, _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final places = await _repository.load();
      if (mounted) {
        setState(() {
          _places = places;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          if (!_repository.isCurrent) _places = [];
          _error = 'Не удалось прочитать места. Данные не изменены.';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([SavedPlace? place]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!_repository.isCurrent) throw StateError('Account changed');
      final point = place?.point ?? await widget.locate!();
      if (!mounted || !_repository.isCurrent) return;
      final updated = await showSavedPlaceEditor(
        context,
        point: point,
        existing: place,
      );
      if (updated == null || !mounted) return;
      await _repository.save(updated);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось сохранить место. Проверьте GPS, аккаунт и свободное место на телефоне.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(SavedPlace place) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить место?'),
        content: Text(place.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _repository.remove(place.id);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось удалить место. Попробуйте ещё раз.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Мои места')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Личные точки этого аккаунта хранятся на устройстве. Нажмите на место, чтобы построить маршрут. Для маршрута по дорогам нужен интернет.',
                ),
              ),
              Expanded(
                child: _error != null
                    ? Center(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              TextButton(
                                onPressed: _load,
                                child: const Text('Повторить'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _places.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Пока нет сохранённых мест.\nСохраните свою позицию или удерживайте нужную точку на карте.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 100),
                        itemCount: _places.length,
                        itemBuilder: (context, index) {
                          final place = _places[index];
                          return ListTile(
                            key: ValueKey(place.id),
                            leading: Icon(place.kind.icon),
                            title: Text(
                              place.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${place.kind.label} · ${place.latitude.toStringAsFixed(5)}, ${place.longitude.toStringAsFixed(5)}',
                            ),
                            onTap: _busy
                                ? null
                                : () {
                                    if (_repository.isCurrent) {
                                      Navigator.pop(context, place);
                                    } else {
                                      _load();
                                    }
                                  },
                            trailing: PopupMenuButton<String>(
                              tooltip: 'Действия с местом',
                              enabled: !_busy,
                              onSelected: (action) {
                                if (action == 'edit') {
                                  _edit(place);
                                } else {
                                  _remove(place);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text('Изменить'),
                                ),
                                PopupMenuItem(
                                  value: 'remove',
                                  child: Text('Удалить место'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
    floatingActionButton: widget.locate == null
        ? null
        : FloatingActionButton(
            tooltip: 'Сохранить мою позицию',
            onPressed: _busy || _loading || _error != null
                ? null
                : () => _edit(),
            child: const Icon(Icons.add_location_alt_outlined),
          ),
  );
}

class _PlaceEditor extends StatefulWidget {
  const _PlaceEditor({required this.point, this.existing});
  final LatLng point;
  final SavedPlace? existing;
  @override
  State<_PlaceEditor> createState() => _PlaceEditorState();
}

class _PlaceEditorState extends State<_PlaceEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late SavedPlaceKind _kind = widget.existing?.kind ?? SavedPlaceKind.other;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? 'Сохранить место' : 'Изменить место'),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _name,
              maxLength: 80,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Название',
                hintText: 'Например, любимый старт',
              ),
              validator: (value) {
                final name = (value ?? '').trim();
                if (name.isEmpty) return 'Введите название';
                if (name.length > 80) return 'Название слишком длинное';
                return null;
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SavedPlaceKind>(
              initialValue: _kind,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Значок'),
              items: [
                for (final kind in SavedPlaceKind.values)
                  DropdownMenuItem(
                    value: kind,
                    child: Text(kind.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _kind = value;
                    if (_name.text.trim().isEmpty &&
                        value != SavedPlaceKind.other) {
                      _name.text = value.label;
                    }
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            Text(
              '${widget.point.latitude.toStringAsFixed(5)}, ${widget.point.longitude.toStringAsFixed(5)}',
            ),
            const Text(
              'Только на этом устройстве. Не публикуется на общей карте.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState?.validate() != true) return;
          Navigator.pop(
            context,
            SavedPlace(
              id: widget.existing?.id,
              name: _name.text,
              latitude: widget.point.latitude,
              longitude: widget.point.longitude,
              kind: _kind,
            ),
          );
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}
