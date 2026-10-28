import 'package:flutter/material.dart';

import '../data/trail_appearance.dart';
import '../data/user_scope.dart';
import '../models/activity_type.dart';
import '../models/live_trail_style.dart';
import '../services/owned_trail_style_service.dart';
import '../widgets/activity_trail_layer.dart';

class OwnedTrailStyleScreen extends StatefulWidget {
  const OwnedTrailStyleScreen({super.key});
  @override
  State<OwnedTrailStyleScreen> createState() => _OwnedTrailStyleScreenState();
}

class _OwnedTrailStyleScreenState extends State<OwnedTrailStyleScreen> {
  final _service = OwnedTrailStyleService.instance;
  final _owner = UserScope.currentUserId();
  final _preview = TrailAppearance();
  LiveTrailStyle _choice = const LiveTrailStyle();
  bool _loading = true, _saving = false, _dirty = false, _allowPop = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _service.load();
      if (!mounted || _owner != UserScope.currentUserId()) return;
      setState(() {
        _choice = _service.style;
        _loading = false;
      });
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'Не удалось прочитать оформление. Попробуйте открыть экран ещё раз.';
        });
    }
  }

  void _change(LiveTrailStyle next) => setState(() {
    _choice = next;
    _dirty = true;
  });
  Future<void> _save() async {
    if (_owner == null || _owner != UserScope.currentUserId()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _service.save(_choice);
      if (mounted && _owner == UserScope.currentUserId())
        setState(() => _dirty = false);
    } catch (_) {
      if (mounted)
        setState(
          () => _error = 'Не удалось сохранить. Ваш выбор остался на экране, попробуйте ещё раз.',
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _close() async {
    if (_saving) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Изменения не сохранены'),
          content: const Text('Вернуться без сохранения нового оформления?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Продолжить настройку'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Не сохранять'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final changedOwner = _owner == null || _owner != UserScope.currentUserId();
    _preview.style = _choice.style;
    _preview.colorIndex = _choice.colorIndex;
    _preview.size = _choice.size;
    _preview.spacing = _choice.spacing;
    _preview.opacity = _choice.opacity;
    return PopScope(
      canPop: _allowPop || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Мой шлейф'),
          leading: BackButton(onPressed: _close),
        ),
        body: changedOwner
            ? const Center(
                child: Text('Откройте настройки из своего аккаунта.'),
              )
            : _loading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    TrailStylePreview(
                      appearance: _preview,
                      activity: ActivityType.hiking,
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          const Text(
                            'Вы выбираете свой шлейф — друзья видят этот рисунок, цвет, размер и плотность. Для этого обоим нужно обновлённое приложение.',
                          ),
                          ListenableBuilder(
                            listenable: _service,
                            builder: (_, _) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                _service.pending
                                    ? 'Сохранено на телефоне. Друзья увидят выбор после синхронизации с интернетом.'
                                    : 'Оформление синхронизируется с вашим аккаунтом.',
                              ),
                            ),
                          ),
                          if (_error != null)
                            Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Мой шлейф на карте'),
                            subtitle: const Text(
                              'Скрывает только шлейф. Передача вашей позиции настраивается отдельно в приватности.',
                            ),
                            value: _choice.enabled,
                            onChanged: _saving
                                ? null
                                : (v) => _change(_choice.copyWith(enabled: v)),
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final style in TrailStyle.values)
                                ChoiceChip(
                                  label: Text(style.label),
                                  selected: _choice.style == style,
                                  onSelected: _saving
                                      ? null
                                      : (_) => _change(
                                          _choice.copyWith(style: style),
                                        ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              for (
                                var i = 0;
                                i < TrailAppearance.colors.length;
                                i++
                              )
                                Semantics(
                                  button: true,
                                  selected: i == _choice.colorIndex,
                                  label: 'Цвет шлейфа ${i + 1}',
                                  child: InkWell(
                                    onTap: _saving
                                        ? null
                                        : () => _change(
                                            _choice.copyWith(colorIndex: i),
                                          ),
                                    customBorder: const CircleBorder(),
                                    child: CircleAvatar(
                                      radius: 22,
                                      backgroundColor:
                                          TrailAppearance.colors[i],
                                      child: i == _choice.colorIndex
                                          ? const Icon(
                                              Icons.check,
                                              color: Colors.white,
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          Text('Размер · ${_choice.size.round()}'),
                          Slider(
                            value: _choice.size,
                            min: 6,
                            max: 20,
                            divisions: 14,
                            onChanged: _saving
                                ? null
                                : (v) => _change(_choice.copyWith(size: v)),
                          ),
                          Text(
                            'Расстояние между отпечатками · ${_choice.spacing.round()}',
                          ),
                          Slider(
                            value: _choice.spacing,
                            min: 16,
                            max: 64,
                            divisions: 12,
                            onChanged: _saving
                                ? null
                                : (v) => _change(_choice.copyWith(spacing: v)),
                          ),
                          Text(
                            'Непрозрачность · ${(_choice.opacity * 100).round()}%',
                          ),
                          Slider(
                            value: _choice.opacity,
                            min: .25,
                            max: 1,
                            divisions: 15,
                            onChanged: _saving
                                ? null
                                : (v) => _change(_choice.copyWith(opacity: v)),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: FilledButton.icon(
                        onPressed: _saving || !_dirty ? null : _save,
                        icon: Icon(_saving ? Icons.hourglass_top : Icons.check),
                        label: Text(
                          _saving ? 'Сохраняем…' : 'Сохранить мой шлейф',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
