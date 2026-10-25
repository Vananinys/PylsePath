import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../config.dart';

/// Офлайн-карты на базе FMTC (flutter_map_tile_caching, ObjectBox-бэкенд).
///
/// Тайлы просмотренных областей кэшируются автоматически; отдельно можно
/// скачать область вокруг текущей позиции (например, перед выездом за сеть).
/// При сбое инициализации (web, нет места) сервис честно сообщит
/// [isAvailable] = false — карта продолжит работать по сети.
class OfflineMapsService {
  const OfflineMapsService._();

  static const String storeName = 'pulsepath_main';
  static String get routeTileUrl => AppConfig.offlineTileUrl.isEmpty
      ? 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
      : AppConfig.offlineTileUrl;

  /// Масштабы для предзагрузки: 13 (район) — 16 (улицы). Больше — больше тайлов.
  static const int _minZoom = 13;
  static const int _maxZoom = 16;

  static bool _initialised = false;
  static bool get isAvailable => _initialised;

  /// Единственный future инициализации: экраны дожидаются его через
  /// [ensureInitialised], чтобы не столкнуться с «бэкенд ещё не открыт».
  static Future<void>? _initFuture;

  static FMTCStore get _store => const FMTCStore(storeName);

  /// Инициализация бэкенда. Вызывается из main() БЕЗ await: ObjectBox-база
  /// может открываться заметное время, и блокировать ей первый кадр нельзя.
  /// Карта до готовности работает по сети, после — переключается на кэш.
  // Исправлено: теперь инициализация обрабатывает ошибки вместо игнорирования
  static Future<void> initialise() async {
    try {
      await ensureInitialised();
    } catch (error) {
      debugPrint('[OfflineMaps] Инициализация провалена: $error');
    }
  }

  /// Гарантирует завершение инициализации (идемпотентно).
  static Future<void> ensureInitialised() {
    return _initFuture ??= () async {
      try {
        await FMTCObjectBoxBackend().initialise();
        if (!await _store.manage.ready) await _store.manage.create();
        _initialised = true;
        debugPrint('[OfflineMaps] FMTC инициализирован');
      } catch (error) {
        debugPrint('[OfflineMaps] FMTC недоступен: $error');
      }
    }();
  }

  /// Провайдер тайлов с кэшем для [TileLayer], либо null без инициализации.
  static FMTCTileProvider? tileProvider({bool offlineOnly = false}) {
    if (!_initialised) return null;
    return _store.getTileProvider(
      settings: FMTCTileProviderSettings(
        behavior: offlineOnly
            ? CacheBehavior.cacheOnly
            : CacheBehavior.cacheFirst,
      ),
    );
  }

  /// Кэш готов (хранилище создано)?
  static Future<bool> isStoreReady() async {
    if (!_initialised) return false;
    try {
      return await _store.manage.ready;
    } catch (_) {
      return false;
    }
  }

  /// Статистика кэша: (количество тайлов, размер в МБ). null — недоступно.
  static Future<(int, double)?> stats() async {
    if (!await isStoreReady()) return null;
    try {
      // FMTC reports tile payload size in KiB, so one conversion yields MiB.
      return (await _store.stats.length, await _store.stats.size / 1024);
    } catch (_) {
      return null;
    }
  }

  /// Скачивает область вокруг [center] радиусом [radiusKm].
  ///
  /// Возвращает поток прогресса (cachedTiles / maxTiles). Кидает исключения
  /// FMTC — вызывающий код показывает их пользователю.
  static Stream<DownloadProgress> downloadAround(
    LatLng center, {
    double radiusKm = 5,
  }) async* {
    if (AppConfig.offlineTileUrl.isEmpty) {
      throw StateError(
        'Настройте OFFLINE_TILE_URL: публичный сервер OSM не используется для массового скачивания.',
      );
    }
    // Дожидаемся фоновую инициализацию: экран мог открыться раньше её конца.
    await ensureInitialised();
    if (!_initialised) {
      throw StateError('Офлайн-карты недоступны на этом устройстве');
    }
    if (!await _store.manage.ready) {
      await _store.manage.create();
    }

    // Грубая конверсия км в градусы bbox (на широте центра — достаточно).
    final latDelta = radiusKm / 111.0;
    final cosLat = math.cos(center.latitude * math.pi / 180.0).abs();
    final lonDelta = radiusKm / (111.0 * cosLat.clamp(0.1, 1.0));
    final bounds = LatLngBounds(
      LatLng(center.latitude - latDelta, center.longitude - lonDelta),
      LatLng(center.latitude + latDelta, center.longitude + lonDelta),
    );

    // User-Agent обязателен: OpenStreetMap блокирует массовую загрузку
    // тайлов без него (403 на каждый запрос — «скачивание» завершалось
    // с нулём сохранённых тайлов).
    final tileLayer = TileLayer(
      urlTemplate: AppConfig.offlineTileUrl,
      userAgentPackageName: 'com.pulsepath.app',
    );
    final region = RectangleRegion(
      bounds,
    ).toDownloadable(minZoom: _minZoom, maxZoom: _maxZoom, options: tileLayer);

    yield* _store.download.startForeground(region: region);
  }

  /// Полностью очищает кэш офлайн-карт.
  static Future<void> clearCache() async {
    if (!await isStoreReady()) return;
    await _store.manage.delete();
    await _store.manage.create();
  }
}
