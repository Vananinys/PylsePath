import '../data/user_scope.dart';
import '../services/profile_presentation_service.dart';
import '../widgets/profile_identity_card.dart';
import 'profile_customize_screen.dart';

import 'dart:io';
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;

import '../data/workout_history_repository.dart';
import '../data/progress_goals_repository.dart';
import '../models/user_profile.dart';
import '../models/progress_period.dart';
import '../models/saved_route.dart';
import '../services/profile_photo_service.dart';
import '../services/achievements_service.dart';
import '../services/achievement_journey.dart';
import '../services/activity_service.dart';
import '../widgets/activity_panel.dart';
import '../services/owner_service.dart';
import '../state/profile_provider.dart';
import 'garage_screen.dart';
import '../widgets/garage_profile_gallery.dart';
import 'workout_history_screen.dart';
import 'training_center_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.provider});

  /// Общий кэш профиля из State Management. Обязателен: экран без общего
  /// провайдера создавал бы собственный второй кэш в обход main.dart.
  final ProfileProvider provider;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final WorkoutHistoryRepository _workoutRepo = WorkoutHistoryRepository();
  final ProfilePhotoService _photoService = ProfilePhotoService();
  final ProgressGoalsRepository _goalsRepo = ProgressGoalsRepository();

  /// Профиль берём из кэша: повторное открытие экрана не дёргает Supabase.
  late final ProfileProvider _profileProvider;

  /// Облачная синхронизация: чтение `profiles` и загрузка аватара в Storage.
  late UserProfile _profile;
  List<SavedRoute> _workoutHistory = [];
  bool _loading = true;
  bool _openingCustomizer = false;
  int _garageRevision = 0;
  String? _loadError;
  String? _equippedTitle;
  String? _equippedTitleIcon;
  ProfilePresentation _presentation = const ProfilePresentation();
  bool? _activityPublic;
  bool _savingActivityPrivacy = false;
  Listenable? _appearanceWatch;
  String? _appearanceOwner;
  Future<void>? _cloudRefresh;

  /// Период прогресса: День / Неделя / Месяц / Год.
  ProgressPeriod _period = ProgressPeriod.month;

  /// Существующий файл пользовательского фото (null — показываем иконку).
  File? _photoFile;

  /// Маркер возврата из шита выбора аватара: «открыть галерею».
  /// Используется потому, что шит возвращает либо индекс иконки, либо это.
  static const String _galleryResult = '__gallery__';

  /// Маркер возврата: «убрать фото и вернуться к иконке».
  static const String _removePhotoResult = '__remove_photo__';

  static const List<IconData> avatarIcons = [
    Icons.person,
    Icons.directions_bike,
    Icons.sports,
    Icons.emoji_events,
    Icons.face,
    Icons.pedal_bike,
    Icons.landscape,
    Icons.speed,
  ];

  @override
  void initState() {
    super.initState();
    // Провайдер обязателен: он передаётся из main.dart (общий кэш над всем
    // приложением). Локальная копия здесь создавала бы второй независимый
    // кэш профиля — так делать нельзя.
    _profileProvider = widget.provider;
    _profile = _profileProvider.profile;
    _appearanceOwner = UserScope.currentUserId();
    if (_appearanceOwner != null) {
      _presentation =
          ProfilePresentationService.peek(_appearanceOwner!) ?? _presentation;
      _appearanceWatch = ProfilePresentationService.watch(_appearanceOwner!);
      _appearanceWatch!.addListener(_appearanceChanged);
    }
    // Мгновенный показ: если кэш уже в памяти (повторное открытие), рисуем
    // экран сразу, а сеть обновляем тихо в фоне.
    if (_profileProvider.isReady &&
        _appearanceOwner != null &&
        ProfilePresentationService.peek(_appearanceOwner!) != null) {
      _profile = _profileProvider.profile;
      _loading = false;
    }
    _loadData(showSpinner: _loading);
  }

  void _appearanceChanged() {
    final owner = _appearanceOwner;
    if (mounted && owner != null && owner == UserScope.currentUserId()) {
      final cached = ProfilePresentationService.peek(owner);
      if (cached != null) setState(() => _presentation = cached);
    }
  }

  @override
  void dispose() {
    _appearanceWatch?.removeListener(_appearanceChanged);
    super.dispose();
  }

  /// [showSpinner] = false — тихое обновление (смена аватара/фото), чтобы
  /// не мигал полноэкранный индикатор загрузки.
  Future<void> _loadData({bool showSpinner = true}) async {
    if (showSpinner) setState(() => _loading = true);
    final owner = UserScope.currentUserId();
    try {
      await Future.wait([
        _profileProvider.ensureLocalLoaded(),
        _workoutRepo.load(),
        _goalsRepo.load(syncCloud: false),
        AchievementsService.restoreProgress(),
        if (owner != null) ProfilePresentationService().loadCached(owner),
      ]);
      final photo = await ProfilePhotoService.resolveExistingFile(
        _profileProvider.profile.photoPath,
      );
      if (!mounted || owner != UserScope.currentUserId()) return;
      setState(() {
        _profile = _profileProvider.profile;
        _workoutHistory = _workoutRepo.workoutHistory;
        _period = _goalsRepo.period;
        _photoFile = photo;
        _presentation = owner == null
            ? _presentation
            : ProfilePresentationService.peek(owner) ?? _presentation;
        _loading = false;
        _loadError = null;
      });
      _cloudRefresh ??= _refreshCloud(owner)
          .whenComplete(() => _cloudRefresh = null);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Не удалось загрузить профиль и историю. Данные не удалены.';
      });
      debugPrint('[Profile] local load failed: $error');
    }
  }

  Future<void> _refreshCloud(String? owner) async {
    Future<void> safely(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        /* Offline content stays visible. */
      }
    }

    await Future.wait([
      safely(() => _profileProvider.ensureLoaded()),
      safely(() => _profileProvider.refreshGarage()),
      safely(() => _workoutRepo.restoreFromCloud()),
      safely(() => _goalsRepo.load()),
      if (owner != null)
        safely(() async {
          await ProfilePresentationService().load(owner, refreshEarned: true);
        }),
      safely(() async {
        final awards = await OwnerService().awards();
        if (!mounted || owner != UserScope.currentUserId()) return;
        AchievementsService.ownerIssued = awards;
        final equipped = awards
            .where((a) => a.kind == 'title' && a.equipped)
            .firstOrNull;
        _equippedTitle = equipped?.label;
        _equippedTitleIcon = equipped?.icon;
      }),
      if (owner != null)
        safely(() async {
          final activity = await ActivityService().load(owner);
          if (mounted && owner == UserScope.currentUserId())
            setState(() => _activityPublic = activity.visible);
        }),
    ]);
    if (!mounted || owner != UserScope.currentUserId()) return;
    final photo = await ProfilePhotoService.resolveExistingFile(
      _profileProvider.profile.photoPath,
    );
    if (!mounted || owner != UserScope.currentUserId()) return;
    setState(() {
      _profile = _profileProvider.profile;
      _photoFile = photo;
      _workoutHistory = _workoutRepo.workoutHistory;
      _period = _goalsRepo.period;
      _garageRevision++;
    });
  }

  // Вычисление статистики за всё время.
  // Парсинг строк («12.5 км», «1 ч 23 мин») живёт в SavedRoute — здесь
  // только суммирование по моделям.
  double get _totalDistanceKm =>
      _workoutHistory.fold(0.0, (sum, workout) => sum + workout.distanceKm);

  int get _totalWorkouts => _workoutHistory.length;

  String get _totalDuration {
    final totalMinutes = _workoutHistory
        .fold<double>(0.0, (sum, workout) => sum + workout.durationMin)
        .round();
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    return '$hours ч $minutes мин';
  }

  /// Суммарный набор высоты по заездам (реальные значения, накопленные
  /// во время записи трека по GPS-высоте; 0 у старых записей без высоты).
  double get _totalElevationGain => _workoutHistory.fold<double>(
    0.0,
    (sum, workout) => sum + workout.elevationGainMeters,
  );

  Future<void> _editProfile() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _EditProfileDialog(profile: _profile),
    );
    if (result != null && mounted) {
      // Явное сохранение формы — единственный момент, когда кэш и облако
      // обновляются по желанию пользователя.
      await _profileProvider.updateProfile(
        weightKg: result['weightKg'] as double?,
        heightCm: result['heightCm'] as double?,
        age: result['age'] as int?,
        username: result['username'] as String?,
        status: result['status'] as String?,
        city: result['city'] as String?,
        preferredRidingType: result['preferredRidingType'] as RidingType?,
        gender: result['gender'] as String?,
        showWeight: result['showWeight'] as bool?,
        showAge: result['showAge'] as bool?,
        showGender: result['showGender'] as bool?,
      );
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Профиль обновлён')));
    }
  }

  Future<void> _openAvatarPicker() async {
    // Фото может быть только в облаке (например, после входа на новом
    // устройстве) — тогда тоже даём возможность его удалить.
    final hasPhoto = _photoFile != null || _isCloudAvatar;

    final result = await showModalBottomSheet<Object>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: hasPhoto ? 360 : 300,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Выберите аватар',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                    itemCount: avatarIcons.length,
                    itemBuilder: (context, index) {
                      final isSelected =
                          _photoFile == null && _profile.avatarIndex == index;
                      return GestureDetector(
                        onTap: () => Navigator.pop(sheetContext, index),
                        child: CircleAvatar(
                          radius: 30,
                          backgroundColor: isSelected
                              ? Colors.deepOrange
                              : Colors.deepOrange.shade100,
                          child: Icon(
                            avatarIcons[index],
                            size: 30,
                            color: isSelected
                                ? Colors.white
                                : Colors.deepOrange,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // Загрузка своего фото из галереи устройства.
                ListTile(
                  leading: const Icon(Icons.photo_library),
                  title: const Text('Загрузить из галереи'),
                  onTap: () => Navigator.pop(sheetContext, _galleryResult),
                ),
                if (hasPhoto)
                  ListTile(
                    leading: const Icon(
                      Icons.delete_outline,
                      color: Colors.red,
                    ),
                    title: const Text(
                      'Удалить фото',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: () =>
                        Navigator.pop(sheetContext, _removePhotoResult),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (result == null || !mounted) return;

    if (result == _galleryResult) {
      await _pickPhotoFromGallery();
    } else if (result == _removePhotoResult) {
      await _removePhoto();
    } else if (result is int) {
      await _selectAvatarIcon(result);
    }
  }

  /// Открывает галерею, копирует выбранный снимок в каталог приложения
  /// и сохраняет путь в профиле.
  Future<void> _pickPhotoFromGallery() async {
    try {
      final newPath = await _photoService.pickFromGallery();
      if (newPath == null) return;
      await _profileProvider.setPhotoPath(newPath);
      await _loadData(showSpinner: false);
      if (mounted)
        _showSnackBar(
          'Фото сохранено на телефоне. Облако обновится при доступной сети.',
        );
    } on ProfilePhotoException catch (error) {
      if (!mounted) return;
      _showSnackBar(
        error.message,
        action: error.isPermissionDenied
            ? SnackBarAction(label: 'Настройки', onPressed: _openAppSettings)
            : null,
      );
    }
  }

  /// Выбор встроенной иконки: пользовательское фото при этом убираем.
  Future<void> _selectAvatarIcon(int index) async {
    final previousPath = _profile.photoPath;
    await _profileProvider.updateProfile(avatarIndex: index);
    // Возврат к встроенной иконке убирает и локальное фото, и облачный URL
    // (setAvatarUrl(null) сбрасывает оба поля через clearPhoto).
    await _profileProvider.setAvatarUrl(null);
    if (previousPath != null) {
      await _photoService.deletePhoto(previousPath);
    }
    await _loadData(showSpinner: false);
    if (!mounted) return;
    _showSnackBar('Аватар обновлён');
  }

  /// Убирает пользовательское фото, возвращая иконку из набора.
  Future<void> _removePhoto() async {
    final previousPath = _profile.photoPath;
    await _profileProvider.setPhotoPath(null);
    await _photoService.deletePhoto(previousPath);
    await _loadData(showSpinner: false);
    if (!mounted) return;
    _showSnackBar('Фото удалено');
  }

  Future<void> _openAppSettings() async {
    try {
      await Geolocator.openAppSettings();
    } catch (error) {
      debugPrint('[Profile] Не удалось открыть настройки: $error');
    }
  }

  /// Переход в историю заездов (тап по плитке «Всего заездов»).
  Future<void> _openWorkoutHistory() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const WorkoutHistoryScreen()),
    );
    if (!mounted) return;
    // В истории заезд можно удалить, поэтому счётчик «Всего заездов»
    // пересчитываем при возврате (тихо, без полноэкранного спиннера).
    await _loadData(showSpinner: false);
  }

  void _showSnackBar(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text), action: action));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Профиль райдера')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_loadError!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => _loadData(),
                  child: const Text('Повторить'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль райдера'),
        actions: [
          IconButton(
            icon: _openingCustomizer
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.edit),
            onPressed: _customizeProfile,
            tooltip: 'Редактировать профиль',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Верхний блок: аватар, имя, статус, город
            _buildProfileHeader(),
            if (_presentation.isPending)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text(
                  'Оформление сохранено на телефоне. Синхронизация продолжится при появлении сети.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ProfileAwardsShowcase(style: _presentation),
            const SizedBox(height: 24),
            // Блок "Статистика за всё время"
            ActivityPanel(
              summary: ActivitySummary.fromRides(_workoutRepo.workoutHistory),
              isOwner: true,
              showAllTime: false,
            ),
            if (_workoutRepo.hasPendingSync)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Ожидается синхронизация: часть активности пока видна только вам.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            if (_activityPublic != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Показывать активность в публичном профиле'),
                subtitle: const Text(
                  'Серия и итоги тренировок. Маршруты и координаты не публикуются.',
                ),
                value: _activityPublic!,
                onChanged: _savingActivityPrivacy
                    ? null
                    : _setActivityVisibility,
              ),
            const SizedBox(height: 24),
            _buildAllTimeStats(),
            const SizedBox(height: 24),
            // Блок "Прогресс за месяц"
            _buildProgressSection(),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.insights, color: Colors.deepOrange),
                title: const Text('Тренировочный центр'),
                subtitle: const Text(
                  'Календарь, ритм недели и личные ориентиры',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const TrainingCenterScreen(),
                    ),
                  );
                  if (mounted) await _loadData(showSpinner: false);
                },
              ),
            ),
            const SizedBox(height: 24),
            // Дополнительная информация (вес, рост, возраст)
            _buildAdditionalInfo(),
            const SizedBox(height: 24),
            // Секция "Мой гараж"
            _buildGarageSection(),
          ],
        ),
      ),
    );
  }

  /// Есть ли публичный URL аватара в облаке (store в `profiles.avatar_url`).
  bool get _isCloudAvatar {
    final url = _profile.avatarUrl;
    return url != null &&
        (url.startsWith('http://') || url.startsWith('https://'));
  }

  /// Аватар: локальное фото, затем облачный URL, иначе иконка из набора.
  Widget _buildAvatar(IconData fallbackIcon, {double radius = 40}) {
    final photo = _photoFile;

    if (photo != null) {
      // Имя файла всегда новое (avatar_<timestamp>.jpg), поэтому Flutter не
      // покажет закэшированную старую картинку после замены фото.
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.deepOrange.shade100,
        backgroundImage: FileImage(photo),
      );
    }

    // Локального файла нет, но есть аватар в облаке (синхронизирован с
    // другого устройства) — показываем его по сети.
    if (_isCloudAvatar) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Colors.deepOrange.shade100,
        // Кэшированное изображение: повторно не скачивается с Supabase.
        backgroundImage: CachedNetworkImageProvider(_profile.avatarUrl!),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.deepOrange,
      child: Icon(fallbackIcon, size: radius, color: Colors.white),
    );
  }

  Future<void> _customizeProfile({String? initialSection}) async {
    if (_openingCustomizer) return;
    final owner = UserScope.currentUserId();
    if (owner == null) return;
    setState(() => _openingCustomizer = true);
    try {
      final service = ProfilePresentationService();
      final presentation = await service.loadCached(owner) ?? _presentation;
      unawaited(
        service
            .load(owner, refreshEarned: true)
            .catchError((Object _) => presentation),
      );
      if (!mounted || UserScope.currentUserId() != owner) return;
      final icon =
          avatarIcons[_profile.avatarIndex.clamp(0, avatarIcons.length - 1)];
      final journey = AchievementJourney(_workoutRepo.workoutHistory);
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ProfileCustomizeScreen(
            initial: presentation,
            name: _profile.username,
            initialSection: initialSection,
            onEditDetails: () async {
              await _editProfile();
              return _profile.username;
            },
            avatar: _buildAvatar(icon),
            onChangeAvatar: () async {
              await _openAvatarPicker();
              final currentIcon =
                  avatarIcons[_profile.avatarIndex.clamp(
                    0,
                    avatarIcons.length - 1,
                  )];
              return _buildAvatar(currentIcon);
            },
            availableRanks: JourneyRank.all
                .where((rank) => rank.xp <= journey.xp)
                .toList(),
          ),
        ),
      );
      if (saved == true && mounted) await _loadData(showSpinner: false);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось открыть сохранённый профиль. Попробуйте ещё раз.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingCustomizer = false);
    }
  }

  Widget _buildProfileHeader() {
    final journey = AchievementJourney(_workoutRepo.workoutHistory);
    final icon =
        avatarIcons[_profile.avatarIndex.clamp(0, avatarIcons.length - 1)];
    return ProfileIdentityCard(
      avatarDiameter: 80,
      name: _profile.username,
      style: _presentation,
      avatar: GestureDetector(
        onTap: _openAvatarPicker,
        child: _buildAvatar(icon),
      ),
      status: _profile.status,
      city: _profile.city,
      sport: _profile.preferredRidingType.label,
      title:
          _presentation.selectedRank?.name ??
          _presentation.title?.label ??
          (_presentation.hasTitleSelection ? null : _equippedTitle) ??
          journey.rank.name,
      titleIcon:
          _presentation.selectedRank?.icon ??
          _presentation.title?.icon ??
          (_presentation.hasTitleSelection ? null : _equippedTitleIcon) ??
          journey.rank.icon,
      onCustomize: _customizeProfile,
      onEditCover: () => _customizeProfile(initialSection: 'cover'),
      onEditTitle: () => _customizeProfile(initialSection: 'title'),
      onEditBio: () => _customizeProfile(initialSection: 'bio'),
    );
  }

  Future<void> _setActivityVisibility(bool visible) async {
    final owner = UserScope.currentUserId();
    if (owner == null) return;
    setState(() => _savingActivityPrivacy = true);
    try {
      await ActivityService().configure(visible: visible);
      if (mounted && UserScope.currentUserId() == owner) {
        setState(() => _activityPublic = visible);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось изменить приватность активности'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingActivityPrivacy = false);
    }
  }

  Widget _buildAllTimeStats() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Статистика за всё время',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          childAspectRatio: 1.15 / MediaQuery.textScalerOf(context).scale(1),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          children: [
            _statCard(
              'Общий пробег',
              '${_totalDistanceKm.toStringAsFixed(1)} км',
              Icons.directions_bike,
            ),
            // Кликабельная плитка: открывает историю заездов.
            _statCard(
              'Всего заездов',
              '$_totalWorkouts',
              Icons.list,
              onTap: _openWorkoutHistory,
            ),
            _statCard('Общее время', _totalDuration, Icons.timer),
            _statCard(
              'Набор высоты',
              '${_totalElevationGain.toStringAsFixed(0)} м',
              Icons.terrain,
            ),
          ],
        ),
      ],
    );
  }

  /// Плитка статистики.
  ///
  /// Если передан [onTap], карточка становится кликабельной: InkWell лежит
  /// ВНУТРИ Card (Card — это Material), поэтому ripple рисуется на самой
  /// карточке и виден. Если обернуть InkWell снаружи Card, волна ушла бы на
  /// Material страницы ПОД карточкой и её не было бы видно.
  /// `clipBehavior: Clip.antiAlias` обрезает волну по скруглённым углам.
  Widget _statCard(
    String title,
    String value,
    IconData icon, {
    VoidCallback? onTap,
  }) {
    final content = Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: Colors.deepOrange),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              maxLines: 1,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              title,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
              maxLines: 2,
            ),
          ),
        ],
      ),
    );

    return Card(
      elevation: 2,
      clipBehavior: onTap == null ? Clip.none : Clip.antiAlias,
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              // Скругление как у Card в Material 3 — чтобы граница волны
              // совпадала с краем карточки.
              borderRadius: BorderRadius.circular(12),
              child: content,
            ),
    );
  }

  /// Пробег за выбранный период из локальной истории заездов.
  double _distanceFor(ProgressPeriod period, DateTime now) {
    double total = 0;
    for (final workout in _workoutHistory) {
      if (period.contains(workout.dateTime, now)) {
        total += workout.distanceKm;
      }
    }
    return total;
  }

  /// «400 км» / «12.5 км» — без лишнего нуля у целых значений.
  static String _formatKm(double value) => value == value.roundToDouble()
      ? '${value.round()} км'
      : '${value.toStringAsFixed(1)} км';

  Future<void> _changeProgressPeriod(ProgressPeriod period) async {
    if (period == _period) return;
    setState(() => _period = period);
    // Выбор запоминаем, чтобы он сохранялся между запусками.
    await _goalsRepo.setPeriod(period);
  }

  /// Диалог смены цели для текущего периода.
  ///
  /// Сам ввод живёт в отдельном виджете [_GoalDialog]: если создавать
  /// TextEditingController прямо здесь и освобождать его сразу после
  /// `showDialog`, контроллер окажется уничтожен, пока диалог ещё доигрывает
  /// анимацию закрытия — Flutter падает с «A TextEditingController was used
  /// after being disposed».
  Future<void> _editGoal() async {
    final newGoal = await showDialog<double>(
      context: context,
      builder: (context) => _GoalDialog(
        period: _period,
        initialGoalKm: _goalsRepo.goalFor(_period),
      ),
    );

    if (newGoal == null || !mounted) return;
    try {
      await _goalsRepo.setGoal(_period, newGoal);
    } catch (_) {
      if (mounted) {
        _showSnackBar('Не удалось сохранить цель. Повторите попытку.');
      }
      return;
    }
    if (!mounted) return;
    setState(() {});
    _showSnackBar(
      '${_period.goalTitle}: ${_formatKm(_goalsRepo.goalFor(_period))}',
    );
  }

  Widget _buildProgressSection() {
    final now = DateTime.now();
    final goal = _goalsRepo.goalFor(_period);
    final current = _distanceFor(_period, now);
    // Знаменатель защищаем от нуля, значение полосы — от выхода за [0, 1].
    final double ratio = goal > 0 ? current / goal : 0.0;
    final double progress = ratio.clamp(0.0, 1.0);
    final String percentLabel =
        '${(ratio * 100).clamp(0, 999).toStringAsFixed(0)} %';
    final bool goalReached = ratio >= 1.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _period.blockTitle,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        // Переключатель периода: День / Неделя / Месяц / Год.
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ProgressPeriod>(
            segments: [
              for (final period in ProgressPeriod.values)
                ButtonSegment<ProgressPeriod>(
                  value: period,
                  label: Text(period.label),
                ),
            ],
            selected: {_period},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                _changeProgressPeriod(selection.first),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    key: const ValueKey('profile-distance-goal-progress'),
                    value: progress,
                    minHeight: 10,
                    backgroundColor: Colors.grey[300],
                    valueColor: AlwaysStoppedAnimation<Color>(
                      goalReached ? Colors.green : Colors.deepOrange,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _period.metricLabel,
                      style: TextStyle(fontSize: 16, color: Colors.grey[700]),
                    ),
                    const SizedBox(width: 12),
                    // Значение забирает остаток строки и переносится —
                    // при увеличенном системном шрифте строка не переполняется.
                    Expanded(
                      child: Text(
                        '${current.toStringAsFixed(1)} км',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    // Кликабельная плашка цели: тап открывает диалог смены цели.
                    Flexible(child: _buildGoalChip(goal)),
                    const Spacer(),
                    Text(
                      percentLabel,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: goalReached
                            ? Colors.green[700]
                            : Colors.grey[700],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Плашка «Цель: X км» с карандашом; по тапу открывается диалог цели.
  Widget _buildGoalChip(double goal) {
    return InkWell(
      onTap: _editGoal,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.flag_outlined, size: 16, color: Colors.deepOrange),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Цель: ${_formatKm(goal)}',
                style: TextStyle(fontSize: 14, color: Colors.grey[700]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.edit, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildAdditionalInfo() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Дополнительная информация',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _infoRow('Вес', '${_profile.weightKg.toStringAsFixed(1)} кг'),
                const Divider(),
                _infoRow('Рост', '${_profile.heightCm.toStringAsFixed(0)} см'),
                const Divider(),
                _infoRow('Возраст', '${_profile.age} лет'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGarageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Мой гараж',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        GarageProfileGallery(key: ValueKey(_garageRevision), isOwner: true),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GarageScreen()),
            );
            if (mounted) await _loadData(showSpinner: false);
          },
          icon: const Icon(Icons.directions_bike),
          label: const Text('Управление гаражом'),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    // Та же ловушка, что и в карточке гаража: два НЕ-гибких Text в Row
    // измеряются без ограничения по ширине и переполняют строку при длинном
    // значении или увеличенном системном шрифте.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Подписи здесь — короткие константы ('Вес', 'Рост', 'Возраст'),
          // поэтому фиксированная ширина у них безопасна, а значение забирает
          // остаток строки и переносится, если не помещается.
          Text(label, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// Диалог смены цели по дистанции для выбранного периода.
class _GoalDialog extends StatefulWidget {
  const _GoalDialog({required this.period, required this.initialGoalKm});

  final ProgressPeriod period;
  final double initialGoalKm;

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialGoalKm.round().toString(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validateGoal(String? raw) {
    final value = double.tryParse((raw ?? '').trim().replaceAll(',', '.'));
    if (value == null) {
      return 'Введите цель числом, например 400';
    }
    if (value < ProgressPeriod.minGoalKm || value > ProgressPeriod.maxGoalKm) {
      return 'Цель должна быть от ${ProgressPeriod.minGoalKm.round()} '
          'до ${ProgressPeriod.maxGoalKm.round()} км';
    }
    return null;
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.pop(context, double.parse(_controller.text.trim()));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Укажите цель от ${ProgressPeriod.minGoalKm.round()} '
          'до ${ProgressPeriod.maxGoalKm.round()} км',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.period.goalTitle),
      content: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4), // 5000 — максимум
          ],
          validator: _validateGoal,
          onFieldSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: 'Цель',
            suffixText: 'км',
            hintText: '400',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        ElevatedButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}

// Диалог редактирования профиля
class _EditProfileDialog extends StatefulWidget {
  final UserProfile profile;

  const _EditProfileDialog({required this.profile});

  @override
  State<_EditProfileDialog> createState() => __EditProfileDialogState();
}

class __EditProfileDialogState extends State<_EditProfileDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late TextEditingController _usernameController;
  late TextEditingController _statusController;
  late TextEditingController _cityController;
  late TextEditingController _weightController;
  late TextEditingController _heightController;
  late TextEditingController _ageController;
  RidingType? _selectedRidingType;
  String? _gender;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController(text: widget.profile.username);
    _statusController = TextEditingController(text: widget.profile.status);
    _cityController = TextEditingController(text: widget.profile.city);
    // Значения показываем сразу в целевом формате: вес — один знак после
    // запятой (75.5), рост — целые сантиметры, плюс страховочный clamp,
    // если в старом профиле лежало что-то нереалистичное.
    _weightController = TextEditingController(
      text: UserProfile.clampWeight(widget.profile.weightKg).toStringAsFixed(1),
    );
    _heightController = TextEditingController(
      text: UserProfile.clampHeight(widget.profile.heightCm).toStringAsFixed(0),
    );
    _ageController = TextEditingController(
      text: UserProfile.clampAge(widget.profile.age).toString(),
    );
    _selectedRidingType = widget.profile.preferredRidingType;
    _gender = widget.profile.gender;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _statusController.dispose();
    _cityController.dispose();
    _weightController.dispose();
    _heightController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  // ── Валидация ────────────────────────────────────────────────────────────
  // Границы берём из UserProfile, чтобы они не разъезжались с хранилищем.

  /// Разбор числа: принимает и точку, и запятую («75,5» == «75.5»).
  static double? _parseDecimal(String? raw) {
    final text = (raw ?? '').trim().replaceAll(',', '.');
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  String? _validateWeight(String? raw) {
    final value = _parseDecimal(raw);
    if (value == null) {
      return 'Введите вес числом, например 75.5';
    }
    if (!UserProfile.isValidWeight(value)) {
      return 'Укажите реалистичный вес от ${UserProfile.minWeightKg.round()} '
          'до ${UserProfile.maxWeightKg.round()} кг';
    }
    return null;
  }

  String? _validateHeight(String? raw) {
    final value = _parseDecimal(raw);
    if (value == null) {
      return 'Введите рост числом, например 175';
    }
    if (!UserProfile.isValidHeight(value)) {
      return 'Укажите реалистичный рост от ${UserProfile.minHeightCm.round()} '
          'до ${UserProfile.maxHeightCm.round()} см';
    }
    return null;
  }

  String? _validateAge(String? raw) {
    final value = int.tryParse((raw ?? '').trim());
    if (value == null) {
      return 'Введите возраст числом, например 30';
    }
    if (!UserProfile.isValidAge(value)) {
      return 'Укажите реалистичный возраст от ${UserProfile.minAge} '
          'до ${UserProfile.maxAge} лет';
    }
    return null;
  }

  void _save() {
    // Валидация всей формы: подсветит конкретные поля, а не сохранит «как есть».
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Проверьте параметры: вес ${UserProfile.minWeightKg.round()}–'
            '${UserProfile.maxWeightKg.round()} кг, рост '
            '${UserProfile.minHeightCm.round()}–${UserProfile.maxHeightCm.round()} см, '
            'возраст ${UserProfile.minAge}–${UserProfile.maxAge} лет',
          ),
        ),
      );
      return;
    }

    Navigator.pop(context, <String, dynamic>{
      'username': _usernameController.text.trim(),
      'status': _statusController.text.trim(),
      'city': _cityController.text.trim(),
      'preferredRidingType': _selectedRidingType,
      // Значения заведомо валидны, но clamp оставляем как вторую линию защиты.
      'weightKg': UserProfile.clampWeight(
        _parseDecimal(_weightController.text) ?? widget.profile.weightKg,
      ),
      'heightCm': UserProfile.clampHeight(
        _parseDecimal(_heightController.text) ?? widget.profile.heightCm,
      ),
      'age': UserProfile.clampAge(
        int.tryParse(_ageController.text.trim()) ?? widget.profile.age,
      ),
      'gender': _gender,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Основные сведения'),
      content: Form(
        key: _formKey,
        // Ошибка появляется сразу после того, как пользователь тронул поле,
        // а не только по нажатию «Сохранить».
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: 'Имя пользователя',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _statusController,
                decoration: const InputDecoration(labelText: 'Статус'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _cityController,
                decoration: const InputDecoration(labelText: 'Город'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<RidingType>(
                initialValue: _selectedRidingType,
                decoration: const InputDecoration(
                  labelText: 'Предпочитаемый тип катания',
                ),
                items: RidingType.values.map((type) {
                  return DropdownMenuItem<RidingType>(
                    value: type,
                    child: Text(type.label),
                  );
                }).toList(),
                onChanged: (value) =>
                    setState(() => _selectedRidingType = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _gender,
                decoration: const InputDecoration(labelText: 'Пол'),
                items: const [
                  DropdownMenuItem(value: 'male', child: Text('Мужской')),
                  DropdownMenuItem(value: 'female', child: Text('Женский')),
                ],
                onChanged: (value) => setState(() => _gender = value),
              ),
              const SizedBox(height: 8),
              // Приватность (вес/возраст/пол) перенесена в Настройки →
              // раздел «Приватность».
              // Вес: только цифры + один разделитель, максимум 1 знак после
              // запятой и 3 цифры до (то есть 250.0 — предел ввода).
              TextFormField(
                controller: _weightController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: const [
                  _DecimalTextInputFormatter(
                    decimalPlaces: 1,
                    maxIntegerDigits: 3,
                  ),
                ],
                validator: _validateWeight,
                decoration: const InputDecoration(
                  labelText: 'Вес',
                  suffixText: 'кг',
                  hintText: '75.5',
                ),
              ),
              const SizedBox(height: 12),
              // Рост: целые сантиметры, максимум 3 цифры.
              TextFormField(
                controller: _heightController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                validator: _validateHeight,
                decoration: const InputDecoration(
                  labelText: 'Рост',
                  suffixText: 'см',
                  hintText: '175',
                ),
              ),
              const SizedBox(height: 12),
              // Возраст: целое число, максимум 3 цифры.
              TextFormField(
                controller: _ageController,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                validator: _validateAge,
                decoration: const InputDecoration(
                  labelText: 'Возраст',
                  suffixText: 'лет',
                  hintText: '30',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        ElevatedButton(onPressed: _save, child: const Text('Сохранить')),
      ],
    );
  }
}

/// Разрешает ввод только цифр и одного десятичного разделителя («.» или «,»)
/// с ограничением числа знаков до и после него.
///
/// Пример (decimalPlaces: 1, maxIntegerDigits: 3): «75.5» — можно,
/// «75.55», «148852» и «12.3.4» — нельзя.
class _DecimalTextInputFormatter extends TextInputFormatter {
  const _DecimalTextInputFormatter({
    this.decimalPlaces = 1,
    this.maxIntegerDigits = 3,
  });

  final int decimalPlaces;
  final int maxIntegerDigits;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue;

    // Разрешены только цифры и один разделитель в любом месте строки.
    if (!RegExp(r'^\d*[.,]?\d*$').hasMatch(text)) return oldValue;

    final parts = text.split(RegExp(r'[.,]'));
    if (parts.length > 2) return oldValue; // второй разделитель
    if (parts[0].length > maxIntegerDigits) return oldValue;
    if (parts.length == 2 && parts[1].length > decimalPlaces) return oldValue;

    return newValue;
  }
}
