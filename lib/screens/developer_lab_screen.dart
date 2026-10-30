import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/activity_type.dart';
import '../models/live_trail_style.dart';
import '../data/user_scope.dart';
import '../services/lab_access.dart';
import '../widgets/activity_trail_layer.dart';
import 'owner_screen.dart';
import 'events_screen.dart';

/// Isolated synthetic map. Never injects GPS into the recording/publishing stack.
class DeveloperLabScreen extends StatefulWidget {
  const DeveloperLabScreen({super.key, this.authorize});
  final Future<bool> Function()? authorize;
  @override
  State<DeveloperLabScreen> createState() => _DeveloperLabScreenState();
}

class _DeveloperLabScreenState extends State<DeveloperLabScreen>
    with WidgetsBindingObserver {
  final _owner = UserScope.currentUserId();
  bool _allowed = false,
      _isOwner = false,
      _checked = false,
      _playing = false,
      _gps = true,
      _online = true,
      _offRoute = false,
      _finished = false;
  double _progress = 0, _speed = 15;
  MotionEffect _effect = MotionEffect.confetti;
  ActivityType _activity = ActivityType.cycling;
  Timer? _timer;
  static final route = List<LatLng>.generate(
    100,
    (i) => LatLng(56.48 + math.sin(i / 18) * .001, 84.95 + i * .000045),
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authorize();
  }

  Future<void> _authorize() async {
    var allowed = false;
    try {
      if (widget.authorize != null) {
        allowed = await widget.authorize!();
      } else {
        final access = await LabAccess.check();
        allowed = access['can_simulate'] == true;
        _isOwner = access['is_owner'] == true;
      }
    } catch (_) {}
    if (mounted)
      setState(() {
        _allowed = allowed && _owner == UserScope.currentUserId();
        _checked = true;
      });
  }

  void _play() {
    _timer?.cancel();
    setState(() {
      _playing = !_playing;
      _finished = false;
    });
    if (!_playing) return;
    _timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted || _owner != UserScope.currentUserId()) {
        timer.cancel();
        return;
      }
      if (!_gps) return;
      setState(() {
        _progress = (_progress + _speed / 36000 / .005).clamp(0, 99);
        if (_progress >= 99) {
          _playing = false;
          _finished = true;
          timer.cancel();
        }
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _timer?.cancel();
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!_allowed || _owner != UserScope.currentUserId())
      return Scaffold(
        appBar: AppBar(title: const Text('Лаборатория')),
        body: const Center(
          child: Text('Требуется подтверждённый доступ владельца'),
        ),
      );
    final index = _progress.floor().clamp(0, 98), t = _progress - index;
    final a = route[index], b = route[index + 1];
    final point = LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
    final points = [...route.take(index + 1), point];
    final color = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Лаборатория PulsePath')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'СИМУЛЯЦИЯ · только на этом экране',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const Text(
            'Демонстрационные координаты не записываются в историю, не отправляются друзьям и не дают XP. GPS и сеть ниже — моделируемые состояния.',
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: SizedBox(
              height: 300,
              child: FlutterMap(
                options: const MapOptions(
                  initialCenter: LatLng(56.4804, 84.9522),
                  initialZoom: 16,
                ),
                children: [
                  const Positioned.fill(
                    child: ColoredBox(color: Color(0xFF14232B)),
                  ),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: route,
                        strokeWidth: 18,
                        color: const Color(0xFF30464F),
                      ),
                      Polyline(
                        points: route,
                        strokeWidth: 2,
                        color: Colors.white24,
                      ),
                    ],
                  ),
                  ActivityTrailLayer(
                    preview: true,
                    segments: [points],
                    activity: _activity,
                    live: true,
                    liveAppearance: LiveTrailStyle(
                      effect: _effect,
                      enabled: true,
                      size: 18,
                      spacing: 22,
                    ),
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: point,
                        width: 90,
                        height: 90,
                        rotate: true,
                        child: Column(
                          children: [
                            const CircleAvatar(
                              backgroundColor: Colors.white,
                              radius: 23,
                              child: Icon(
                                Icons.person,
                                color: Colors.teal,
                                size: 30,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${_gps && _playing ? _speed.round() : 0} км/ч',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: color.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(
                    !_gps
                        ? Icons.gps_off
                        : _offRoute
                        ? Icons.wrong_location
                        : Icons.turn_right,
                    size: 36,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _finished
                          ? 'Поездка завершена · тестовые данные сброшены при выходе'
                          : !_gps
                          ? 'GPS потерян · положение удерживается'
                          : _offRoute
                          ? (_online
                                ? 'Уход с маршрута · проверка предупреждения'
                                : 'Уход с маршрута · пересчёт требует интернета')
                          : 'Через 120 м направо',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _play,
                  icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  label: Text(_playing ? 'Пауза' : 'Начать симуляцию'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () {
                  _timer?.cancel();
                  setState(() {
                    _playing = false;
                    _finished = true;
                  });
                },
                child: const Text('Финиш'),
              ),
            ],
          ),
          Slider(
            value: _progress,
            min: 0,
            max: 99,
            onChanged: (v) => setState(() => _progress = v),
          ),
          Text('Скорость: ${_speed.round()} км/ч'),
          Slider(
            value: _speed,
            min: 3,
            max: 60,
            onChanged: (v) => setState(() => _speed = v),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final effect in MotionEffect.values)
                ChoiceChip(
                  label: Text(effect.label),
                  selected: _effect == effect,
                  onSelected: (_) => setState(() => _effect = effect),
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final item in {
                ActivityType.hiking: 'Пешком',
                ActivityType.cycling: 'Велосипед',
                ActivityType.driving: 'Авто',
              }.entries)
                ChoiceChip(
                  label: Text(item.value),
                  selected: _activity == item.key,
                  onSelected: (_) => setState(() => _activity = item.key),
                ),
            ],
          ),
          SwitchListTile(
            title: const Text('GPS доступен'),
            value: _gps,
            onChanged: (v) => setState(() => _gps = v),
          ),
          SwitchListTile(
            title: const Text('Сеть доступна'),
            value: _online,
            onChanged: (v) => setState(() => _online = v),
          ),
          SwitchListTile(
            title: const Text('Отклонение от маршрута'),
            value: _offRoute,
            onChanged: (v) => setState(() => _offRoute = v),
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () {
                  _timer?.cancel();
                  setState(() {
                    _progress = 0;
                    _playing = false;
                    _finished = false;
                  });
                },
                child: const Text('Сбросить сценарий'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const EventsScreen()),
                ),
                child: const Text('Реальные события'),
              ),
              if (_isOwner)
                OutlinedButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const OwnerScreen()),
                  ),
                  child: const Text('Управление владельца'),
                ),
            ],
          ),
          const Text(
            'События и управление владельца работают с настоящими данными и прежними серверными правами. Лаборатория не проверяет Android-фон, батарею или реальную точность GPS.',
          ),
        ],
      ),
    );
  }
}
