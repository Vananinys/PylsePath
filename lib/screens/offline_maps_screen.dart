import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../services/offline_maps_service.dart';
import '../config.dart';
import '../data/navigation_preferences.dart';

/// Управление офлайн-картами: статистика кэша, загрузка области вокруг
/// текущей позиции, очистка.
class OfflineMapsScreen extends StatefulWidget {
  final List<LatLng> routePoints;
  final LatLngWithLabel? currentLocation;

  const OfflineMapsScreen({
    super.key,
    this.currentLocation,
    this.routePoints = const [],
  });

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

/// Точка для скачивания области: координаты + подпись в UI.
class LatLngWithLabel {
  final double latitude;
  final double longitude;
  final String label;

  const LatLngWithLabel({
    required this.latitude,
    required this.longitude,
    this.label = 'Моя геопозиция',
  });
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  bool _loading = true;
  bool _available = false;
  int? _tileCount;
  double? _sizeMb;

  // Состояние загрузки области
  bool _downloading = false;
  int _cachedTiles = 0;
  int _failedTiles = 0;
  int _maxTiles = 0;
  double _cachedSizeMb = 0;
  double _radiusKm = 5;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    // Статистика имеет смысл только после готовности фонового бэкенда.
    await OfflineMapsService.ensureInitialised();
    _available = OfflineMapsService.isAvailable;
    final stats = await OfflineMapsService.stats();
    if (!mounted) return;
    setState(() {
      _tileCount = stats?.$1;
      _sizeMb = stats?.$2;
      _loading = false;
    });
  }

  Future<void> _startDownload() async {
    final location = widget.currentLocation;
    if (location == null && widget.routePoints.length < 2) {
      _showMessage('Не удалось определить геопозицию');
      return;
    }

    setState(() {
      _downloading = true;
      _cachedTiles = 0;
      _failedTiles = 0;
      _maxTiles = 0;
      _cachedSizeMb = 0;
    });

    try {
      await for (final progress
          in widget.routePoints.length >= 2
              ? OfflineMapsService.downloadRoute(widget.routePoints)
              : OfflineMapsService.downloadAround(
                  LatLng(location!.latitude, location.longitude),
                  radiusKm: _radiusKm,
                )) {
        if (!mounted) return;
        setState(() {
          _maxTiles = progress.maxTiles;
          _cachedTiles = progress.cachedTiles;
          _failedTiles = progress.failedTiles;
          _cachedSizeMb = progress.cachedSize / 1024 / 1024;
        });
      }
      if (!mounted) return;
      // Честный итог: поток мог завершиться с нулём сохранённых тайлов
      // (например, все запросы отбиты сервером).
      if (_cachedTiles > 0) {
        _showMessage(
          _failedTiles > 0
              ? 'Готово: $_cachedTiles тайлов офлайн '
                    '($_failedTiles не скачались)'
              : 'Область скачана — она будет доступна офлайн',
        );
      } else {
        _showMessage(
          'Не удалось скачать тайлы. Проверьте интернет '
          'и попробуйте ещё раз',
        );
      }
    } catch (error) {
      if (!mounted) return;
      _showMessage(
        'Не удалось загрузить карту. Проверьте соединение и свободное место на телефоне, затем повторите.',
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
      await _refresh();
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Очистить офлайн-карты?'),
        content: const Text(
          'Все скачанные области будут удалены. '
          'Их придётся скачивать заново.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await OfflineMapsService.clearCache();
    _showMessage('Кэш офлайн-карт очищен');
    await _refresh();
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Офлайн-карты'), centerTitle: true),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!_available) ...[
                  const _UnavailableCard(),
                ] else ...[
                  _buildStatsCard(),
                  SwitchListTile(
                    title: const Text('Только сохранённые тайлы'),
                    subtitle: const Text(
                      'Основная карта не загружает тайлы из сети. Пустые участки означают, что их нет в кэше. Трек и GPS доступны.',
                    ),
                    value: NavigationPreferences.instance.cachedMapOnly,
                    onChanged: _downloading
                        ? null
                        : (value) async {
                            await NavigationPreferences.instance.update(
                              cachedOnly: value,
                            );
                            if (mounted) setState(() {});
                          },
                  ),
                  const ListTile(
                    leading: Icon(Icons.route),
                    title: Text('Маршруты без интернета'),
                    subtitle: Text(
                      'Сохраните маршрут заранее: линия и подсказки поворотов останутся на устройстве. Новое построение по дорогам требует сети.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildDownloadCard(),
                  const SizedBox(height: 16),
                  _buildClearButton(),
                ],
              ],
            ),
    );
  }

  Widget _buildStatsCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.deepOrange.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.map_outlined, color: Colors.deepOrange),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Скачанные тайлы',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _tileCount == null
                        ? 'Кэш пуст'
                        : '$_tileCount тайлов · '
                              '${(_sizeMb ?? 0).toStringAsFixed(1)} МБ',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadCard() {
    final location = widget.currentLocation;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Скачать область',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              AppConfig.offlineTileUrl.isEmpty
                  ? 'Загрузка районов недоступна: не подключён источник карт с разрешением на офлайн-скачивание. Доступен кэш просмотренных тайлов.'
                  : 'Область радиусом ${_radiusKm.round()} км вокруг текущей позиции, масштабы 13–16.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (AppConfig.offlineTileUrl.isNotEmpty && !_downloading)
              Wrap(
                spacing: 8,
                children: [
                  for (final radius in [1.0, 3.0, 5.0])
                    ChoiceChip(
                      label: Text('${radius.round()} км'),
                      selected: _radiusKm == radius,
                      onSelected: (_) => setState(() => _radiusKm = radius),
                    ),
                ],
              ),
            if (_downloading) ...[
              LinearProgressIndicator(
                value: _maxTiles > 0 ? _cachedTiles / _maxTiles : null,
              ),
              const SizedBox(height: 8),
              Text(
                _maxTiles > 0
                    ? '$_cachedTiles из $_maxTiles тайлов · '
                          '${_cachedSizeMb.toStringAsFixed(1)} МБ'
                          ' · ошибок: $_failedTiles'
                    : 'Подготовка...',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ] else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed:
                      (location == null && widget.routePoints.length < 2) ||
                          AppConfig.offlineTileUrl.isEmpty
                      ? null
                      : _startDownload,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    widget.routePoints.length >= 2
                        ? 'Скачать карты всего маршрута (13–16)'
                        : location == null
                        ? 'Геопозиция не определена'
                        : 'Скачать область вокруг меня',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildClearButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _downloading ? null : _clearCache,
        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
        label: const Text(
          'Очистить кэш офлайн-карт',
          style: TextStyle(color: Colors.redAccent),
        ),
      ),
    );
  }
}

class _UnavailableCard extends StatelessWidget {
  const _UnavailableCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(
              Icons.cloud_off,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            SizedBox(height: 8),
            Text(
              'Офлайн-карты недоступны на этом устройстве',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 4),
            Text(
              'Карта продолжит работать через интернет.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
