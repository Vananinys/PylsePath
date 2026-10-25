import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_profile.dart';
import 'user_scope.dart';
import '../services/profile_sync_service.dart';

class UserProfileRepository {
  UserProfileRepository({
    ProfileSyncService? syncService,
    String? Function()? currentUser,
  }) : _syncService = syncService ?? ProfileSyncService(),
       _currentUser = currentUser ?? UserScope.currentUserId,
       _owner = (currentUser ?? UserScope.currentUserId)();
  static const String _storageKey =
      'user_profile'; // базовый ключ; хранится пер-аккаунтово (UserScope)
  static const String _syncPendingKey = 'user_profile_sync_pending';
  static const String _clearAvatarPendingKey =
      'user_profile_clear_avatar_pending';
  static const double _defaultWeight = 70.0;
  static const double _defaultHeight = 175.0;
  static const int _defaultAge = 30;

  /// Отправка профиля в Supabase (ничего не делает без сессии/инициализации).
  final ProfileSyncService _syncService;
  final String? Function() _currentUser;

  final String? _owner;
  UserProfile _profile = _defaultProfile();

  UserProfile get profile => _profile;

  /// Был ли на устройстве сохранённый профиль этого аккаунта до загрузки.
  /// Вместе с `pullFromCloud() == false` означает «аккаунт только что
  /// создан» — сигнал показать онбординг с выбором пресета.
  bool _hadStoredProfile = false;
  bool get hadStoredProfile => _hadStoredProfile;
  bool _syncPending = false;
  bool _clearAvatarPending = false;
  int _syncRevision = 0;
  String? _avatarUploadPath;
  Future<bool>? _syncing;
  bool get hasPendingSync => _syncPending;

  static UserProfile _defaultProfile() => UserProfile(
    weightKg: _defaultWeight,
    heightCm: _defaultHeight,
    age: _defaultAge,
    garage: [],
    selectedBike: null,
    username: 'Райдер',
    status: 'Начинающий',
    city: 'Не указан',
    preferredRidingType: RidingType.road,
    avatarIndex: 0,
  );

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Ключ привязан к аккаунту: второй аккаунт не увидит кэш первого.
      final scopedKey = UserScope.keyFor(_storageKey, _owner);
      final String? profileJson = prefs.getString(scopedKey);
      _syncPending =
          prefs.getBool(UserScope.keyFor(_syncPendingKey, _owner)) ?? false;
      _clearAvatarPending =
          prefs.getBool(UserScope.keyFor(_clearAvatarPendingKey, _owner)) ??
          false;
      if (profileJson != null) {
        final Map<String, dynamic> decoded = jsonDecode(profileJson);
        _syncPending = decoded['_syncPending'] as bool? ?? _syncPending;
        _clearAvatarPending =
            decoded['_clearAvatarPending'] as bool? ?? _clearAvatarPending;
        _syncRevision = decoded['_syncRevision'] as int? ?? 0;
        _avatarUploadPath = decoded['_avatarUploadPath'] as String?;
        _profile = UserProfile.fromJson(decoded);
        _hadStoredProfile = true;
      } else {
        // Если нет сохранённого профиля, создаём дефолтный
        _profile = _defaultProfile();
        await save();
      }
    } catch (_) {
      _profile = _defaultProfile();
    }
  }

  Future<void> save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String encoded = jsonEncode({
        ..._profile.toJson(),
        '_syncPending': _syncPending,
        '_clearAvatarPending': _clearAvatarPending,
        '_syncRevision': _syncRevision,
        '_avatarUploadPath': _avatarUploadPath,
      });
      if (!await prefs.setString(
        UserScope.keyFor(_storageKey, _owner),
        encoded,
      )) {
        throw StateError('Хранилище отклонило запись профиля');
      }
    } catch (error) {
      throw StateError('Не удалось сохранить профиль: $error');
    }
  }

  /// Сброс in-memory состояния (при выходе из аккаунта). Данные на диске
  /// остаются под ключом пользователя — после повторного входа вернутся.
  void reset() {
    _profile = _defaultProfile();
  }

  /// Локально сохранили — отправляем UPSERT в `profiles` (best effort:
  /// без сети/сессии просто пропускается, ошибка не пробрасывается).
  Future<void> _saveAndSync({bool clearAvatar = false}) async {
    _syncPending = _owner != null;
    _syncRevision++;
    if (clearAvatar) {
      _clearAvatarPending = true;
    } else if (_avatarUploadPath != null ||
        _profile.avatarUrl != null ||
        (_profile.photoPath?.startsWith('http://') ?? false) ||
        (_profile.photoPath?.startsWith('https://') ?? false)) {
      _clearAvatarPending = false;
    }
    await _persistSyncState();
    if (_owner != null && _currentUser() == _owner) {
      unawaited(_retryCloudSync());
    }
  }

  Future<void> _persistSyncState() async {
    await save();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
      UserScope.keyFor(_syncPendingKey, _owner),
      _syncPending,
    );
    await prefs.setBool(
      UserScope.keyFor(_clearAvatarPendingKey, _owner),
      _clearAvatarPending,
    );
  }

  Future<bool> retryPendingSync() => _retryCloudSync();
  Future<bool> _retryCloudSync() =>
      _syncing ??= _sendPending().whenComplete(() => _syncing = null);
  Future<bool> _sendPending() async {
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!_syncPending || _currentUser() != _owner) return !_syncPending;
        final revision = _syncRevision;
        final localPhoto = _avatarUploadPath;
        if (localPhoto != null) {
          final url = await _syncService.uploadAvatar(localPhoto);
          if (_currentUser() != _owner) return false;
          if (_syncRevision != revision || _avatarUploadPath != localPhoto)
            continue;
          _profile = _profile.copyWith(avatarUrl: url);
          _avatarUploadPath = null;
          await save();
        }
        final snapshot = UserProfile.fromJson(_profile.toJson());
        final sent = await _syncService.upsertProfile(
          snapshot,
          clearAvatar: _clearAvatarPending,
        );
        if (!sent || _currentUser() != _owner) return false;
        if (_syncRevision != revision) continue;
        _syncPending = false;
        _clearAvatarPending = false;
        await _persistSyncState();
        return true;
      }
    } catch (error) {
      debugPrint('[Profile] saved locally; sync deferred: $error');
    }
    return false;
  }

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
    _profile = _profile.copyWith(
      // Страховка на записи: даже если значение пришло в обход валидации
      // формы, в профиль оно попадёт только в физически допустимом диапазоне.
      weightKg: weightKg == null ? null : UserProfile.clampWeight(weightKg),
      heightCm: heightCm == null ? null : UserProfile.clampHeight(heightCm),
      age: age == null ? null : UserProfile.clampAge(age),
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
    await _saveAndSync();
  }

  /// Local mirror of server garage; reading the garage must not upload a profile.
  Future<void> updateGarageCache({
    required List<Bike> garage,
    Bike? selectedBike,
  }) async {
    if (UserScope.currentUserId() != _owner) return;
    _profile = _profile.copyWith(garage: garage, selectedBike: selectedBike);
    _profile.selectedBike = selectedBike;
    await save();
  }

  Future<void> updateFullProfile({
    double? weightKg,
    double? heightCm,
    int? age,
    String? username,
    String? status,
    String? city,
    RidingType? preferredRidingType,
    List<Bike>? garage,
    Bike? selectedBike,
  }) async {
    _profile = _profile.copyWith(
      weightKg: weightKg == null ? null : UserProfile.clampWeight(weightKg),
      heightCm: heightCm == null ? null : UserProfile.clampHeight(heightCm),
      age: age == null ? null : UserProfile.clampAge(age),
      username: username,
      status: status,
      city: city,
      preferredRidingType: preferredRidingType,
      garage: garage,
      selectedBike: selectedBike,
    );
    await _saveAndSync();
  }

  /// Сохраняет путь к пользовательскому фото профиля.
  /// `null` — вернуться к иконке из встроенного набора.
  Future<void> setPhotoPath(String? path) async {
    _avatarUploadPath = path != null && !path.startsWith('http') ? path : null;
    _profile = _profile.copyWith(photoPath: path, clearPhoto: path == null);
    await _saveAndSync(clearAvatar: path == null);
  }

  /// Сохраняет публичный URL аватара в Supabase Storage.
  /// `null` — аватар в облаке удалён (заодно сбрасываем локальное фото).
  Future<void> setAvatarUrl(String? url) async {
    _avatarUploadPath = null;
    _profile = _profile.copyWith(avatarUrl: url, clearPhoto: url == null);
    await _saveAndSync(clearAvatar: url == null);
  }

  /// Загружает профиль из облака (по auth.uid()) и применяет его локально.
  ///
  /// Возвращает true, если данные в облаке были. Обратной записи здесь нет
  /// намеренно — иначе получился бы цикл «pull → push → pull».
  /// Если строки в облаке нет, данные остаются локальными и уедут в облако
  /// при следующем сохранении профиля.
  Future<bool> pullFromCloud() async {
    if (_currentUser() != _owner) return false;
    // Push locally saved edits before pulling. An offline edit must never be
    // silently replaced by the older cloud copy on the next app launch.
    if (_syncPending && !await _retryCloudSync()) return false;
    final revision = _syncRevision;
    final remote = await _syncService.fetchProfile();
    if (_currentUser() != _owner || _syncPending || revision != _syncRevision)
      return false;
    if (remote == null) return false;

    final weight = remote['weight'] as double?;
    final height = remote['height'] as double?;
    final age = remote['age'] as int?;
    final status = remote['status'] as String?;
    final city = remote['city'] as String?;
    final ridingType = remote['preferredRidingType'] as RidingType?;
    final gender = remote['gender'] as String?;
    final showWeight = remote['showWeight'] as bool?;
    final showAge = remote['showAge'] as bool?;
    final showGender = remote['showGender'] as bool?;
    final cloudAvatarUrl = remote['avatarUrl'] as String?;

    _profile = _profile.copyWith(
      username: remote['username'] as String?,
      weightKg: weight == null ? null : UserProfile.clampWeight(weight),
      heightCm: height == null ? null : UserProfile.clampHeight(height),
      age: age == null ? null : UserProfile.clampAge(age),
      // В облаке аватара нет → локальный фото-путь тоже надо сбросить:
      // иначе после входа другим аккаунтом здесь останется ЧУЖОЙ локальный
      // файл (он и был источником «перетирающейся аватарки»).
      avatarUrl: cloudAvatarUrl,
      clearPhoto: cloudAvatarUrl == null,
      // status/city/preferred_riding_type: null в облаке = «не задано»,
      // локальное значение оставляем.
      status: status,
      city: city,
      preferredRidingType: ridingType,
      gender: gender,
      showWeight: showWeight,
      showAge: showAge,
      showGender: showGender,
      uiPreset: remote['uiPreset'] as String?,
      modulesEnabled: remote['modulesEnabled'] as Set<String>?,
    );
    await save();
    return true;
  }

  Future<void> addBike(Bike bike) async {
    _profile.garage.add(bike);
    // Если это первый велосипед, автоматически выбираем его
    _profile.selectedBike ??= bike;
    await save();
  }

  Future<void> removeBike(Bike bike) async {
    _profile.garage.removeWhere((item) => item.id == bike.id);
    // Если удалённый велосипед был выбран, сбрасываем выбор.
    // Сравнение по id: после перечитывания профиля из JSON это другой экземпляр.
    if (_profile.selectedBike?.id == bike.id) {
      _profile.selectedBike = _profile.garage.isNotEmpty
          ? _profile.garage.first
          : null;
    }
    await save();
  }

  Future<void> selectBike(Bike? bike) async {
    _profile.selectedBike = bike;
    await save();
  }

  Future<void> clearGarage() async {
    _profile.garage.clear();
    _profile.selectedBike = null;
    await save();
  }
}
