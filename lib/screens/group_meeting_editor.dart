import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/group_coordination.dart';
import '../data/navigation_preferences.dart';
import '../services/offline_maps_service.dart';

class GroupMeetingEditor extends StatefulWidget {
  const GroupMeetingEditor({
    super.key,
    required this.initial,
    this.center,
    this.pointOnly = false,
    this.stopProposal = false,
  });
  final GroupMeetPlan initial;
  final LatLng? center;
  final bool pointOnly;
  final bool stopProposal;
  @override
  State<GroupMeetingEditor> createState() => _GroupMeetingEditorState();
}

class _GroupMeetingEditorState extends State<GroupMeetingEditor> {
  late final _label = TextEditingController(text: widget.initial.label);
  late LatLng? _point = widget.initial.point;
  late DateTime? _starts = widget.initial.startsAt?.toLocal();
  late GroupRideStyle _style = widget.initial.style;
  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _time() async {
    final today = DateTime.now();
    var initial = _starts ?? today;
    if (initial.isBefore(today.subtract(const Duration(days: 1))) ||
        initial.isAfter(today.add(const Duration(days: 365)))) {
      initial = today;
    }
    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today.subtract(const Duration(days: 1)),
      lastDate: today.add(const Duration(days: 365)),
    );
    if (!mounted || day == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (mounted && time != null) {
      setState(
        () => _starts = DateTime(
          day.year,
          day.month,
          day.day,
          time.hour,
          time.minute,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.stopProposal
            ? 'Где остановимся?'
            : widget.pointOnly
            ? 'Место команды'
            : 'Сбор и темп группы',
      ),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            flex: 3,
            child: FlutterMap(
              options: MapOptions(
                initialCenter:
                    _point ?? widget.center ?? const LatLng(55.75, 37.61),
                initialZoom: 14,
                onTap: (_, point) => setState(() => _point = point),
              ),
              children: [
                if (!NavigationPreferences.instance.cachedMapOnly ||
                    OfflineMapsService.isAvailable)
                  TileLayer(
                    urlTemplate: OfflineMapsService.routeTileUrl,
                    tileProvider: OfflineMapsService.tileProvider(
                      offlineOnly: NavigationPreferences.instance.cachedMapOnly,
                    ),
                    userAgentPackageName: 'com.pulsepath.app',
                  ),
                if (_point != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _point!,
                        width: 42,
                        height: 42,
                        child: const Icon(
                          Icons.location_on,
                          color: Colors.teal,
                          size: 42,
                        ),
                      ),
                    ],
                  ),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('© OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Нажмите на карту. Выбранная точка будет видна участникам комнаты.',
                  ),
                  if (_point != null)
                    Text(
                      widget.stopProposal
                          ? 'Место остановки выбрано'
                          : 'Место выбрано на карте',
                    ),
                  if (widget.stopProposal)
                    TextField(
                      controller: _label,
                      maxLength: 120,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Зачем остановимся?',
                        hintText: 'Например: вода у фонтана или отдых',
                      ),
                    ),
                  if (!widget.pointOnly) ...[
                    TextField(
                      controller: _label,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: 'Место или описание сбора',
                      ),
                    ),
                    DropdownButtonFormField<GroupRideStyle>(
                      initialValue: _style,
                      isExpanded: true,
                      items: [
                        for (final style in GroupRideStyle.values)
                          DropdownMenuItem(
                            value: style,
                            child: Text(style.label),
                          ),
                      ],
                      onChanged: (value) => setState(() => _style = value!),
                    ),
                    TextButton.icon(
                      onPressed: _time,
                      icon: const Icon(Icons.schedule),
                      label: Text(
                        _starts == null
                            ? 'Выбрать дату и время'
                            : '${_starts!.day}.${_starts!.month}.${_starts!.year} · ${TimeOfDay.fromDateTime(_starts!).format(context)}',
                      ),
                    ),
                    if (_starts != null)
                      TextButton(
                        onPressed: () => setState(() => _starts = null),
                        child: const Text('Без времени старта'),
                      ),
                  ],
                  Wrap(
                    spacing: 8,
                    children: [
                      if (_point != null && !widget.pointOnly)
                        TextButton(
                          onPressed: () => setState(() => _point = null),
                          child: const Text('Убрать точку'),
                        ),
                      FilledButton(
                        onPressed: widget.pointOnly && _point == null
                            ? null
                            : () {
                                if (_label.text.trim().length <= 120) {
                                  Navigator.pop(
                                    context,
                                    GroupMeetPlan(
                                      label: _label.text.trim(),
                                      startsAt: _starts,
                                      style: _style,
                                      point: _point,
                                    ),
                                  );
                                }
                              },
                        child: Text(
                          widget.stopProposal
                              ? 'Предложить группе'
                              : 'Подтвердить',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class GroupPointPreview extends StatelessWidget {
  const GroupPointPreview({
    super.key,
    required this.point,
    required this.label,
  });
  final LatLng point;
  final String label;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(label)),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: FlutterMap(
              options: MapOptions(initialCenter: point, initialZoom: 16),
              children: [
                if (!NavigationPreferences.instance.cachedMapOnly ||
                    OfflineMapsService.isAvailable)
                  TileLayer(
                    urlTemplate: OfflineMapsService.routeTileUrl,
                    tileProvider: OfflineMapsService.tileProvider(
                      offlineOnly: NavigationPreferences.instance.cachedMapOnly,
                    ),
                    userAgentPackageName: 'com.pulsepath.app',
                  ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: point,
                      width: 44,
                      height: 44,
                      child: const Icon(
                        Icons.location_on,
                        size: 44,
                        color: Colors.teal,
                      ),
                    ),
                  ],
                ),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('© OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: '${point.latitude}, ${point.longitude}',
                      ),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Координаты скопированы')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Скопировать координаты'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
