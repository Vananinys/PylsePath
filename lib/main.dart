import 'data/trail_appearance.dart';
import 'widgets/activity_trail_layer.dart';
import 'services/usage_statistics.dart';
import 'widgets/home_steps_pill.dart';
import 'widgets/map_home_actions.dart';
import 'widgets/incoming_chat_preview.dart';
import 'widgets/ride_preparation_panel.dart';
import 'services/presence_service.dart';
import 'models/shared_route.dart';
import 'services/group_ride_service.dart';
import 'widgets/route_share_sheet.dart';
import 'widgets/round_trip_planner.dart';
import 'widgets/workout_finish_sheet.dart';
import 'models/gps_signal.dart';
import 'models/workout_record.dart';
import 'models/workout_details.dart';
import 'widgets/route_waypoints_editor.dart';
import 'screens/workout_detail_screen.dart';
import 'widgets/map_sticker_flight.dart';
import 'services/smooth_map_position.dart';
import 'services/smooth_map_heading.dart';
import 'widgets/friend_motion_layer.dart';
import 'screens/events_screen.dart';
import 'widgets/friend_trails_layer.dart';
import 'services/owned_trail_style_service.dart';

import 'dart:async';
import 'dart:math' as math;

import 'widgets/gps_signal_indicator.dart';
import 'utils/gpx_utils.dart';
import 'widgets/gear_advisor_card.dart';
import 'screens/vehicle_detail_screen.dart';
import 'services/personal_records.dart';
import 'services/achievements_service.dart';
import 'services/achievement_journey.dart';
import 'services/activity_service.dart';
import 'data/user_scope.dart';
import 'data/progress_backup_repository.dart';
import 'data/progress_goals_repository.dart';
import 'widgets/ride_achievement_banner.dart';
import 'widgets/widget_size_observer.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'data/workout_history_repository.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'ui/app_theme.dart';
import 'services/profile_presentation_service.dart';
import 'services/network_recovery_sync.dart';
import 'models/activity_type.dart';
import 'models/chat_message.dart';
import 'models/saved_route.dart';
import 'models/route_step.dart';
import 'models/friend_profile.dart';
import 'models/user_profile.dart';
import 'data/app_settings.dart';
import 'data/navigation_preferences.dart';
import 'services/daily_activity_service.dart';
import 'services/background_location_service.dart';
import 'screens/daily_activity_screen.dart';
import 'screens/route_builder_screen.dart';
import 'data/saved_routes_repository.dart';
import 'data/saved_places_repository.dart';
import 'models/saved_place.dart';
import 'screens/saved_places_screen.dart';
import 'data/ui_modules.dart';
import 'services/geocoding_service.dart';
import 'services/weather_service.dart';
import 'services/chat_service.dart';
import 'services/friend_service.dart';
import 'services/notification_service.dart';
import 'services/push_service.dart';
import 'services/offline_maps_service.dart';
import 'services/compass_service.dart';
import 'services/auth_service.dart';
import 'models/camera_lock_mode.dart';
import 'models/map_mark.dart';
import 'services/map_marks_service.dart';
import 'services/overpass_service.dart';
import 'state/profile_provider.dart';
import 'controllers/map_navigation_controller.dart';
import 'widgets/route_details_bottom_sheet.dart';
import 'widgets/map_ui_overlays.dart';
import 'widgets/workout_stats_bottom_sheet.dart';
import 'widgets/pre_ride_widget.dart';
import 'widgets/group_start_choice.dart';
import 'widgets/vehicle_selector_sheet.dart';
import 'widgets/rider_marker.dart';
import 'screens/auth_gate.dart';
import 'screens/saved_routes_screen.dart';
import 'screens/training_center_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/garage_screen.dart';
import 'screens/achievements_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/public_profile_screen.dart';
import 'screens/chats_list_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/group_ride_screen.dart';
import 'widgets/friend_map_panel.dart';
import 'widgets/app_update_gate.dart';
import 'screens/about_screen.dart';
import 'screens/ride_heatmap_screen.dart';
import 'screens/satellite_settings_screen.dart';
import 'services/satellite_map.dart';
import 'widgets/heatmap_path_layer.dart';
import 'widgets/map_credits.dart';
import 'services/owner_service.dart';
import 'screens/offline_maps_screen.dart';

part 'src/map_screen/urban_map_mixin.dart';
part 'src/map_screen/camera_compass_mixin.dart';
part 'src/map_screen/chat_push_mixin.dart';
part 'src/map_screen/route_actions_mixin.dart';
part 'src/map_screen/drawer_mixin.dart';
part 'src/map_screen/markers_mixin.dart';
part 'src/map_screen/ride_sheets_mixin.dart';

/// Отладочный переключатель эмуляции вращения компаса.
///
/// Если магнитометр И GPS- bearing отдают 0.0, `CompassService` не сбрасывает
/// азимут в 0.0, а держит последнее валидное значение. При этом флаге, если
/// датчики «залипли» на нуле, включается эмуляция вращения +2.0° каждые 100 мс —
/// чтобы визуально убедиться, что `_mapController.moveAndRotate(...)` и
/// `RiderMarker` действительно вращаются.
///
/// Отладочный режим: в релизной сборке должен оставаться `false`.
const bool kEnableMockHeadingDebug = false;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PushService.prepareBackgroundDelivery();

  // Авторизация и синхронизация (profiles / rides).
  try {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabasePublishableKey,
      authOptions: const FlutterAuthClientOptions(
        // PKCE: письмо возвращает ?code=..., который SDK обменивает на сессию.
        authFlowType: AuthFlowType.pkce,
        // true (по умолчанию, указано явно для наглядности): SDK сам ловит
        // входящие ссылки через app_links и вызывает getSessionFromUrl().
        // Ссылка вида pulsepath://login-callback?code=... -> появляется сессия
        // -> onAuthStateChange -> AuthGate показывает карту.
        detectSessionInUri: true,
      ),
    );
    debugPrint('[App] Supabase инициализирован: ${AppConfig.supabaseUrl}');
    debugPrint('[App] redirect URL для писем: ${AppConfig.authRedirectUrl}');
  } catch (error) {
    // Без сети приложение всё равно должно запуститься: карта и локальные
    // данные работают, а вход покажет понятную ошибку.
    debugPrint('[App] Не удалось инициализировать Supabase: $error');
  }

  // Офлайн-карты: инициализация кэша тайлов в фоне (не блокирует запуск).
  OfflineMapsService.initialise();

  final settings = AppSettings();
  await settings.load();
  try {
    final package = await PackageInfo.fromPlatform();
    UsageStatistics.instance.version =
        '${package.version}+${package.buildNumber}';
    UsageStatistics.instance.record(UsageEvent.appOpened);
  } catch (_) {
    /* Optional local counters never block startup. */
  }
  await NavigationPreferences.instance.load();
  OwnedTrailStyleService.instance.start();
  try {
    await TrailAppearance.instance.load();
  } catch (_) {
    /* Optional appearance never prevents startup. */
  }
  final repository = SavedRoutesRepository();
  runApp(PulsePathApp(settings: settings, repository: repository));
}

class PulsePathApp extends StatefulWidget {
  final AppSettings settings;
  final SavedRoutesRepository repository;

  const PulsePathApp({
    super.key,
    required this.settings,
    required this.repository,
  });

  @override
  State<PulsePathApp> createState() => _PulsePathAppState();
}

class _PulsePathAppState extends State<PulsePathApp> {
  @override
  Widget build(BuildContext context) {
    // ProfileProvider живёт над всем приложением: кэш профиля сохраняется
    // между открытиями экрана профиля.
    return MaterialApp(
      title: 'PulsePath Navigator',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      theme: pulsePathTheme(),
      home: AppUpdateGate(
        child: AuthGate(
          authedChild: PulsePathMapScreen(
            settings: widget.settings,
            repository: widget.repository,
          ),
        ),
      ),
    );
  }
}

class PulsePathMapScreen extends StatefulWidget {
  final AppSettings settings;
  final SavedRoutesRepository repository;

  const PulsePathMapScreen({
    super.key,
    required this.settings,
    required this.repository,
  });

  @override
  State<PulsePathMapScreen> createState() => _PulsePathMapScreenState();
}

/// База состояния экрана карты: поля и общие помощники.
///
/// Экран разбит на миксины (части этой библиотеки), которые работают с
/// этими полями; разбивка чисто механическая — поведение не менялось.
abstract class _MapScreenStateBase extends State<PulsePathMapScreen>
    with WidgetsBindingObserver {
  final SavedRoutesRepository _repository = SavedRoutesRepository();
  final ChatService _chatService = ChatService();
  void Function(ChatMessage message)? _chatListener;
  int _searchGeneration = 0;
  bool _nearbySearch = true;
  String? _searchLocality;
  bool _isForeground = true;
  bool _refreshingGps = false;
  bool _centerOnNextGpsFix = false;
  bool _openingPushChat = false;
  bool _pushErrorShown = false;
  Timer? _notificationPollTimer;
  Timer? _achievementPollTimer;
  final _achievementBanner = AchievementBannerController();
  double _workoutHudHeight = 220;
  double _preRideHudHeight = 380;
  LiveAchievementSession? _liveAchievements;
  String? _achievementSessionKey;
  bool _preparingAchievements = false;

  Future<void> _checkRideAchievements() async {
    if (!mounted) return;
    final controller = _navigationController;
    if (!controller.isWorkoutActive && !controller.isWorkoutPaused) {
      _liveAchievements = null;
      _achievementSessionKey = null;
      _achievementBanner.dismiss();
      return;
    }
    final owner = UserScope.currentUserId();
    final sessionKey = UserScope.keyFor(
      'ride_achievement_announced_${controller.workoutSessionId}',
      owner,
    );
    if (_achievementSessionKey != sessionKey) {
      if (_preparingAchievements) return;
      _preparingAchievements = true;
      try {
        final history = WorkoutHistoryRepository();
        await history.load();
        final preferences = await SharedPreferences.getInstance();
        if (!mounted ||
            owner != UserScope.currentUserId() ||
            (!controller.isWorkoutActive && !controller.isWorkoutPaused) ||
            sessionKey !=
                UserScope.keyFor(
                  'ride_achievement_announced_${controller.workoutSessionId}',
                  owner,
                )) {
          return;
        }
        _liveAchievements = LiveAchievementSession(
          List.of(history.workoutHistory),
        );
        _liveAchievements!.remember(
          preferences.getStringList(sessionKey) ?? const [],
        );
        _achievementSessionKey = sessionKey;
      } catch (error) {
        debugPrint('[Achievements] history unavailable: $error');
        return;
      } finally {
        _preparingAchievements = false;
      }
    }
    if (!controller.isWorkoutActive) return;
    final draft = SavedRoute(
      title: 'Текущий заезд',
      localId: controller.workoutSessionId,
      workoutDetails: controller.achievementWorkoutDetails,
      distance: '',
      duration: '',
      surfaceSummary: '',
      distanceMeters: controller.totalDistanceMeters,
      durationSeconds: controller.activeWorkoutDuration.inSeconds,
      finishPoint: controller.currentLocation,
      routePoints: const [],
      activityType: controller.workoutActivity,
      elevationGainMeters: controller.workoutElevationGain,
      createdAt: controller.workoutSessionStartedAt,
    );
    final newly = _liveAchievements?.check(draft) ?? [];
    if (newly.isNotEmpty) {
      try {
        final preferences = await SharedPreferences.getInstance();
        if (!mounted ||
            sessionKey != _achievementSessionKey ||
            owner != UserScope.currentUserId()) {
          return;
        }
        await preferences.setStringList(
          sessionKey,
          _liveAchievements!.announcedIds,
        );
      } catch (error) {
        debugPrint('[Achievements] milestone receipt unavailable: $error');
      }
    }
    if (!mounted ||
        sessionKey != _achievementSessionKey ||
        !controller.isWorkoutActive ||
        owner != UserScope.currentUserId()) {
      return;
    }
    if (_isForeground && newly.isNotEmpty) _achievementBanner.show(newly);
  }

  final _syncHistory = WorkoutHistoryRepository();
  bool _syncHistoryLoaded = false, _syncingHistory = false;
  DateTime? _lastHistorySync;
  DateTime? _lastHistoryPull;
  NetworkRecoverySync? _networkRecovery;
  bool get _useOfflineMap => NavigationPreferences.instance.cachedMapOnly || (_networkRecovery?.offline ?? false);
  bool get _usePreparedMapSource => NavigationPreferences.instance.cachedMapOnly ||
      ((_networkRecovery?.offline ?? false) && AppConfig.offlineTileUrl.isNotEmpty);

  void _retryLocalChanges(bool restored) {
    if (!mounted || !_isForeground || UserScope.currentUserId() == null) return;
    unawaited(ProfilePresentationService().syncPending());
    unawaited(
      context.read<ProfileProvider>().retryPendingChanges().catchError((
        Object error,
      ) {
        debugPrint('[Profile] retry deferred: $error');
      }),
    );
    if (restored) _lastHistorySync = null;
    unawaited(_syncPendingHistory());
  }

  Future<void> _syncPendingHistory() async {
    final owner = UserScope.currentUserId();
    if (!mounted ||
        !_isForeground ||
        _syncingHistory ||
        _navigationController.isWorkoutActive ||
        _navigationController.isWorkoutPaused ||
        _navigationController.isSavingWorkout) {
      return;
    }
    final now = DateTime.now();
    if (_lastHistorySync != null &&
        now.difference(_lastHistorySync!) < const Duration(minutes: 1)) {
      return;
    }
    _lastHistorySync = now;
    _syncingHistory = true;
    try {
      if (!_syncHistoryLoaded) {
        await _syncHistory.load();
        _syncHistoryLoaded = true;
      }
      if (_syncHistory.hasPendingSync) {
        await _syncHistory.retryUnsynced(maxItems: 5);
      }
      if (!mounted || owner != UserScope.currentUserId()) return;
      if (_lastHistoryPull == null ||
          now.difference(_lastHistoryPull!) >= const Duration(minutes: 5)) {
        try {
          await _syncHistory.restoreFromCloud();
          unawaited(_syncHistory.reconcileWalkingSteps());
          _lastHistoryPull = now;
          if (mounted && _heatMode != 0) setState(() => _heatRevision++);
        } catch (error) {
          debugPrint('[Progress] history restore deferred: $error');
        }
      }
      if (!mounted || owner != UserScope.currentUserId()) return;
      await AchievementsService.captureProgress(_syncHistory.workoutHistory);
      try {
        await ProgressBackupRepository().sync();
        if (!mounted || owner != UserScope.currentUserId()) return;
        await AchievementsService.restoreProgress();
        await DailyActivityService.instance.restoreCloudBackup();
      } catch (error) {
        debugPrint('[Progress] cloud backup deferred: $error');
      }
      if (mounted && owner == UserScope.currentUserId())
        await ProgressGoalsRepository().load();
    } catch (error) {
      debugPrint('[History] pending sync deferred: $error');
    } finally {
      _syncingHistory = false;
    }
  }

  final MapController _mapController = MapController();
  final DraggableScrollableController _routeSheetController =
      DraggableScrollableController();
  final SmoothMapPosition _displayPosition = SmoothMapPosition(
    const LatLng(52.5200, 13.4050),
  );
  final TextEditingController _searchController = TextEditingController();
  final MapNavigationController _navigationController =
      MapNavigationController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;
  Timer? _searchDebounce;

  // Компас и режим камеры.
  //
  // enableMockRotation        — разрешает эмуляцию вращения (см. kEnableMockHeadingDebug);
  // autoMockRotationOnZero    — включает её автоматически, когда компас И GPS дают 0.0;
  // mockStepDeg/mockInterval  — +2.0° каждые 100 мс.
  final CompassService _compassService = CompassService(
    enableMockRotation: kEnableMockHeadingDebug,
    autoMockRotationOnZero: kEnableMockHeadingDebug,
    mockStepDeg: 2.0,
    mockInterval: const Duration(milliseconds: 100),
  );
  CameraLockMode _cameraLockMode = CameraLockMode.followAndHeading;
  final SmoothMapHeading _displayHeading = SmoothMapHeading();
  double _currentHeading = 0.0;
  bool _isMapReady = false;

  /// Показываем подсказку про эмуляцию только один раз за сессию.
  bool _mockNoticeShown = false;

  /// Версия приложения из метаданных сборки (pubspec.yaml → versionName /
  /// CFBundleShortVersionString). null, пока не загрузилась.
  String? _appVersion;

  // --- Защита от случайных нажатий (Screen Touch Lock) ---
  bool _isScreenLocked = false;

  /// Открыта ли панель подготовки к заезду (Pre-Ride HUD). Пока закрыта,
  /// внизу карты видна компактная панель с кнопкой «Свободный заезд».
  bool _isPreRideOpen = false;
  String? _preRideGroupRoomId;
  bool _isChoosingRoute = false;
  final FocusNode _searchFocusNode = FocusNode();
  bool _startingRide = false;
  bool _finishingRide = false;

  /// Погода в точке старта для HUD предзапуска (null — не показываем).
  WeatherInfo? _preRideWeather;
  DateTime? _lastWeatherFetchAt;
  bool _weatherLoading = false;
  Timer? _weatherRefreshTimer;
  StreamSubscription<Object?>? _gpxImportSubscription;
  bool _importedGpxPendingFit = false;

  // --- Панель друга на карте (Этап C) ---
  FriendProfile? _selectedMapFriend;
  final FriendService _friendServiceInstance = FriendService();
  final ValueNotifier<List<MapStickerEffect>> _flyingStickersNotifier =
      ValueNotifier([]);
  int _stickerSequence = 0;

  void _completeStickerEffect(String id) {
    if (!mounted) return;
    final effects = _flyingStickersNotifier.value;
    if (effects.any((effect) => effect.id == id)) {
      _flyingStickersNotifier.value = effects
          .where((effect) => effect.id != id)
          .toList();
    }
  }

  // --- Городской модуль (Этап 1): метки проблем + слой парковок ---
  final MapMarksService _mapMarksService = MapMarksService();
  final List<MapMark> _mapMarks = [];
  LatLng? _pendingReportPoint;
  final OverpassService _overpassService = OverpassService();
  bool _showParkingLayer = false;
  bool _parkingsLoading = false;
  final List<({LatLng point, String name})> _parkings = [];
  final Set<String> _parkingsLoadedRegions = {};
  Timer? _parkingsDebounce;

  /// Баннер «новое сообщение» поверх карты (тап — открыть чат).
  final _incomingMessages = ValueNotifier<List<IncomingChatItem>>([]);
  final _incomingVisible = ValueNotifier<bool>(true);
  final Set<String> _previewedMessageIds = {};
  OverlayEntry? _incomingOverlay;

  // --- Слои карты (переключаются кнопкой «слои» в правой панели) ---
  int _mapLayerIndex = 0;
  int _heatMode = 0;
  int _heatRevision = 0;
  String _heatStatus = '';

  Future<void> _chooseMapLayer() async {
    await SatelliteMap.load();
    if (!mounted) return;
    if (_mapLayerIndex == 3 && SatelliteMap.template == null) {
      setState(() => _mapLayerIndex = 0);
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Карта и тепловые слои',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  for (var i = 0; i < 4; i++)
                    ListTile(
                      leading: Icon(
                        _mapLayerIndex == i
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(
                        i == 3 ? 'Спутник · MapTiler' : _mapLayerLabels[i],
                      ),
                      subtitle: i == 3 && SatelliteMap.template == null
                          ? const Text('Для подключения нужен ключ сервиса')
                          : null,
                      onTap: () async {
                        if (i == 3 && SatelliteMap.template == null) {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SatelliteSettingsScreen(),
                            ),
                          );
                          if (!mounted || !sheetContext.mounted) return;
                          update(() {});
                          if (SatelliteMap.template == null) return;
                        }
                        setState(() => _mapLayerIndex = i);
                        update(() {});
                      },
                    ),
                  const Divider(),
                  for (final entry in {
                    0: 'Без теплового слоя',
                    1: 'Мои тренировки',
                    2: 'Публичная тепловая карта',
                    3: 'Моя и публичная вместе',
                  }.entries)
                    ListTile(
                      leading: Icon(
                        _heatMode == entry.key
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(entry.value),
                      onTap: () {
                        setState(() {
                          _heatMode = entry.key;
                          _heatStatus = 'Загрузка тепловой карты…';
                        });
                        update(() {});
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: const Text('Периоды и участие в публичной карте'),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const RideHeatmapScreen(),
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('Готово'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (mounted && _mapLayerIndex == 3 && SatelliteMap.template == null) {
      setState(() => _mapLayerIndex = 0);
    }
  }

  static const List<String> _mapLayerUrls = [
    AppConfig.offlineTileUrl == ''
        ? 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
        : AppConfig.offlineTileUrl,
    'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
    'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png',
  ];
  static const List<String> _mapLayerLabels = [
    AppConfig.offlineTileUrl == '' ? 'OSM' : 'Основная',
    'Топография',
    'Велокарта',
  ];

  void _showSnackBar(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  // Кросс-миксиновые методы: объявлены здесь, реализованы в частях
  // библиотеки (_RouteActionsMixin). Без объявлений другие миксины не видят
  // их через ограничение `on _MapScreenStateBase`.
  void _setRouteTo(LatLng point);
  Future<void> _changeRouteWaypoints(List<LatLng> via);

  void _openSavedRoutes();
  Future<void> _openMyPlaces();
  Future<void> _savePersonalPlace(LatLng point);
  void _openRoundTripPlanner();
  void _setCameraLockMode(CameraLockMode mode);
  Future<void> _startRide();
  Future<void> _beginPreparedRide() => _startRide();
}

class _PulsePathMapScreenState extends _MapScreenStateBase
    with
        _UrbanMapMixin,
        _CameraCompassMixin,
        _ChatPushMixin,
        _RouteActionsMixin,
        _DrawerBuilderMixin,
        _MapMarkersMixin,
        _RideSheetsMixin {
  @override
  void initState() {
    super.initState();
    unawaited(
      AchievementsService.restoreProgress().catchError((Object error) {
        debugPrint('[Progress] local receipts restore failed: $error');
      }),
    );
    unawaited(
      OwnerService()
          .catalog()
          .then((_) {
            if (mounted) setState(() {});
          })
          .catchError((Object _) {}),
    );
    _navigationController.addListener(_handleControllerUpdate);
    unawaited(
      ActivityService().configure().catchError((Object error) {
        debugPrint('[Activity] initial timezone update deferred: $error');
      }),
    );
    _achievementPollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_checkRideAchievements()),
    );
    _routeSheetController.addListener(_onRouteSheetChanged);
    _searchFocusNode.addListener(_onSearchFocusChanged);
    _gpxImportSubscription = const EventChannel('pulsepath/gpx_import')
        .receiveBroadcastStream()
        .listen(
          _handleImportedGpx,
          onError: (Object error) {
            if (mounted) _showSnackBar('Не удалось открыть GPX-файл');
          },
        );
    _weatherRefreshTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_loadPreRideWeather()),
    );
    NavigationPreferences.instance.addListener(_onAppearanceChanged);
    PresenceService.instance.start();
    unawaited(DailyActivityService.instance.initialize());
    // Быстрые каналы: камера двигается императивно, без setState экрана.
    _navigationController.positionNotifier.addListener(_onPositionChanged);
    _displayPosition.addListener(_onDisplayedPositionChanged);
    _displayHeading.addListener(_onDisplayedHeadingChanged);
    _navigationController.headingListenable.addListener(_onHeadingChanged);
    WidgetsBinding.instance.addObserver(this);
    _loadSessionRoutes();
    unawaited(
      _initLocationTracking().then((_) async {
        _loadPreRideWeather();
        final signal = _navigationController.gpsSignal.value.checkedAt(
          DateTime.now(),
        );
        if (signal.updatedAt == null ||
            signal.quality == GpsQuality.lost ||
            (signal.accuracy ?? double.infinity) > 1000)
          return;
        final locality = await GeocodingService().locality(
          _navigationController.currentLocation,
        );
        if (mounted) setState(() => _searchLocality = locality);
      }),
    );
    _loadAppVersion();
    // Настройки заезда, сохранённые в SharedPreferences: контроллер стартует
    // с ними, а живые переключения — в HUD/настройках (там же и персист).
    _navigationController.setAutoPauseEnabled(widget.settings.autoPauseEnabled);
    _navigationController.setSportMode(widget.settings.sportMode);
    _navigationController.setGearLabEnabled(widget.settings.gearLabEnabled);
    _navigationController.setWaterReminderMinutes(
      widget.settings.waterReminderMinutes,
    );
    _navigationController.setBackgroundTrackingEnabled(
      widget.settings.backgroundTracking,
    );
    _navigationController.setShareLivePosition(
      widget.settings.shareLivePosition,
    );
    unawaited(
      BackgroundLocationService.instance.restore(
        shareAllowed: widget.settings.shareLivePosition,
      ),
    );
    // Подставляем технику по умолчанию (is_active == true) для HUD предзапуска.
    _navigationController.initPreRideVehicle();
    // Сообщество: друзья и их живые позиции на карте (Realtime).
    _navigationController.startFriendsTracking();
    // Чат: счётчик непрочитанных + живая доставка (бейдж в дровере).
    ChatService().refreshUnread();
    // Центр уведомлений: заявки в друзья + непрочитанные чаты —
    // бейдж у пункта «Уведомления» в дровере.
    NotificationService.instance.refresh();
    _chatListener = (message) {
      if (!mounted ||
          message.receiverId != _chatService.userId ||
          message.isRead) {
        return;
      }
      unawaited(_chatService.refreshUnread());
      if (ChatService.openChatFriendId != message.senderId) {
        unawaited(
          NotificationService.instance.notifyIncomingMessage(message).then((
            notification,
          ) {
            if (notification != null &&
                mounted &&
                _isForeground &&
                message.receiverId == _chatService.userId &&
                ChatService.openChatFriendId != message.senderId) {
              _showIncomingBanner(notification, message);
            }
          }),
        );
      }
    };
    _chatService.subscribe(_chatListener!);
    // Reconnects and DELETE events may be missed by Realtime filters.
    _notificationPollTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _isForeground) {
        unawaited(_syncPendingHistory());
        unawaited(_chatService.refreshUnread());
        unawaited(NotificationService.instance.refresh());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_syncPendingHistory());
      context.read<ProfileProvider>().ensureLoaded();
      _networkRecovery = NetworkRecoverySync(onSync: _retryLocalChanges,
        onStatusChanged: (_) { if (mounted) setState(() {}); })
        ..start();
      PushService.instance.onChatOpen = _openChatFromPush;
      PushService.instance.onGarageOpen = () async {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const GarageScreen()),
        );
      };
      PushService.instance.onChatPreview = _previewPushMessage;
      unawaited(_initialisePush());
      unawaited(_offerWorkoutRecovery());
    });
    unawaited(
      OfflineMapsService.ensureInitialised().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  Future<void> _offerWorkoutRecovery() async {
    try {
      final draft = await _navigationController.loadInterruptedWorkout();
      if (!mounted || draft == null) return;
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Найдена незавершённая поездка'),
          content: Text(
            'Сохранено ${(draft.distanceMeters / 1000).toStringAsFixed(2)} км '
            'и ${Duration(milliseconds: draft.activeMilliseconds).inMinutes} мин. '
            'После восстановления поездка будет на паузе.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'discard'),
              child: const Text('Удалить'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'save'),
              child: const Text('Сохранить'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'restore'),
              child: const Text('Продолжить'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == 'discard') {
        await _navigationController.discardInterruptedWorkout();
      } else if (choice == 'restore' || choice == 'save') {
        _navigationController.restoreInterruptedWorkout(draft);
        if (_navigationController.workoutSessionId != draft.localId) {
          _showSnackBar(
            'Состояние поездки изменилось. Восстановление не выполнено.',
          );
          return;
        }
        if (choice == 'save') {
          final saved = await _navigationController.finishAndSaveWorkout();
          if (mounted)
            _showSnackBar(
              saved != null
                  ? 'Прерванная поездка сохранена'
                  : 'Поездка не сохранена. Проверьте состояние записи.',
            );
        } else {
          _showSnackBar('Поездка восстановлена на паузе');
        }
      }
    } catch (error) {
      if (mounted) _showSnackBar('Не удалось восстановить поездку: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    _networkRecovery?.setForeground(_isForeground);
    _incomingVisible.value = _isForeground;
    PresenceService.instance.setForeground(_isForeground);
    DailyActivityService.instance.setForeground(_isForeground);
    _navigationController.setSharingForeground(_isForeground);
    if (_isForeground) {
      unawaited(_navigationController.resumeLocationTracking());
      unawaited(
        BackgroundLocationService.instance.restore(
          shareAllowed: widget.settings.shareLivePosition,
        ),
      );
      unawaited(GroupRideService().restoreSession());
      unawaited(_syncPendingHistory());
      unawaited(_chatService.refreshUnread());
      unawaited(NotificationService.instance.refresh());
      unawaited(_initialisePush());
    } else {
      _achievementBanner.dismiss();
      _navigationController.checkpointWorkout();
    }
  }

  @override
  void dispose() {
    _networkRecovery?.dispose();
    _achievementPollTimer?.cancel();
    _achievementBanner.dispose();
    _routeSheetController.removeListener(_onRouteSheetChanged);
    _routeSheetController.dispose();
    _weatherRefreshTimer?.cancel();
    unawaited(_gpxImportSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    PresenceService.instance.stop();
    unawaited(DailyActivityService.instance.stop());
    _notificationPollTimer?.cancel();
    _parkingsDebounce?.cancel();
    unawaited(_mapMarksService.unsubscribe());
    _searchGeneration++;
    final listener = _chatListener;
    if (listener != null) _chatService.unsubscribe(listener);
    PushService.instance.detach();
    _incomingOverlay?.remove();
    _incomingOverlay = null;
    _incomingMessages.dispose();
    _incomingVisible.dispose();
    _flyingStickersNotifier.dispose();
    _navigationController.removeListener(_handleControllerUpdate);
    NavigationPreferences.instance.removeListener(_onAppearanceChanged);
    _navigationController.positionNotifier.removeListener(_onPositionChanged);
    _navigationController.headingListenable.removeListener(_onHeadingChanged);
    _displayPosition.removeListener(_onDisplayedPositionChanged);
    _displayPosition.dispose();
    _displayHeading.removeListener(_onDisplayedHeadingChanged);
    _displayHeading.dispose();
    _navigationController.dispose();
    _searchDebounce?.cancel();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _mapController.dispose();
    _compassService.removeListener(_onCompassUpdate);
    _compassService.stop();
    _compassService.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onRouteSheetChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _configureGears() async {
    final vehicle = _navigationController.gearVehicle;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => vehicle == null
            ? const GarageScreen()
            : VehicleDetailScreen(vehicle: vehicle),
      ),
    );
    if (mounted) await _navigationController.refreshEquipment();
  }

  void _handleImportedGpx(Object? event) {
    if (!mounted || event is! String) return;
    final imported = GpxUtils.parseTrack(event);
    final points = imported.points;
    if (points.length < 2) {
      _showSnackBar('В GPX-файле не найден трек с двумя точками');
      return;
    }
    if (!_navigationController.loadImportedTrack(
      points,
      segmentStarts: imported.segmentStarts,
      title: imported.name.isEmpty ? 'GPX-трек' : imported.name,
    )) {
      _showSnackBar('Сначала завершите текущий заезд, чтобы открыть GPX');
      return;
    }
    if (_isMapReady) {
      _fitRoute();
    } else {
      _importedGpxPendingFit = true;
    }
    _showSnackBar('GPX-трек открыт на карте');
  }

  @override
  Widget build(BuildContext context) {
    // Точечная подписка: перекомпоновка только при смене флага стикеров.
    final bool stickersEnabled = context.select<ProfileProvider, bool>(
      (provider) => provider.isModuleEnabled(UiModules.stickers),
    );
    // Городской модуль: метки проблем, парковки, светофоры.
    final bool urbanEnabled = context.select<ProfileProvider, bool>(
      (provider) => provider.isModuleEnabled(UiModules.urban),
    );
    final bool showNavigationCard =
        _navigationController.isNavigating &&
        _navigationController.routeSteps.isNotEmpty &&
        _navigationController.currentStepIndex <
            _navigationController.routeSteps.length;
    final RouteStep? activeStep = showNavigationCard
        ? _navigationController.routeSteps[_navigationController
              .currentStepIndex]
        : null;

    // Заезд идёт (включая паузу) — HUD предзапуска скрыт, метрики активны.
    final bool isTracking =
        _navigationController.isWorkoutActive ||
        _navigationController.isWorkoutPaused;
    // Шторка маршрута занимает низ экрана — HUD и панель поднимаем выше.
    final bool routeSheetVisible =
        _navigationController.finishPoint != null &&
        !_isPreRideOpen &&
        !(isTracking && _navigationController.isNavigating);
    final double routeSheetHeight = _routeSheetController.isAttached
        ? _routeSheetController.size *
              (MediaQuery.sizeOf(context).height -
                  MediaQuery.paddingOf(context).bottom)
        : MediaQuery.sizeOf(context).height * .48;

    final bottomPanelHeight = isTracking
        ? _workoutHudHeight
        : _isPreRideOpen
        ? _preRideHudHeight + 16 + MediaQuery.paddingOf(context).bottom
        : routeSheetVisible
        ? routeSheetHeight
        : 100.0 + MediaQuery.paddingOf(context).bottom;

    return PopScope(
      canPop: !_isPreRideOpen && !_isChoosingRoute,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _searchFocusNode.unfocus();
        setState(() {
          _isPreRideOpen = false;
          _isChoosingRoute = false;
        });
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _buildAppDrawer(context),
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            // Message notifications use the phone UI. Only ride achievements get an in-app banner.
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _navigationController.currentLocation,
                initialZoom: 16.0,
                // При блокировке экрана отключаем все жесты карты: защита от
                // случайных нажатий (карман / дождевик).
                interactionOptions: InteractionOptions(
                  flags: _isScreenLocked
                      ? InteractiveFlag.none
                      : InteractiveFlag.all,
                ),
                onPositionChanged: (position, hasGesture) {
                  if (hasGesture &&
                      _navigationController.isFollowingUser &&
                      _cameraLockMode != CameraLockMode.free) {
                    debugPrint('User gesture detected, switching to free mode');
                    setState(() {
                      _navigationController.setFollowingUser(false);
                      // Держим autoRotateMap в согласии с режимом камеры,
                      // иначе карта продолжит доворачиваться по компасу.
                      _navigationController.setAutoRotateMap(false);
                      _cameraLockMode = CameraLockMode.free;
                    });
                  }
                },
                onTap: (_, __) {
                  FocusScope.of(context).unfocus();
                  setState(() => _searchResults = []);
                },
                onLongPress: (_, point) => _onLongPressMap(point),
                onMapEvent: (event) {
                  // Догрузка парковок при перемещении карты (с дебаунсом).
                  if (_showParkingLayer && !_parkingsLoading) {
                    _parkingsDebounce?.cancel();
                    _parkingsDebounce = Timer(
                      const Duration(milliseconds: 600),
                      () => unawaited(_loadParkingsForViewport()),
                    );
                  }
                },
                onMapReady: () {
                  setState(() {
                    _isMapReady = true;
                  });
                  // A fix can arrive before FlutterMap finishes its first frame.
                  _onDisplayedPositionChanged();
                  // Городские метки: загрузка + realtime, когда камера готова.
                  unawaited(_refreshMapMarks());
                  unawaited(_subscribeMapMarks());
                  if (_importedGpxPendingFit) {
                    _importedGpxPendingFit = false;
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _fitRoute(),
                    );
                  }
                },
              ),
              children: [
                if (!_useOfflineMap ||
                    OfflineMapsService.isAvailable)
                  TileLayer(
                    key: ValueKey(
                      '$_mapLayerIndex:${_useOfflineMap}',
                    ),
                    urlTemplate: _usePreparedMapSource ? OfflineMapsService.routeTileUrl : _mapLayerIndex == 3
                        ? SatelliteMap.template
                        : _MapScreenStateBase._mapLayerUrls[_mapLayerIndex],
                    maxNativeZoom: _usePreparedMapSource ? 16 : _mapLayerIndex == 3
                        ? SatelliteMap.maxZoom
                        : 19,
                    subdomains: const ['a', 'b', 'c'],
                    // Кэширование тайлов (офлайн-карты); без FMTC — сетевой провайдер.
                    tileProvider: _useOfflineMap
                        ? OfflineMapsService.tileProvider(offlineOnly: true)
                        : _mapLayerIndex == 3
                        ? NetworkTileProvider()
                        : OfflineMapsService.tileProvider(),
                    userAgentPackageName: 'com.pulsepath.app',
                  ),
                if (_heatMode != 0)
                  HeatmapPathLayer(
                    revision: _heatRevision,
                    personal: _heatMode == 1 || _heatMode == 3,
                    public: _heatMode == 2 || _heatMode == 3,
                    onStatus: (status) {
                      if (mounted && _heatStatus != status) {
                        setState(() => _heatStatus = status);
                      }
                    },
                  ),
                // Путь рисуем над тайлами, но до слоёв маркеров: маршрут не
                // должен перекрывать аватары друзей и значок пользователя.
                if (_navigationController.routePoints.isNotEmpty)
                  ActivityTrailLayer(
                    segments: _navigationController.routeSegments,
                    activity: _navigationController.workoutActivity,
                    transport: _navigationController.gearVehicle?.transportType,
                    baseColor: NavigationPreferences.instance.routeColor,
                    baseWidth: NavigationPreferences.instance.lineWidth,
                  ),
                MarkerLayer(
                  markers: [
                    for (
                      var i = 0;
                      i < _navigationController.routeWaypoints.length;
                      i++
                    )
                      Marker(
                        point: _navigationController.routeWaypoints[i],
                        width: 30,
                        height: 30,
                        rotate: true,
                        child: Tooltip(
                          message: 'Остановка ${i + 1}',
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.deepOrange,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    for (final member in GroupRideService().members)
                      if (member.userId != _chatService.userId &&
                          member.isLive &&
                          member.latitude != null &&
                          member.longitude != null &&
                          !_navigationController.friends.any(
                            (friend) =>
                                friend.id == member.userId &&
                                friend.hasLivePosition &&
                                friend.hasFreshMotion,
                          ))
                        Marker(
                          point: LatLng(member.latitude!, member.longitude!),
                          width: 52,
                          height: 52,
                          rotate: true,
                          child: Tooltip(
                            message:
                                '${member.username} · ${(member.distanceMeters / 1000).toStringAsFixed(1)} км',
                            child: CircleAvatar(
                              backgroundColor: Colors.deepOrange,
                              child: Text(
                                member.username.isEmpty
                                    ? 'Р'
                                    : member.username.characters.first,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
                ValueListenableBuilder<LatLng>(
                  valueListenable: _displayPosition,
                  builder: (context, position, _) => MarkerLayer(
                    markers: [
                      Marker(
                        point: position,
                        width: 96,
                        height: 96,
                        // true: flutter_map сам компенсирует поворот карты
                        // (MarkerLayer -> Transform.rotate(-map.rotationRad)),
                        // поэтому screenAngleDeg в RiderMarker — экранный угол,
                        // который считает _buildUserLocationMarker.
                        rotate: true,
                        child: _buildUserLocationMarker(),
                      ),
                      if (_navigationController.finishPoint != null)
                        Marker(
                          point: _navigationController.finishPoint!,
                          width: 44,
                          height: 44,
                          // true: пин должен всегда стоять вертикально, даже когда
                          // карта повёрнута в режиме "По направлению взгляда".
                          rotate: true,
                          child: const Icon(
                            Icons.location_on,
                            color: Colors.deepOrange,
                            size: 44,
                          ),
                        ),
                    ],
                  ),
                ), // ValueListenableBuilder(positionNotifier)
                if (!isTracking)
                  ValueListenableBuilder<LatLng>(
                    valueListenable: _navigationController.positionNotifier,
                    builder: (context, position, _) => FriendTrailsLayer(
                      key: ValueKey('idle-trail-${UserScope.currentUserId()}'),
                      idle: true,
                      friends:
                          _navigationController.gpsSignal.value.updatedAt ==
                              null
                          ? const []
                          : [
                              FriendProfile(
                                id: 'self',
                                username: '',
                                liveLatitude: position.latitude,
                                liveLongitude: position.longitude,
                                liveUpdatedAt: _navigationController
                                    .gpsSignal
                                    .value
                                    .updatedAt,
                                liveActivity: 'walking',
                              ),
                            ],
                    ),
                  ),
                FriendMotionLayer(
                  key: ValueKey('friend-motion-${UserScope.currentUserId()}'),
                  friends: !_navigationController.canDisplayFriendTrails
                      ? const []
                      : _navigationController.friendsOnMap,
                  markerBuilder: (friend) => _buildFriendMarker(
                    friend,
                    selected: _selectedMapFriend?.id == friend.id,
                  ),
                  onSelect: (friend) =>
                      setState(() => _selectedMapFriend = friend),
                ),
                if (_navigationController.recordedPath.isNotEmpty)
                  ActivityTrailLayer(
                    segments: _navigationController.recordedSegments,
                    activity: _navigationController.workoutActivity,
                    transport: _navigationController.gearVehicle?.transportType,
                    recorded: true,
                    baseColor: Colors.greenAccent.withValues(alpha: .8),
                  ),
                // Летящие стикеры: анимация прилёта к маркеру друга
                // (только при включённом игровом модуле).
                // Городские метки проблем (urban-модуль): эмодзи-пины.
                if (urbanEnabled)
                  MarkerLayer(
                    markers: [
                      for (final mark in _mapMarks)
                        Marker(
                          point: LatLng(mark.latitude, mark.longitude),
                          width: 46,
                          height: 46,
                          alignment: Alignment.topCenter,
                          child: GestureDetector(
                            onTap: () => _showMarkDetails(mark),
                            child: Opacity(
                              // Свежие метки ярче; «стареющие» — полупрозрачные.
                              opacity: 0.45 + mark.freshness * 0.55,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: mark.type.color,
                                    width: 2.5,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black26,
                                      blurRadius: 6,
                                      offset: Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Text(
                                    mark.type.emoji,
                                    style: const TextStyle(fontSize: 20),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                // Индикатор выбранной точки для будущего отчёта.
                if (urbanEnabled && _pendingReportPoint != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _pendingReportPoint!,
                        width: 28,
                        height: 28,
                        child: const Icon(
                          Icons.location_on,
                          color: Colors.amber,
                          size: 28,
                        ),
                      ),
                    ],
                  ),
                // Слой парковок OSM (urban-модуль, кнопка 🅿️).
                if (urbanEnabled && _showParkingLayer && _parkings.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      for (final parking in _parkings)
                        Marker(
                          point: parking.point,
                          width: 34,
                          height: 34,
                          alignment: Alignment.topCenter,
                          child: Tooltip(
                            message: parking.name,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.blue),
                              ),
                              child: const Center(
                                child: Text(
                                  'P',
                                  style: TextStyle(
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),

            if (!_isPreRideOpen || isTracking)
              IgnorePointer(
                ignoring: _isScreenLocked,
                child: SearchPanel(
                  focusNode: _searchFocusNode,
                  searchController: _searchController,
                  isSearching: _isSearching,
                  searchResults: _searchResults,
                  onSearchChanged: (value) {
                    _searchGeneration++;
                    setState(() {
                      _searchResults = [];
                      _isSearching = false;
                    });
                  },
                  onSearchSubmitted: _onSearchChanged,
                  nearbyOnly: _nearbySearch,
                  locality: _searchLocality,
                  onSearchScopeChanged: (nearby) {
                    setState(() => _nearbySearch = nearby);
                    if (_searchController.text.trim().isNotEmpty) {
                      _onSearchChanged(_searchController.text);
                    }
                  },
                  onSelectResult: (item) {
                    setState(() => _isChoosingRoute = false);
                    _selectSearchResult(item);
                  },
                  onClearSearch: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                  openDrawer: () => _scaffoldKey.currentState?.openDrawer(),
                ),
              ),
            if (_isPreRideOpen && !isTracking && !_isScreenLocked)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 12,
                left: 16,
                child: IconButton.filledTonal(
                  tooltip: 'Меню',
                  icon: const Icon(Icons.menu),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
              ),
            if (showNavigationCard &&
                (!_isPreRideOpen || isTracking) &&
                _searchResults.isEmpty &&
                MediaQuery.viewInsetsOf(context).bottom == 0)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 76,
                left: 16,
                right: 12,
                child: ValueListenableBuilder<LatLng>(
                  valueListenable: _navigationController.positionNotifier,
                  builder: (context, position, _) => NavigationCard(
                    onReconnectAhead: () async {
                      try { await _navigationController.reconnectAhead(); }
                      catch (error) { if (mounted) _showSnackBar(error.toString()); }
                    },
                    offRoute: _navigationController.isOffRoute,
                    preserveTrack: _navigationController.followsSavedTrack,
                    deviationMeters: _navigationController.routeDeviationMeters,
                    activeStep: activeStep,
                    distanceToNextStepMeters:
                        _navigationController.distanceToNextTurnMeters,
                    remainingMeters: _navigationController.remainingRouteMeters,
                    remainingMinutes:
                        _navigationController.remainingRouteMinutes,
                    isRerouting: _navigationController.isLoadingRoute,
                  ),
                ),
              ),
            if ((!_isPreRideOpen || isTracking) &&
                _searchResults.isEmpty &&
                MediaQuery.viewInsetsOf(context).bottom == 0 &&
                !_searchFocusNode.hasFocus)
              Positioned(
                top:
                    MediaQuery.paddingOf(context).top +
                    (showNavigationCard ? 204 : 80),
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    Flexible(
                      flex: 0,
                      child: GpsSignalIndicator(
                        signal: _navigationController.gpsSignal,
                        compact: true,
                        refreshing: _refreshingGps,
                        onTap: _refreshGpsAndCenter,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 3,
                      child: MapWeatherPill(
                        weather: _preRideWeather,
                        isLoading: _weatherLoading,
                        onTap: _loadPreRideWeather,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const HomeStepsPill(),
                  ],
                ),
              ),

            Positioned(
              right: 12,
              bottom: bottomPanelHeight + 8,
              child: IgnorePointer(
                ignoring: _isScreenLocked,
                child: MapCredits(layer: _usePreparedMapSource ? 0 : _mapLayerIndex),
              ),
            ),
            // Баннер входящего сообщения: тап — открыть чат с отправителем.
            if (_heatMode != 0 && _heatStatus.isNotEmpty)
              Positioned(
                top:
                    MediaQuery.paddingOf(context).top +
                    (showNavigationCard ? 280 : 135),
                left: 16,
                right: 100,
                child: Material(
                  color: Theme.of(context).colorScheme.surface
                      .withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _heatStatus,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ),
            MapOverlays(
              mapController: _mapController,
              autoRotateMap: _cameraLockMode.isRotating,
              isFollowingUser: _cameraLockMode.isFollowing,
              isWorkoutActive: _navigationController.isWorkoutActive,
              isWorkoutPaused: _navigationController.isWorkoutPaused,
              currentHeading: _currentHeading,
              currentLocation: _navigationController.currentLocation,
              onAutoRotateChanged: (value) {
                if (_cameraLockMode.isFollowing) {
                  // Переключаем между follow и followAndHeading
                  _setCameraLockMode(
                    value
                        ? CameraLockMode.followAndHeading
                        : CameraLockMode.follow,
                  );
                } else {
                  // Если не следует, сначала включаем follow
                  _setCameraLockMode(CameraLockMode.follow);
                  if (value) {
                    _setCameraLockMode(CameraLockMode.followAndHeading);
                  }
                }
              },
              onFollowUser: () {
                if (_cameraLockMode == CameraLockMode.free) {
                  _setCameraLockMode(CameraLockMode.follow);
                } else if (_cameraLockMode == CameraLockMode.follow) {
                  _setCameraLockMode(CameraLockMode.followAndHeading);
                } else {
                  _setCameraLockMode(CameraLockMode.free);
                }
              },
              bottomOffset: bottomPanelHeight + 12,
              cameraLockModeLabel: _cameraLockMode.label,
              cameraLockModeIcon: _cameraLockMode.icon,
              onCameraLockModePressed: () {
                _setCameraLockMode(_cameraLockMode.next);
              },
              mapRotation: _isMapReady ? _mapController.camera.rotation : 0.0,
              onCompassPressed: () {
                if (!_isMapReady) return;
                _mapController.rotate(0.0);
              },
              isScreenLocked: _isScreenLocked,
              onLockScreen: () {
                setState(() => _isScreenLocked = true);
                _showSnackBar('Экран заблокирован: кнопки и карта неактивны');
              },
              onScreenUnlocked: () {
                setState(() => _isScreenLocked = false);
                _showSnackBar('Экран разблокирован');
              },
              mapLayerLabel: _usePreparedMapSource ? 'Офлайн-карта' : _mapLayerIndex == 3
                  ? 'Спутник'
                  : _MapScreenStateBase._mapLayerLabels[_mapLayerIndex],
              onMapLayerPressed: _chooseMapLayer,
              showParkingLayer: urbanEnabled ? _showParkingLayer : null,
              onParkingLayerPressed: urbanEnabled ? _toggleParkingLayer : null,
            ),

            if (_isChoosingRoute &&
                !_isPreRideOpen &&
                !isTracking &&
                MediaQuery.viewInsetsOf(context).bottom == 0)
              Positioned(
                left: 16,
                right: 16,
                bottom: 108 + MediaQuery.paddingOf(context).bottom,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(18),
                  elevation: 3,
                  child: ListTile(
                    leading: const Icon(Icons.pin_drop_outlined),
                    title: const Text('Выберите пункт назначения'),
                    subtitle: const Text(
                      'Найдите место или удерживайте точку на карте',
                    ),
                    trailing: IconButton(
                      tooltip: 'Отменить выбор',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _searchFocusNode.unfocus();
                        setState(() => _isChoosingRoute = false);
                      },
                    ),
                  ),
                ),
              ),

            // Активная панель метрик: выезжает снизу при старте заезда и
            // уезжает обратно при финише. Метрики обновляются по тику
            // контроллера (workoutTick) — без rebuild всего экрана карты.
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) {
                  final slide =
                      Tween<Offset>(
                        begin: const Offset(0, 1),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutCubic,
                        ),
                      );
                  return SlideTransition(
                    position: slide,
                    child: FadeTransition(opacity: animation, child: child),
                  );
                },
                child: ValueListenableBuilder<int>(
                  valueListenable: _navigationController.workoutTick,
                  builder: (context, tick, child) {
                    if (!isTracking) return const SizedBox.shrink();
                    return WidgetSizeObserver(
                      onSize: (size) {
                        if (mounted &&
                            (size.height - _workoutHudHeight).abs() > 1) {
                          setState(() => _workoutHudHeight = size.height);
                        }
                      },
                      child: WorkoutStatsBottomSheet(
                        gearAdvisor:
                            _navigationController.gearLabEnabled &&
                                !_navigationController.workoutActivity.isFoot
                            ? GearAdvisorCard(
                                vehicle: _navigationController.gearVehicle,
                                speedKmh: _navigationController.isWorkoutPaused
                                    ? 0
                                    : _navigationController.workoutSpeedKmh,
                                onConfigure: _configureGears,
                                compact: true,
                              )
                            : null,
                        controller: _navigationController,
                        savedRoutesRepo: _repository,
                        onPauseResumePressed: () {
                          if (_isScreenLocked) return;
                          if (_navigationController.isWorkoutActive) {
                            _navigationController.pauseWorkout();
                          } else {
                            _navigationController.resumeWorkout();
                          }
                        },
                        onFinishPressed: _finishRide,
                        onSharingChanged: _setRideSharing,
                        isPaused:
                            !_navigationController.isWorkoutActive &&
                            _navigationController.isWorkoutPaused,
                        isAutoPaused: _navigationController.isAutoPaused,
                        isLocked: _isScreenLocked,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Нижняя панель карты (как в Komoot): компактная плашка с кнопкой
            // «Свободный заезд»; по нажатию раскрывается в HUD подготовки.
            // Когда заезд идёт — обе прячутся, остаётся панель метрик.
            if (!isTracking && (!routeSheetVisible || _isPreRideOpen))
              Positioned(
                bottom: routeSheetVisible && !_isPreRideOpen
                    ? routeSheetHeight + 12
                    : 16 + MediaQuery.paddingOf(context).bottom,
                left: 16,
                right: 16,
                child: _isPreRideOpen
                    ? ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * .72,
                        ),
                        child: WidgetSizeObserver(
                          onSize: (size) {
                            if (mounted &&
                                (size.height - _preRideHudHeight).abs() > 1) {
                              setState(() => _preRideHudHeight = size.height);
                            }
                          },
                          child: PreRideWidget(
                            key: const ValueKey('pre-ride-hud'),
                            startLabel: _preRideGroupRoomId == null
                                ? 'НАЧАТЬ'
                                : 'НАЧАТЬ В ГРУППЕ',
                            startEnabled:
                                _preRideGroupRoomId == null ||
                                _preRideGroupRoomId ==
                                    GroupRideService().activeRoomId,
                            groupChoice: GroupStartChoice(
                              service: GroupRideService(),
                              selectedRoomId: _preRideGroupRoomId,
                              disabled: _isScreenLocked || _startingRide,
                              onChanged: (room) =>
                                  setState(() => _preRideGroupRoomId = room),
                              onManage: _openGroupFromPreparation,
                              sharesLocation:
                                  _navigationController.shareLivePosition,
                              onUseRoute: () {
                                final route = GroupRideService().route;
                                if (route != null) {
                                  _navigationController.loadSavedRoute(
                                    route.toSavedRoute(),
                                  );
                                  final mode = switch (route.activity) {
                                    ActivityType.hiking => SportMode.walking,
                                    ActivityType.running => SportMode.running,
                                    ActivityType.briskWalking =>
                                      SportMode.briskWalking,
                                    ActivityType.nordicWalking =>
                                      SportMode.nordicWalking,
                                    ActivityType.trekking => SportMode.trekking,
                                    ActivityType.trailRunning =>
                                      SportMode.trailRunning,
                                    _ => SportMode.vehicle,
                                  };
                                  _navigationController.setSportMode(mode);
                                  widget.settings.setSportMode(mode);
                                  _showSnackBar(
                                    'Маршрут группы выбран. Можно начинать поездку.',
                                  );
                                }
                              },
                            ),
                            settingsSummary:
                                '${_navigationController.workoutGoal?.label ?? 'Без цели'} · ${_navigationController.intervalPlan == null ? 'без интервалов' : 'интервалы включены'} · ${_navigationController.shareLivePosition ? 'позиция видна друзьям' : 'позиция скрыта'}',
                            onPlanRoute: _openRoutePlanner,
                            readiness: GpsSignalIndicator(
                              signal: _navigationController.gpsSignal,
                              onTap: _refreshGpsAndCenter,
                              refreshing: _refreshingGps,
                            ),
                            preparation: RidePreparationPanel(
                              showGps: false,
                              controller: _navigationController,
                              onSharingChanged: _setRideSharing,
                              onGpsRetry: _initLocationTracking,
                            ),
                            selectedVehicle:
                                _navigationController.preRideVehicle,
                            onSelectVehicle: _openVehicleSelector,
                            autoPauseEnabled:
                                _navigationController.autoPauseEnabled,
                            onAutoPauseChanged: (value) {
                              _navigationController.setAutoPauseEnabled(value);
                              // Значение становится дефолтом для следующих сессий.
                              widget.settings.setAutoPauseEnabled(value);
                            },
                            sportMode: _navigationController.sportMode,
                            onSportModeChanged: (value) {
                              _navigationController.setSportMode(value);
                              widget.settings.setSportMode(value);
                            },
                            onStartRide: _beginPreparedRide,
                            onCollapse: () =>
                                setState(() => _isPreRideOpen = false),
                            isLocked: _isScreenLocked,
                            routeLabel:
                                _navigationController.finishPoint != null
                                ? _navigationController.finishAddress
                                : null,
                          ),
                        ),
                      )
                    : _buildRideBottomBar(),
              ),

            // Панель друга на карте (2ГИС-стиль): компактная + разворот.
            if (_selectedMapFriend != null)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: false,
                  child: FriendMapPanel(
                    friend: _selectedMapFriend!,
                    currentUserId: ChatService().userId,
                    myPosition: _navigationController.positionNotifier,
                    showStickers: stickersEnabled,
                    onClose: () => setState(() => _selectedMapFriend = null),
                    onShowOnMap: () {
                      final friend = _selectedMapFriend;
                      if (friend == null || !_isMapReady) return;
                      if (friend.liveLatitude != null &&
                          friend.liveLongitude != null) {
                        _mapController.move(
                          LatLng(friend.liveLatitude!, friend.liveLongitude!),
                          17.0,
                        );
                      }
                    },
                    onShare: () {
                      final friend = _selectedMapFriend;
                      if (friend == null) return;
                      Clipboard.setData(
                        ClipboardData(
                          text:
                              'Друг PulsePath: ${friend.username} — найдите его в приложении!',
                        ),
                      );
                      _showSnackBar('Ссылка на друга скопирована');
                    },
                    onOpenProfile: () {
                      final friend = _selectedMapFriend;
                      if (friend != null) _openFriendProfile(friend);
                    },
                    onRemoveFriend: () {
                      final friend = _selectedMapFriend;
                      if (friend != null) _removeMapFriend(friend);
                    },
                    onSticker: (emoji, origin) {
                      final friend = _selectedMapFriend;
                      if (friend != null) {
                        _flySticker(friend, emoji, origin: origin);
                      }
                    },
                    onStickerRain: (emoji, origin) {
                      final friend = _selectedMapFriend;
                      if (friend != null) {
                        _flySticker(friend, emoji, rain: true, origin: origin);
                      }
                    },
                  ),
                ),
              ),

            if (stickersEnabled && _isMapReady)
              Positioned.fill(
                child: MapStickerFlightOverlay(
                  onEffectCompleted: _completeStickerEffect,
                  effects: _flyingStickersNotifier,
                  mapController: _mapController,
                ),
              ),

            // Подсказка при блокировке экрана.
            if (_isScreenLocked)
              Positioned(
                bottom:
                    (_navigationController.isWorkoutActive ||
                        _navigationController.isWorkoutPaused)
                    ? 190
                    : 80,
                left: 24,
                right: 90,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.lock, color: Colors.white, size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Экран заблокирован. Удерживайте замок 1.5 сек для разблокировки',
                            style: TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            if (routeSheetVisible)
              Positioned(
                top: 0,
                bottom: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  top: false,
                  child: IgnorePointer(
                    ignoring: _isScreenLocked,
                    child: RouteDetailsBottomSheet(
                      waypointEditor: RouteWaypointsEditor(
                        controller: _navigationController,
                        onChange: _changeRouteWaypoints,
                      ),
                      gearAdvisor:
                          _navigationController.gearLabEnabled &&
                              !_navigationController.selectedActivity.isFoot
                          ? GearAdvisorCard(
                              vehicle: _navigationController.gearVehicle,
                              speedKmh: 0,
                              planning: true,
                              onConfigure: _configureGears,
                            )
                          : null,
                      sheetController: _routeSheetController,
                      finishAddress: _navigationController.finishAddress,
                      finishPoint: _navigationController.finishPoint,
                      selectedActivity: _navigationController.selectedActivity,
                      activityTypes: ActivityType.values,
                      hasOfflineInstructions: _navigationController.routeSteps.isNotEmpty,
                      routeProgressMeters: ((_navigationController.routeDistanceKm ?? 0) * 1000 - _navigationController.remainingRouteMeters).clamp(0, double.infinity),
                      onAddPlaceStop: !_navigationController.canEditWaypoints ? null : (point) => _navigationController.replanWithWaypoints([..._navigationController.routeWaypoints, point]),
                      routePoints: _navigationController.routePoints,
                      routeDistanceKm: _navigationController.routeDistanceKm,
                      routeDurationMin: _navigationController.routeDurationMin,
                      elevationGainMeters:
                          _navigationController.elevationGainMeters,
                      elevationLossMeters:
                          _navigationController.elevationLossMeters,
                      surfaceInfo: _navigationController.surfaceInfo,
                      isLoadingRoute: _navigationController.isLoadingRoute,
                      isBookmarked: _navigationController.isBookmarked,
                      isNavigating: _navigationController.isNavigating,
                      routeError: _navigationController.routeError,
                      routeNotice: _navigationController.routeNotice,
                      hasRoute: _navigationController.routePoints.isNotEmpty,
                      onStartWorkout: isTracking
                          ? null
                          : () {
                              final mode = switch (_navigationController
                                  .selectedActivity) {
                                ActivityType.hiking => SportMode.walking,
                                ActivityType.running => SportMode.running,
                                ActivityType.briskWalking =>
                                  SportMode.briskWalking,
                                ActivityType.nordicWalking =>
                                  SportMode.nordicWalking,
                                ActivityType.trekking => SportMode.trekking,
                                ActivityType.trailRunning =>
                                  SportMode.trailRunning,
                                _ => SportMode.vehicle,
                              };
                              _navigationController.setSportMode(mode);
                              widget.settings.setSportMode(mode);
                              setState(() => _isPreRideOpen = true);
                              _loadPreRideWeather();
                            },
                      onRetry: _buildRoute,
                      onShowRoute: _fitRoute,
                      onRoundTrip: _openRoundTripPlanner,
                      onClearRoute: _clearRoute,
                      onActivityChanged: (activity) {
                        _navigationController.setSelectedActivity(activity);
                        _buildRoute();
                      },
                      onToggleBookmark: _toggleBookmark,
                      onToggleNavigation: _toggleNavigation,
                      onShareRoute: _shareRoute,
                      formatDuration: _formatDuration,
                      formatETA: _formatETA,
                      calculateCalories: _calculateCalories,
                    ),
                  ),
                ),
              ),
            if (_isForeground && isTracking)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 12,
                left: 16,
                right: 16,
                child: IgnorePointer(
                  ignoring: _isScreenLocked,
                  child: RideAchievementBanner(controller: _achievementBanner),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
