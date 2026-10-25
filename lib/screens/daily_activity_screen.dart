import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/daily_activity_service.dart';

class DailyActivityScreen extends StatefulWidget {
  const DailyActivityScreen({super.key, required this.weightKg});
  final double weightKg;
  @override
  State<DailyActivityScreen> createState() => _DailyActivityScreenState();
}

class _DailyActivityScreenState extends State<DailyActivityScreen> {
  double get weightKg => widget.weightKg;
  @override
  void initState() {
    super.initState();
    DailyActivityService.instance.beginLiveUpdates();
  }

  @override
  void dispose() {
    DailyActivityService.instance.endLiveUpdates();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = DailyActivityService.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Активность за день'),
        actions: [
          IconButton(
            tooltip: 'Обновить шаги',
            onPressed: service.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Сегодня', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Text(
              '${service.steps}',
              style: const TextStyle(fontSize: 54, fontWeight: FontWeight.bold),
            ),
            Text('шагов из ${service.goal}'),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: service.progress,
              minHeight: 10,
              borderRadius: BorderRadius.circular(8),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 20,
              runSpacing: 12,
              children: [
                _metric(
                  Icons.route,
                  '${service.distanceKm.toStringAsFixed(2)} км',
                  'примерно по шагам',
                ),
                _metric(
                  Icons.local_fire_department_outlined,
                  '${service.activeCalories(weightKg).round()} ккал',
                  'активные · оценка',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Оценка для веса ${weightKg.toStringAsFixed(0)} кг. Вес меняется в профиле. Калории от шагов не складываются с тренировками: они могут учитывать одну прогулку.',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Считать шаги'),
              subtitle: Text(
                !service.ready
                    ? 'Подготовка…'
                    : service.available
                    ? service.busy
                          ? 'Сохраняем настройки…'
                          : 'В фоне через Google Play · без GPS'
                    : 'Нужны доступные сервисы Google Play',
              ),
              value: service.enabled,
              onChanged: service.ready && service.available && !service.busy
                  ? service.setEnabled
                  : null,
            ),
            if (service.notice != null) ...[
              Text(
                service.notice!,
                style: const TextStyle(color: Colors.deepOrange),
              ),
              const TextButton(
                onPressed: openAppSettings,
                child: Text('Настройки телефона'),
              ),
              if (!service.available)
                TextButton(
                  onPressed: service.resolveServices,
                  child: const Text('Проверить сервисы Google Play'),
                ),
              TextButton(
                onPressed: service.refresh,
                child: const Text('Повторить обновление'),
              ),
            ],
            const Text(
              'Счёт начинается после включения и продолжается при закрытом приложении через сервисы Google Play. Итоги обновляются с задержкой и восстанавливаются при открытии. Интернет и GPS для шагов не нужны.',
            ),
            if (service.lastSyncedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Обновлено: ${MaterialLocalizations.of(context).formatShortDate(service.lastSyncedAt!)} '
                  '${TimeOfDay.fromDateTime(service.lastSyncedAt!).format(context)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                service.cloudPending
                    ? 'Сохранено на телефоне · ожидает отправки в облако'
                    : service.cloudSyncedAt != null
                    ? 'Резервная копия в облаке сохранена'
                    : 'Сохранено на телефоне · облачная копия при подключении',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const Divider(height: 32),
            Text(
              'Дневная цель · ${service.goal} шагов',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Slider(
              value: service.goal.toDouble().clamp(1000, 20000),
              min: 1000,
              max: 20000,
              divisions: 19,
              onChanged: (value) => service.configure(target: value.round()),
            ),
            Text('Длина шага · ${(service.strideMeters * 100).round()} см'),
            Slider(
              value: service.strideMeters,
              min: .4,
              max: 1.2,
              divisions: 80,
              onChanged: (value) => service.configure(stride: value),
            ),
            const Text(
              'Для точной настройки пройдите известные 100 м и разделите дистанцию на число шагов.',
            ),
            if (service.history.isNotEmpty) ...[
              const Divider(height: 32),
              Text(
                'Последние дни',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final day
                  in (service.history.keys.toList()..sort()).reversed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(day),
                  trailing: Text('${service.history[day]} шагов'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metric(IconData icon, String value, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: Colors.deepOrange),
      Text(
        value,
        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
      ),
      Text(label),
    ],
  );
}
