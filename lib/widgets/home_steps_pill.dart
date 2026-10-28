import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/daily_activity_screen.dart';
import '../services/daily_activity_service.dart';
import '../state/profile_provider.dart';

class HomeStepsPreference extends ValueNotifier<bool> {
  HomeStepsPreference._() : super(true) {
    _load();
  }
  static final instance = HomeStepsPreference._();
  static const _key = 'home_steps_visible';
  Future<void> _load() async {
    value = (await SharedPreferences.getInstance()).getBool(_key) ?? true;
  }

  Future<void> save(bool visible) async {
    await (await SharedPreferences.getInstance()).setBool(_key, visible);
    value = visible;
  }
}

class HomeStepsSetting extends StatelessWidget {
  const HomeStepsSetting({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: HomeStepsPreference.instance,
    builder: (context, visible, _) => SwitchListTile(
      secondary: const Icon(Icons.directions_walk_rounded),
      title: const Text('Шаги рядом с погодой'),
      subtitle: const Text(
        'Показывать на главном экране. Сам подсчёт выключается в разделе шагомера.',
      ),
      value: visible,
      onChanged: HomeStepsPreference.instance.save,
    ),
  );
}

class HomeStepsPill extends StatefulWidget {
  const HomeStepsPill({super.key});
  @override
  State<HomeStepsPill> createState() => _HomeStepsPillState();
}

class _HomeStepsPillState extends State<HomeStepsPill> {
  bool _watching = false;
  void _sync() {
    final visible = HomeStepsPreference.instance.value;
    if (visible == _watching) return;
    _watching = visible;
    if (visible) {
      DailyActivityService.instance.beginLiveUpdates();
    } else {
      DailyActivityService.instance.endLiveUpdates();
    }
  }

  @override
  void initState() {
    super.initState();
    HomeStepsPreference.instance.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    HomeStepsPreference.instance.removeListener(_sync);
    if (_watching) DailyActivityService.instance.endLiveUpdates();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: HomeStepsPreference.instance,
    builder: (context, visible, _) => !visible
        ? const SizedBox.shrink()
        : Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ListenableBuilder(
                listenable: DailyActivityService.instance,
                builder: (context, _) {
                  final service = DailyActivityService.instance;
                  final label = !service.ready
                      ? 'Шаги…'
                      : service.enabled
                      ? '${service.steps}'
                      : 'Включить';
                  return Tooltip(
                    message: 'Шаги за сегодня · открыть шагомер',
                    child: Material(
                      color: Theme.of(context).colorScheme.surface
                          .withValues(alpha: .95),
                      borderRadius: BorderRadius.circular(24),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DailyActivityScreen(
                              weightKg: context
                                  .read<ProfileProvider>()
                                  .profile
                                  .weightKg,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.directions_walk_rounded,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
  );
}
