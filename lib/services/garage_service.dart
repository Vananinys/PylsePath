import 'package:flutter/foundation.dart';

import 'dart:convert';
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models/vehicle.dart';
import '../utils/file_reader.dart';
import 'garage_maintenance_reminders.dart';
import '../data/account_progress_cache.dart';

/// Ошибка сервиса гаража с готовым для UI текстом.
class GarageServiceException implements Exception {
  const GarageServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Работа с техникой пользователя в таблице `garage`.
///
/// Колонки: id, user_id, title, type, weight_kg, wheel_size,
/// total_distance, is_active, photo_url, created_at.
///
/// Чтение возвращает пустой список/false, чтобы экран работал и офлайн.
/// Сохранение нового транспорта при сбое бросает [GarageServiceException]
/// (UI показывает текст через SnackBar).
class GarageService {
  static const String _selectColumns =
      'id, user_id, title, type, weight_kg, wheel_size, total_distance, '
      'is_active, is_ebike, photo_url, created_at, is_public, maintenance, drivetrain, recorded_hours';

  static SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  static bool get isAvailable => _client != null;

  String? get userId => _client?.auth.currentUser?.id;

  List<Vehicle> _vehicles = [];
  final Map<String, Map<String, dynamic>> _equipmentSnapshots = {};
  bool lastFetchSucceeded = false;
  Future<List<Vehicle>> _restoreCachedGarage(String owner) async {
    final saved = await AccountProgressCache('garage_rows', owner).read();
    if (userId != owner) return const [];
    if (saved is List) {
      _vehicles = saved
          .map((r) => Vehicle.fromRow(Map<String, dynamic>.from(r as Map)))
          .toList();
    }
    return vehicles;
  }

  /// Последний полученный список техники (кэш для UI).
  List<Vehicle> get vehicles => List.unmodifiable(_vehicles);

  /// Активная техника из кэша (`is_active == true`), если загружена.
  Vehicle? get activeVehicle {
    for (final vehicle in _vehicles) {
      if (vehicle.isActive) return vehicle;
    }
    return null;
  }

  /// Техника, привязанная к текущей сессии поездки.
  ///
  /// Позволяет контроллеру навигации записать `vehicle_id` в заезд, не делая
  /// сетевой запрос в момент «Финиша».
  static Vehicle? _sessionVehicle;
  Vehicle? get sessionVehicle =>
      _sessionVehicle?.userId == userId ? _sessionVehicle : null;

  /// Привязывает технику к текущей сессии поездки.
  void bindToSession(Vehicle? vehicle) => _sessionVehicle = vehicle;

  /// Загружает список техники пользователя из `garage` (свежие сверху).
  Future<List<Vehicle>> fetchVehicles() async {
    lastFetchSucceeded = false;
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return const [];
    await _restoreCachedGarage(id);

    try {
      final rows = await client
          .from(AppConfig.garageTable)
          .select(_selectColumns)
          .eq('user_id', id)
          .order('created_at', ascending: false)
          .timeout(const Duration(seconds: 6));
      if (userId != id) return const [];
      lastFetchSucceeded = true;
      await AccountProgressCache('garage_rows', id).write(rows);
      _vehicles = rows
          .map((row) => Vehicle.fromRow(Map<String, dynamic>.from(row)))
          .toList();
      unawaited(GarageMaintenanceReminders.check(_vehicles));
      debugPrint('[GarageService] загружено техники: ${_vehicles.length}');
      return vehicles;
    } on PostgrestException catch (error) {
      debugPrint('[GarageService] fetch ${error.code}: ${error.message}');
      return _restoreCachedGarage(id);
    } catch (error) {
      debugPrint('[GarageService] fetch failed: $error');
      return _restoreCachedGarage(id);
    }
  }

  /// Возвращает активную технику пользователя (или null).
  Future<Vehicle?> fetchActiveVehicle() async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return null;

    try {
      final row = await client
          .from(AppConfig.garageTable)
          .select(_selectColumns)
          .eq('user_id', id)
          .eq('is_active', true)
          .maybeSingle()
          .timeout(const Duration(seconds: 6));
      if (row == null) return null;
      return Vehicle.fromRow(Map<String, dynamic>.from(row));
    } on PostgrestException catch (error) {
      debugPrint('[GarageService] active ${error.code}: ${error.message}');
      return (await _restoreCachedGarage(id))
          .where((v) => v.isActive)
          .firstOrNull;
    } catch (error) {
      debugPrint('[GarageService] active failed: $error');
      return (await _restoreCachedGarage(id))
          .where((v) => v.isActive)
          .firstOrNull;
    }
  }

  /// Добавляет технику чистым INSERT в `garage` (без Supabase Storage).
  ///
  /// Только текстовые/числовые поля; `photo_url` всегда null. Первая техника
  /// в гараже обычно передаётся с [isActive] = true.
  ///
  /// При сбое печатает `GARAGE INSERT ERROR: ...` и бросает
  /// [GarageServiceException] — UI показывает текст в SnackBar.
  Future<String?> addVehicle({
    required String name,
    required String transportType,
    double weightKg = 0,
    double wheelSize = 0,
    double totalDistance = 0,
    bool isActive = false,
    bool isEbike = false,
  }) async {
    try {
      final client = _client;
      final userId = client?.auth.currentUser?.id;
      if (client == null || userId == null) {
        throw const GarageServiceException(
          'Нет сессии. Войдите в аккаунт, чтобы добавить технику.',
        );
      }

      // Ключи строго совпадают с колонками таблицы `garage` (иначе PostgREST
      // вернёт PGRST204 «Could not find the '<column>' column»).
      // Исправлено: проверяем на дубликат имени техники
      final duplicates = await client
          .from(AppConfig.garageTable)
          .select('id')
          .eq('user_id', userId)
          .eq('title', name);
      if (duplicates.isNotEmpty) {
        throw const GarageServiceException(
          'Техника с таким именем уже существует в гараже.',
        );
      }

      final data = <String, dynamic>{
        'user_id': userId,
        'title': name,
        'type': transportType,
        'weight_kg': weightKg,
        'wheel_size': wheelSize,
        'total_distance': totalDistance,
        'is_active': isActive,
        'is_ebike': isEbike,
        'photo_url': null,
      };

      final inserted = await client
          .from(AppConfig.garageTable)
          .insert(data)
          .select('id')
          .single();
      final newId = (inserted['id'] ?? '').toString();
      if (newId.isEmpty) {
        throw const GarageServiceException(
          'Сервер не вернул id техники. Попробуйте ещё раз.',
        );
      }
      debugPrint('[GarageService] добавлена техника $newId (active=$isActive)');

      final vehicle = Vehicle(
        id: newId,
        userId: userId,
        name: name,
        transportType: transportType,
        weightKg: weightKg,
        wheelSize: wheelSize,
        totalDistance: totalDistance,
        isActive: isActive,
        isEbike: isEbike,
      );
      _vehicles = <Vehicle>[vehicle, ..._vehicles];
      return newId;
    } on PostgrestException catch (e) {
      // Подробная диагностика PostgREST (код PGRST204 и др.) — только в лог.
      debugPrint('[GarageService] addVehicle ${e.code}: ${e.message}');
      throw GarageServiceException(
        'Не удалось сохранить транспорт (${e.code}). Проверьте интернет '
        'и настройки таблицы garage.',
      );
    } catch (e) {
      debugPrint('[GarageService] addVehicle failed: $e');
      // GarageServiceException уже с текстом для UI — пробрасываем как есть.
      if (e is GarageServiceException) rethrow;
      throw const GarageServiceException(
        'Не удалось сохранить транспорт. Проверьте интернет.',
      );
    }
  }

  /// Удаляет технику по id.
  Future<bool> deleteVehicle(String vehicleId) async {
    if (sessionVehicle?.id == vehicleId) return false;
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return false;

    try {
      await client
          .from(AppConfig.garageTable)
          .delete()
          .eq('user_id', id)
          .eq('id', vehicleId);
      _vehicles.removeWhere((vehicle) => vehicle.id == vehicleId);
      if (_sessionVehicle?.id == vehicleId) bindToSession(null);
      debugPrint('[GarageService] удалена техника $vehicleId');
      return true;
    } on PostgrestException catch (error) {
      debugPrint('[GarageService] delete ${error.code}: ${error.message}');
      return false;
    } catch (error) {
      debugPrint('[GarageService] delete failed: $error');
      return false;
    }
  }

  /// Делает технику активной (сбрасывая флаг у остальных).
  ///
  /// Сервер блокирует строки владельца и меняет выбор одной транзакцией.
  Future<bool> setActiveVehicle(String vehicleId) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return false;

    try {
      await client.rpc(
        'set_active_vehicle',
        params: {'p_vehicle_id': vehicleId},
      );

      _vehicles = _vehicles
          .map((vehicle) => vehicle.copyWith(isActive: vehicle.id == vehicleId))
          .toList();
      debugPrint('[GarageService] активная техника: $vehicleId');
      return true;
    } on PostgrestException catch (error) {
      debugPrint('[GarageService] setActive ${error.code}: ${error.message}');
      return false;
    } catch (error) {
      debugPrint('[GarageService] setActive failed: $error');
      return false;
    }
  }

  Future<Vehicle> fetchVehicle(String vehicleId) async {
    final client = _client;
    final uid = userId;
    if (client == null || uid == null) {
      throw const GarageServiceException('Войдите в аккаунт');
    }
    try {
      final row = await client
          .from(AppConfig.garageTable)
          .select(_selectColumns)
          .eq('user_id', uid)
          .eq('id', vehicleId)
          .single()
          .timeout(const Duration(seconds: 6));
      if (userId != uid) {
        throw const GarageServiceException('Аккаунт изменился');
      }
      _equipmentSnapshots[vehicleId] = Map<String, dynamic>.from(row);
      final cache = AccountProgressCache('garage_rows', uid);
      final stored = await cache.read();
      final rows =
          (stored as List? ?? []).where((r) => r['id'] != vehicleId).toList()
            ..add(row);
      await cache.write(rows);
      return Vehicle.fromRow(row);
    } catch (_) {
      if (userId == uid) {
        final rows = await AccountProgressCache('garage_rows', uid).read();
        if (rows is List) {
          final cached = rows.where((r) => r['id'] == vehicleId).firstOrNull;
          if (cached is Map) {
            final row = Map<String, dynamic>.from(cached);
            _equipmentSnapshots[vehicleId] = row;
            return Vehicle.fromRow(row);
          }
        }
      }
      throw const GarageServiceException(
        'Не удалось загрузить велосипед. Проверьте подключение.',
      );
    }
  }

  Future<Vehicle> saveEquipment(Vehicle vehicle) async {
    final client = _client;
    final uid = userId;
    if (client == null || uid == null || uid != vehicle.userId) {
      throw const GarageServiceException('Нет доступа к велосипеду');
    }
    try {
      final previous = _equipmentSnapshots[vehicle.id];
      if (previous == null || previous['user_id'] != uid) {
        throw const GarageServiceException(
          'Обновите велосипед перед сохранением',
        );
      }
      final row = await client
          .rpc(
            'save_bike_workshop_v2',
            params: {
              'p_vehicle_id': vehicle.id,
              'p_expected': _workshopExpected(previous),
              'p_changes': _workshopChanges(vehicle),
            },
          )
          .single()
          .timeout(const Duration(seconds: 20));
      if (userId != uid) {
        throw const GarageServiceException('Аккаунт изменился');
      }
      _equipmentSnapshots[vehicle.id] = Map<String, dynamic>.from(row);
      final saved = Vehicle.fromRow(row);
      unawaited(fetchVehicles());
      _vehicles = _vehicles.map((v) => v.id == saved.id ? saved : v).toList();
      return saved;
    } catch (_) {
      throw const GarageServiceException(
        'Изменения не сохранены. Обновите велосипед: возможно, синхронизировался заезд или настройки изменились на другом устройстве. Затем повторите.',
      );
    }
  }

  static Map<String, dynamic> _workshopExpected(Map<String, dynamic> row) => {
    for (final key in [
      'title',
      'type',
      'weight_kg',
      'wheel_size',
      'is_ebike',
      'is_public',
      'maintenance',
      'drivetrain',
      'total_distance',
      'recorded_hours',
    ])
      key: row[key],
  };

  static Map<String, dynamic> _workshopChanges(Vehicle vehicle) {
    final changes = <String, dynamic>{
      'title': vehicle.name,
      'type': vehicle.transportType,
      'weight_kg': vehicle.weightKg,
      'wheel_size': vehicle.wheelSize,
      'is_ebike': vehicle.isEbike,
      'is_public': vehicle.isPublic,
      'maintenance': vehicle.parts.map((p) => p.toJson()).toList(),
      'drivetrain': vehicle.drivetrain?.toJson() ?? {},
    };
    if (utf8.encode(jsonEncode(changes)).length > 4000000) {
      throw const GarageServiceException(
        'Журнал велосипеда превышает 4 МБ. Изменения не отправлены.',
      );
    }
    return changes;
  }

  Future<Vehicle> addPriorMileage(Vehicle vehicle, double km) async {
    final client = _client;
    final uid = userId;
    if (client == null ||
        sessionVehicle?.id == vehicle.id ||
        uid != vehicle.userId ||
        !km.isFinite ||
        km <= 0 ||
        km > 1000000) {
      throw const GarageServiceException('Проверьте пробег и аккаунт');
    }
    // Начальный пробег сдвигает шкалу одометра. Интервалы обслуживания
    // сохраняют фактически накопленную с момента их настройки дистанцию.
    final shifted = vehicle.parts
        .map(
          (p) => p.copyWith(
            lastServiceKm: p.lastServiceKm + km,
            installedKm: (p.installedKm ?? p.lastServiceKm) + km,
            history: p.history
                .map(
                  (e) => {
                    ...e,
                    'km': ((e['km'] as num?)?.toDouble() ?? 0) + km,
                  },
                )
                .toList(),
          ),
        )
        .toList();
    try {
      final previous = _equipmentSnapshots[vehicle.id];
      if (previous == null || previous['user_id'] != uid) {
        throw const GarageServiceException(
          'Обновите велосипед перед изменением пробега',
        );
      }
      final row = await client
          .rpc(
            'save_bike_workshop_v2',
            params: {
              'p_vehicle_id': vehicle.id,
              'p_expected': _workshopExpected(previous),
              'p_changes': _workshopChanges(vehicle.copyWith(parts: shifted)),
              'p_mileage_delta': km,
            },
          )
          .single()
          .timeout(const Duration(seconds: 20));
      if (userId != uid) {
        throw const GarageServiceException('Аккаунт изменился');
      }
      _equipmentSnapshots[vehicle.id] = Map<String, dynamic>.from(row);
      final saved = Vehicle.fromRow(row);
      _vehicles = _vehicles.map((v) => v.id == saved.id ? saved : v).toList();
      return saved;
    } catch (_) {
      throw const GarageServiceException(
        'Пробег не изменён: обновите велосипед и повторите. Возможно, сейчас синхронизировался заезд.',
      );
    }
  }

  Future<List<Vehicle>> fetchPublicVehicles(String ownerId) async {
    final client = _client;
    if (client == null || userId == null) {
      throw const GarageServiceException('Войдите в аккаунт');
    }
    try {
      final rows = await client.rpc(
        'get_public_garage',
        params: {'p_user_id': ownerId},
      );
      return (rows as List)
          .whereType<Map>()
          .map((row) => Vehicle.fromRow(Map<String, dynamic>.from(row)))
          .toList();
    } catch (_) {
      throw const GarageServiceException(
        'Не удалось загрузить публичный гараж',
      );
    }
  }

  /// Обновляет суммарный пробег техники (например, после заезда).
  Future<bool> updateVehicleDistance(
    String vehicleId,
    double totalDistance,
  ) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return false;

    try {
      await client
          .from(AppConfig.garageTable)
          .update({
            'total_distance': totalDistance.isFinite ? totalDistance : 0,
          })
          .eq('user_id', id)
          .eq('id', vehicleId);
      _vehicles = _vehicles
          .map(
            (vehicle) => vehicle.id == vehicleId
                ? vehicle.copyWith(totalDistance: totalDistance)
                : vehicle,
          )
          .toList();
      return true;
    } on PostgrestException catch (error) {
      debugPrint(
        '[GarageService] updateDistance ${error.code}: ${error.message}',
      );
      return false;
    } catch (error) {
      debugPrint('[GarageService] updateDistance failed: $error');
      return false;
    }
  }

  /// Сохраняет ссылку на фото техники (`null` — сбросить).
  Future<bool> updateVehiclePhotoUrl(String vehicleId, String? url) =>
      _updatePhotoUrl(vehicleId, url);

  /// Загружает фото техники в бакет `vehicles` и сохраняет публичный URL
  /// в `garage.photo_url`.
  ///
  /// Путь объекта: `<uid>/<vehicle_id>.<ext>` — фиксированное имя по id
  /// техники: при замене фото объект перезаписывается, мусор не копится.
  /// Формат политики Storage: `(storage.foldername(name))[1] = auth.uid()`.
  Future<String> uploadVehiclePhoto(
    String localFilePath,
    String vehicleId,
  ) async {
    final client = _client;
    final userId = client?.auth.currentUser?.id;
    if (client == null || userId == null) {
      throw const GarageServiceException(
        'Нет сессии. Войдите в аккаунт, чтобы загрузить фото.',
      );
    }

    try {
      final bytes = await readBytesFromPath(localFilePath);
      final objectPath = '$userId/$vehicleId${_extensionOf(localFilePath)}';

      await client.storage
          .from(AppConfig.vehiclesBucket)
          .uploadBinary(
            objectPath,
            bytes,
            fileOptions: const FileOptions(upsert: true, cacheControl: '3600'),
          );

      final url =
          '${client.storage.from(AppConfig.vehiclesBucket).getPublicUrl(objectPath)}?v=${DateTime.now().millisecondsSinceEpoch}';
      final ok = await _updatePhotoUrl(vehicleId, url);
      if (!ok) {
        throw const GarageServiceException(
          'Фото загружено, но ссылка не сохранена. Попробуйте ещё раз.',
        );
      }
      debugPrint('[GarageService] фото техники $vehicleId загружено');
      return url;
    } on StorageException catch (error) {
      debugPrint(
        '[GarageService] Storage ${error.statusCode}: ${error.message}',
      );
      throw GarageServiceException(_humanizeStorageError(error));
    } on FileReadException catch (error) {
      throw GarageServiceException(error.message);
    } on GarageServiceException {
      rethrow;
    } catch (error) {
      debugPrint('[GarageService] uploadVehiclePhoto failed: $error');
      throw const GarageServiceException(
        'Не удалось загрузить фото. Проверьте интернет.',
      );
    }
  }

  /// Убирает фото: чистит `photo_url` и (best effort) объекты в Storage.
  Future<bool> removeVehiclePhoto(String vehicleId) async {
    final client = _client;
    final userId = client?.auth.currentUser?.id;
    final cleared = await _updatePhotoUrl(vehicleId, null);
    if (client == null || userId == null) return cleared;

    try {
      final objects = await client.storage
          .from(AppConfig.vehiclesBucket)
          .list(path: userId);
      final own = objects.where((object) => object.name.startsWith(vehicleId));
      if (own.isNotEmpty) {
        await client.storage
            .from(AppConfig.vehiclesBucket)
            .remove(own.map((object) => '$userId/${object.name}').toList());
      }
    } catch (error) {
      debugPrint('[GarageService] не удалось удалить файлы фото: $error');
    }
    return cleared;
  }

  static String _humanizeStorageError(StorageException error) {
    final message = error.message.toLowerCase();
    if (error.statusCode == '404' || message.contains('bucket not found')) {
      return 'Бакет «${AppConfig.vehiclesBucket}» не найден в Supabase Storage. '
          'Создайте его (Public) и добавьте политики доступа.';
    }
    if (error.statusCode == '403' || message.contains('policy')) {
      return 'Нет прав на загрузку в Storage. Проверьте политики бакета '
          '«${AppConfig.vehiclesBucket}».';
    }
    return 'Не удалось загрузить фото: ${error.message}';
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    if (dot <= slash || dot == path.length - 1) return '.jpg';
    final extension = path.substring(dot).toLowerCase();
    return extension.length <= 6 ? extension : '.jpg';
  }

  Future<bool> _updatePhotoUrl(String vehicleId, String? url) async {
    final client = _client;
    final id = client?.auth.currentUser?.id;
    if (client == null || id == null) return false;

    try {
      await client
          .from(AppConfig.garageTable)
          .update({'photo_url': url})
          .eq('user_id', id)
          .eq('id', vehicleId);
      _vehicles = _vehicles
          .map(
            (vehicle) => vehicle.id == vehicleId
                ? vehicle.copyWith(photoUrl: url, clearPhoto: url == null)
                : vehicle,
          )
          .toList();
      return true;
    } on PostgrestException catch (error) {
      debugPrint('[GarageService] photoUrl ${error.code}: ${error.message}');
      return false;
    } catch (error) {
      debugPrint('[GarageService] photoUrl failed: $error');
      return false;
    }
  }
}
