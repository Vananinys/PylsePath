import 'package:flutter/foundation.dart';

import '../data/ui_modules.dart';
import '../data/user_profile_repository.dart';
import '../models/user_profile.dart';
import '../services/garage_service.dart';
import '../services/profile_presentation_service.dart';
import '../data/user_scope.dart';

/// Состояние профиля: держит данные в памяти и синхронизирует с Supabase.
///
/// Ключевая идея — не дёргать `profiles` при каждом открытии экрана:
/// [ensureLoaded] подтягивает облако один раз за сессию, дальше данные берутся
/// из памяти. Кэш и облако обновляются только по явному действию пользователя
/// (сохранение формы профиля или смена фото).
class ProfileProvider extends ChangeNotifier {
  ProfileProvider({UserProfileRepository? repository})
    : _repo = repository ?? UserProfileRepository();

  final UserProfileRepository _repo;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  bool _loading = false;
  bool _loaded = false;
  bool _cloudPulled = false;
  Future<void>? _loadingFuture;
  Future<void>? _localFuture;

  /// Текущий профиль из кэша.
  UserProfile get profile => _repo.profile;

  /// Идёт загрузка (для индикатора на экране).
  bool get isLoading => _loading;

  /// Данные из облака уже подтянуты в этой сессии.
  bool get isCloudPulled => _cloudPulled;

  /// Кэш уже загружен и готов к показу без спиннера.
  bool get isReady => _loaded;
  bool get hasLocalProfile => _repo.hadStoredProfile;
  bool get hasPendingSync => _repo.hasPendingSync;

  Future<void> ensureLocalLoaded() => _localFuture ??= () async {
    final owner = UserScope.currentUserId();
    await Future.wait([
      _repo.load(),
      if (owner != null) ProfilePresentationService().loadCached(owner),
    ]);
    _loaded = true;
    notifyListeners();
  }();

  Future<void> retryPendingChanges() async {
    await _repo.retryPendingSync();
    notifyListeners();
  }

  /// Аккаунт только что создан: нет ни локального кэша, ни облачной строки.
  /// Вызывается ПОСЛЕ [ensureLoaded]; служит сигналом для онбординга
  /// (существующие пользователи онбординг не видят — у них есть кэш или облако).
  bool get isBrandNewUser =>
      isReady && !_repo.hadStoredProfile && !_cloudPulled;

  /// Гарантирует загрузку профиля.
  ///
  /// Облако тянется только один раз за сессию; повторные вызовы (повторное
  /// открытие экрана профиля) отдают данные из памяти. [force] = true
  /// принудительно обновляет из Supabase. Параллельные вызовы ждут один и
  /// тот же future — двойной load()+pull невозможен.
  Future<void> ensureLoaded({bool force = false}) {
    if (_loading && _loadingFuture != null) return _loadingFuture!;
    if (_loaded && !force && _cloudPulled) return Future.value();

    _loading = true;
    final future = Future<void>.microtask(() => _load(force: force));
    _loadingFuture = future;
    return future;
  }

  Future<void> _load({bool force = false}) async {
    _loading = true;
    notifyListeners();

    try {
      await ensureLocalLoaded();
      if (force || !_cloudPulled) {
        try {
          _cloudPulled = await _repo.pullFromCloud();
        } catch (error) {
          debugPrint('[ProfileProvider] pullFromCloud failed: $error');
        }
      }

      _loaded = true;
    } finally {
      _loading = false;
      _loadingFuture = null;
      notifyListeners();
    }
  }

  /// Принудительно обновляет профиль из облака (pull-to-refresh).
  Future<void> refresh() => ensureLoaded(force: true);

  Future<void> refreshGarage() async {
    final service = GarageService();
    final vehicles = await service.fetchVehicles();
    if (!service.lastFetchSucceeded) return;
    await _repo.updateGarageCache(
      garage: vehicles.map((v) => v.toBike()).toList(),
      selectedBike: vehicles.where((v) => v.isActive).firstOrNull?.toBike(),
    );
    notifyListeners();
  }

  /// Полный сброс при выходе из аккаунта: without этого следующий вход
  /// другого аккаунта работал бы на кэше предыдущего (его аватар, вес, имя)
  /// и не подтягивал своё облако (флаг _cloudPulled оставался бы true).
  void reset() {
    _repo.reset();
    _loaded = false;
    _loading = false;
    _cloudPulled = false;
    _loadingFuture = null;
    _localFuture = null;
    notifyListeners();
  }

  /// Сохраняет изменения формы профиля (локально + UPSERT в `profiles`).
  /// Кэш обновляется сразу — следующий вход на экран покажет новые данные.
  Future<void> updateProfile({
    double? weightKg,
    double? heightCm,
    int? age,
    String? username,
    String? status,
    String? city,
    RidingType? preferredRidingType,
    int? avatarIndex,
    String? gender,
    bool? showWeight,
    bool? showAge,
    bool? showGender,
    String? uiPreset,
    Set<String>? modulesEnabled,
  }) async {
    await _repo.updateProfile(
      weightKg: weightKg,
      heightCm: heightCm,
      age: age,
      username: username,
      status: status,
      city: city,
      preferredRidingType: preferredRidingType,
      avatarIndex: avatarIndex,
      gender: gender,
      showWeight: showWeight,
      showAge: showAge,
      showGender: showGender,
      uiPreset: uiPreset,
      modulesEnabled: modulesEnabled,
    );
    notifyListeners();
  }

  /// Сохраняет локальный путь фото профиля (`null` — вернуть иконку).
  Future<void> setPhotoPath(String? path) async {
    await _repo.setPhotoPath(path);
    notifyListeners();
  }

  /// Сохраняет публичный URL аватара (`null` — сбросить).
  Future<void> setAvatarUrl(String? url) async {
    await _repo.setAvatarUrl(url);
    notifyListeners();
  }

  Future<void> addBike(Bike bike) async {
    await _repo.addBike(bike);
    notifyListeners();
  }

  Future<void> removeBike(Bike bike) async {
    await _repo.removeBike(bike);
    notifyListeners();
  }

  Future<void> selectBike(Bike? bike) async {
    await _repo.selectBike(bike);
    notifyListeners();
  }

  /// Включён ли модуль интерфейса (явный набор профиля или набор пресета).
  bool isModuleEnabled(String moduleId) =>
      effectiveEnabledModules(profile).contains(moduleId);

  /// Применяет пресет: фиксирует выбор и раскладывает его набор модулей.
  Future<void> applyUiPreset(UiPreset preset) async {
    await updateProfile(uiPreset: preset.id, modulesEnabled: preset.modules);
  }

  /// Включает/выключает один модуль поверх текущей конфигурации.
  Future<void> setModuleEnabled(String moduleId, bool enabled) async {
    final modules = Set.of(effectiveEnabledModules(profile));
    if (enabled) {
      modules.add(moduleId);
    } else {
      modules.remove(moduleId);
    }
    await updateProfile(modulesEnabled: modules);
  }
}
