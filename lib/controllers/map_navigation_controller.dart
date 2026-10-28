import '../services/usage_statistics.dart';
import '../models/workout_details.dart';
import '../services/distance_laps.dart';
import '../services/workout_step_tracker.dart';
import '../services/recording_daily_activity_service.dart';
import '../models/walking_steps.dart';
import '../services/notification_service.dart';
import '../models/interval_plan.dart';

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:geolocator/geolocator.dart' hide ActivityType;

import '../services/notification_permission_service.dart';
import '../services/push_service.dart';
import '../services/workout_reminder_clock.dart';
import '../services/voice_guidance_service.dart';
import '../services/trail_guidance.dart';

import 'package:latlong2/latlong.dart' hide Path;

import '../data/user_scope.dart';
import '../data/workout_draft_store.dart';
import '../models/activity_type.dart';
import '../models/gps_signal.dart';
import '../services/gps_freshness_probe.dart';
import '../models/route_step.dart';
import '../models/surface_info.dart';
import '../models/saved_route.dart';
import '../models/vehicle.dart';
import '../services/routing_service.dart';
import '../services/overpass_service.dart';
import '../services/garage_service.dart';
import '../services/cycling_power.dart';
import '../services/cycling_energy.dart';
import '../models/bike_setup.dart';
import '../models/brake_load.dart';
import '../services/friend_service.dart';
import '../services/background_location_service.dart';
import '../services/group_ride_service.dart';
import '../models/friend_profile.dart';
import '../utils/geo_utils.dart';
import '../utils/ride_id.dart';
import '../data/workout_history_repository.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// Вид активности свободного тренировочного заезда.
///
/// `vehicle` — на технике из гаража (тип заезда берётся из техники);
/// `walking` / `running` — без техники, тип заезда hiking/running.
enum SportMode {
  vehicle('Вело'),
  walking('Пешком'),
  running('Бег'),
  briskWalking('Быстрая ходьба'),
  nordicWalking('С палками'),
  trekking('Поход'),
  trailRunning('Трейл');

  const SportMode(this.label);
  final String label;
}

class MapNavigationController extends ChangeNotifier {
  bool _preserveTrack = false;
  bool _offRoute = false;
  int _offRouteSamples = 0;
  double _routeDeviation = 0;
  bool get isOffRoute => _offRoute;
  double get routeDeviationMeters => _routeDeviation;
  bool get followsSavedTrack => _preserveTrack;
  bool get canReturnToStart => _recordedPath.length >= 2;

  void _resetDeviation() {
    _offRoute = false;
    _offRouteSamples = 0;
    _routeDeviation = 0;
  }

  void returnAlongTrack() {
    if (!_hasSession || !canReturnToStart || _isSavingWorkout) {
      throw StateError('Сначала запишите часть пути');
    }
    final segments = WorkoutDetails.splitTrack(
      _recordedPath,
      _trackSegmentStarts,
    );
    final latest = segments.last;
    if (latest.length < 2) {
      throw StateError(
        'После последнего разрыва GPS ещё нет участка для возвращения',
      );
    }
    final reverse = latest.reversed.toList();
    _routeGeneration++;
    _routePoints = reverse;
    _routeSegmentStarts = {};
    _routeSteps = TrailGuidance.steps(reverse);
    _routeVia = [];
    _viaOffsetsMeters = [];
    _routeDistanceKm = TrailGuidance.length(reverse) / 1000;
    _routeDurationMin = _routeDistanceKm! / _selectedActivity.avgSpeedKmH * 60;
    _finishPoint = reverse.last;
    _finishAddress = segments.length > 1
        ? 'Начало последнего непрерывного участка'
        : 'Возвращение к старту по треку';
    _currentStepIndex = 0;
    _navigationProgressMeters = 0;
    _isLoadingRoute = false;
    _routeError = null;
    _isBookmarked = false;
    _surfaceInfo = null;
    _elevationGainMeters = 0;
    _elevationLossMeters = 0;
    _preserveTrack = true;
    _isFollowingUser = true;
    _autoRotateMap = true;
    _resetDeviation();
    routeNotice = segments.length > 1
        ? 'В записи есть разрывы. Ведём только по последнему непрерывному участку; проверьте путь до исходного старта.'
        : 'Обратный записанный трек: работает без сети. Проверяйте ограничения движения и возможность проезда в обратную сторону.';
    setNavigating(true);
    notifyListeners();
  }

  Future<void> returnToStartByRoads() async {
    if (!_hasSession ||
        !canReturnToStart ||
        _isLoadingRoute ||
        _isSavingWorkout) {
      throw StateError('Нет записанного пути или идёт построение');
    }
    if (gpsSignal.value.quality != GpsQuality.good) {
      throw StateError('Дождитесь точного GPS');
    }
    final start = _recordedPath.first;
    final generation = ++_routeGeneration;
    _isLoadingRoute = true;
    notifyListeners();
    try {
      final result = await _routingService.buildRoute(
        start: _currentLocation,
        end: start,
        activity: _sessionActivity ?? _selectedActivity,
      );
      if (_disposed || generation != _routeGeneration) return;
      _finishPoint = start;
      _finishAddress = 'Возвращение к старту по дорогам';
      _routeVia = [];
      _preserveTrack = false;
      _isFollowingUser = true;
      _autoRotateMap = true;
      routeNotice = null;
      _routeError = null;
      _acceptRoutingResult(result, generation, _selectedActivity);
      setNavigating(true);
    } finally {
      if (!_disposed && generation == _routeGeneration) {
        _isLoadingRoute = false;
        notifyListeners();
      }
    }
  }

  final _waterReminder = WorkoutReminderClock();
  int _waterReminderMinutes = 0;

  void setWaterReminderMinutes(int minutes) {
    if (!WorkoutReminderClock.intervals.contains(minutes)) return;
    _waterReminderMinutes = minutes;
    _waterReminder.configure(minutes, _activeDuration);
    if (minutes == 0) unawaited(PushService.instance.clearWaterReminder());
  }

  MapNavigationController({
    Stopwatch? activeClock,
    DateTime Function()? gpsNow,
    RoutingService? routingService,
    WorkoutStepTracker? stepTracker,
    GroupRideService? groupRideService,
  }) : _gpsNow = gpsNow ?? DateTime.now,
       _activeClock = activeClock ?? Stopwatch(),
       _stepTracker = stepTracker ?? WorkoutStepTracker(),
       _routingService = routingService ?? RoutingService(),
       _groupRideService = groupRideService ?? GroupRideService() {
    gpsSignal.addListener(_onTelemetryQualityChanged);
    _stepTracker.addListener(_onWorkoutStepsChanged);
  }
  final DateTime Function() _gpsNow;
  final WorkoutStepTracker _stepTracker;
  WorkoutStepTracker get stepTracker => _stepTracker;
  void _onWorkoutStepsChanged() {
    if (_disposed || !_hasSession || !_hasCurrentOwner) return;
    _queueDraft();
    workoutTick.value++;
    notifyListeners();
  }

  final RoutingService _routingService;
  final OverpassService _overpassService = OverpassService();
  final WorkoutHistoryRepository _workoutHistoryRepository =
      WorkoutHistoryRepository();
  // Отправляет заезд в `rides` (с vehicle_id/transport_type) и определяет
  // активную технику из `garage` (см. finishAndSaveWorkout).
  final GarageService _garageService = GarageService();
  // Сообщество: друзья и живые позиции (Realtime `live_positions`).
  final FriendService _friendService = FriendService();
  final Map<String, FriendProfile> _friends = {};
  DateTime? _lastLivePublish;
  bool _friendsTrackingStarted = false;
  bool _refreshingFriends = false;
  bool _sharingForeground = true;

  void setSharingForeground(bool value) {
    _sharingForeground = value;
    if (value && _hasSession && workoutActivity.isFoot)
      unawaited(_stepTracker.refresh());
    if (!value && !_backgroundTrackingEnabled) {
      unawaited(VoiceGuidanceService.instance.stop());
    }
    if (value) {
      unawaited(_publishLivePosition(_currentLocation));
      unawaited(_refreshFriends());
    }
  }

  Timer? _friendStatusTimer;
  Timer? _groupProgressTimer;
  final GroupRideService _groupRideService;
  String? _workoutGroupRoomId;
  String? get workoutGroupRoomId => _workoutGroupRoomId;
  bool get isGroupWorkout => _hasSession && _workoutGroupRoomId != null;
  bool get groupWorkoutConnected =>
      isGroupWorkout &&
      _workoutGroupRoomId == _groupRideService.activeRoomId &&
      _groupRideService.userId == _ownerId &&
      _hasCurrentOwner;
  bool _publishingGroup = false;
  String? _lastGroupRoom;
  int _lastGroupRevision = -1;
  bool _groupHadWorkout = false;
  double _groupLastDistance = 0;
  int _groupLastSeconds = 0;
  DateTime? _lastGroupPoll;
  DateTime? _lastGroupPublish;

  @visibleForTesting
  Future<void> publishGroupProgressForTesting() => _publishGroupProgress();

  Future<void> _publishGroupProgress() async {
    final room = _groupRideService.activeRoomId;
    if (room == null || _publishingGroup || _disposed || !_hasCurrentOwner) {
      return;
    }
    _publishingGroup = true;
    try {
      final grouped = _hasSession && _workoutGroupRoomId == room;
      final interval = grouped ? 5 : (_sharingForeground ? 15 : 60);
      if (_lastGroupRoom == room &&
          _lastGroupPublish != null &&
          DateTime.now().difference(_lastGroupPublish!).inSeconds < interval) {
        return;
      }
      _lastGroupPublish = DateTime.now();
      if (_lastGroupRoom != room ||
          _lastGroupRevision != _groupRideService.membershipRevision) {
        _lastGroupRevision = _groupRideService.membershipRevision;
        _lastGroupRoom = room;
        _groupHadWorkout = false;
        _groupLastDistance = 0;
        _groupLastSeconds = 0;
        final restored = _groupRideService.members
            .where((member) => member.userId == _groupRideService.userId)
            .firstOrNull;
        if (restored != null) {
          _groupLastDistance = restored.distanceMeters;
          _groupLastSeconds = restored.durationSeconds;
          _groupHadWorkout = restored.workoutState == 'finished';
        }
      }
      if (grouped) {
        _groupHadWorkout = true;
        _groupLastDistance = _totalDistanceMeters;
        _groupLastSeconds = _activeDuration.inSeconds;
      }
      final share =
          grouped &&
          gpsSignal.value.quality == GpsQuality.good &&
          _shareLivePosition &&
          (_sharingForeground || (_hasSession && _backgroundTrackingEnabled));
      await _groupRideService.updateProgress(
        room,
        distanceMeters: _groupLastDistance,
        durationSeconds: _groupLastSeconds,
        latitude: share ? _currentLocation.latitude : null,
        longitude: share ? _currentLocation.longitude : null,
        workoutState: grouped
            ? (_isWorkoutPaused ? 'paused' : 'active')
            : _groupHadWorkout
            ? 'finished'
            : 'waiting',
      );
      if (_lastGroupPoll == null ||
          DateTime.now().difference(_lastGroupPoll!).inSeconds >= 15) {
        _lastGroupPoll = DateTime.now();
        await _groupRideService.refreshMembers();
      }
    } catch (error) {
      debugPrint('[GroupRide] heartbeat: $error');
    } finally {
      _publishingGroup = false;
    }
  }

  // --- Быстрые каналы обновлений (оптимизация перерисовок) ---
  // GPS-точки и события компаса приходят по нескольку раз в секунду. Полный
  // notifyListeners() на каждый тик перестраивал бы ВЕСЬ экран карты. Поэтому
  // быстро меняющиеся значения вынесены в ValueNotifier'ы: их слушают только
  // маркер райдера и панель метрик, а notifyListeners() остаётся для смены
  // состояний (старт/пауза/финиш/маршрут/друзья) — это редкие события.
  final ValueNotifier<LatLng> positionNotifier = ValueNotifier<LatLng>(
    const LatLng(52.5200, 13.4050),
  );
  final ValueNotifier<double> headingListenable = ValueNotifier<double>(0.0);

  /// Тик метрик заезда (скорость/дистанция/время/уклон). Слушается только
  /// панелью метрик.
  final ValueNotifier<int> workoutTick = ValueNotifier<int>(0);
  final ValueNotifier<GpsSignal> gpsSignal = ValueNotifier(const GpsSignal());
  Timer? _gpsWatchdog;
  late final _gpsFreshnessProbe = GpsFreshnessProbe(
    read: () => Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 10),
    ),
    current: () => gpsSignal.value,
    accept: _acceptFreshnessProbe,
  );

  Timer? _gpsRecoveryTimer;
  int _gpsStreamEpoch = 0, _gpsRecoveryAttempts = 0;
  bool _streamFailed = false, _waitingForRecoveredStream = false;
  bool get isGpsStreamRecovering =>
      _hasSession &&
      (_streamFailed ||
          _waitingForRecoveredStream ||
          _gpsRecoveryTimer != null);
  String get gpsRecoveryStatus =>
      _gpsRecoveryAttempts >= 5 &&
          _gpsRecoveryTimer == null &&
          _locationInitialization == null
      ? 'GPS не восстановлен. Повторите поиск геопозиции на карте.'
      : 'Восстанавливаем запись GPS…';
  DateTime? _lastStreamFixAt, _streamStartedAt;
  Position? _lastStreamPosition, _stationaryProbe;

  bool _validPosition(Position p, {DateTime? observedAt}) {
    final now = observedAt ?? _gpsNow();
    return p.latitude.isFinite &&
        p.longitude.isFinite &&
        p.latitude.abs() <= 90 &&
        p.longitude.abs() <= 180 &&
        !p.timestamp.isAfter(now.add(const Duration(seconds: 5))) &&
        now.difference(p.timestamp) <= const Duration(seconds: 30);
  }

  void _scheduleGpsRecovery() {
    if (_disposed ||
        !_hasCurrentOwner ||
        (!_hasSession && !_isNavigating) ||
        _gpsRecoveryTimer != null ||
        _gpsRecoveryAttempts >= 5)
      return;
    const delays = [1, 5, 15, 30, 60];
    final session = _sessionLocalId;
    _gpsRecoveryTimer = Timer(
      Duration(seconds: delays[_gpsRecoveryAttempts]),
      () async {
        _gpsRecoveryTimer = null;
        if (_disposed ||
            !_hasCurrentOwner ||
            session != _sessionLocalId ||
            (!_hasSession && !_isNavigating))
          return;
        _gpsRecoveryAttempts++;
        UsageStatistics.instance.record(UsageEvent.gpsRecoveryStarted);
        _waitingForRecoveredStream = true;
        _breakTrackSegment = true;
        try {
          await initLocationTracking(requestPermission: false);
        } catch (_) {
          /* Retry is bounded. */
        }
        if (_streamFailed || !_locationReady) _scheduleGpsRecovery();
      },
    );
  }

  @visibleForTesting
  void acceptFreshnessProbeForTesting(Position p) => _acceptFreshnessProbe(p);

  void _acceptFreshnessProbe(Position p) {
    if (_disposed || !_hasCurrentOwner || !_validPosition(p)) return;
    _updateGpsSignal(p);
    final accurate = p.accuracy.isFinite && p.accuracy >= 0 && p.accuracy <= 20;
    final last = _lastStreamPosition;
    final anchorTime = _lastStreamFixAt ?? _streamStartedAt;
    if (accurate &&
        last != null &&
        anchorTime != null &&
        _gpsNow().difference(anchorTime) > const Duration(seconds: 45) &&
        _streamStartedAt != null &&
        _gpsNow().difference(_streamStartedAt!) > const Duration(seconds: 45) &&
        GeoUtils.distanceBetween(
              LatLng(last.latitude, last.longitude),
              LatLng(p.latitude, p.longitude),
            ) >
            math.max(30, last.accuracy + p.accuracy)) {
      _scheduleGpsRecovery();
    }
    // Two fresh independent low-speed fixes establish a stop; silence alone does not.
    final previous = _stationaryProbe;
    final slow =
        accurate &&
        p.speed.isFinite &&
        p.speed >= 0 &&
        p.speed * 3.6 < _autoPauseBelowKmh &&
        p.speedAccuracy.isFinite &&
        p.speedAccuracy > 0 &&
        (p.speed + p.speedAccuracy) * 3.6 < _autoPauseBelowKmh;
    if (!slow) {
      _stationaryProbe = null;
      return;
    }
    _stationaryProbe = p;
    if (_autoPauseEnabled &&
        _isWorkoutActive &&
        !_isWorkoutPaused &&
        previous != null &&
        p.timestamp.difference(previous.timestamp) >= _autoPauseDelay &&
        p.timestamp.difference(previous.timestamp) <=
            const Duration(seconds: 45) &&
        GeoUtils.distanceBetween(
              LatLng(previous.latitude, previous.longitude),
              LatLng(p.latitude, p.longitude),
            ) <=
            math.max(3, math.min(5, previous.accuracy + p.accuracy))) {
      _autoPause();
    }
  }

  void _updateGpsSignal(Position position, {DateTime? observedAt}) {
    if (_disposed) return;
    gpsSignal.value = GpsSignal(
      accuracy: position.accuracy,
      updatedAt: position.timestamp,
    ).checkedAt(observedAt ?? _gpsNow());
  }

  LatLng _currentLocation = const LatLng(52.5200, 13.4050);
  double _currentHeading = 0.0;
  bool _isFollowingUser = true;
  bool _autoRotateMap = true;
  bool _isNavigating = false;
  bool _isBookmarked = false;

  LatLng? _finishPoint;
  String _finishAddress = 'Выбранная точка';
  List<LatLng> _routePoints = [];
  Set<int> _routeSegmentStarts = {};
  List<int> get routeSegmentStarts => _routeSegmentStarts.toList()..sort();
  List<List<LatLng>> get routeSegments =>
      WorkoutDetails.splitTrack(_routePoints, routeSegmentStarts);
  List<LatLng> get routeWaypoints => List.unmodifiable(_routeVia);
  bool get canEditWaypoints =>
      _finishPoint != null &&
      _routePoints.length >= 2 &&
      !_preserveTrack &&
      !_isNavigating &&
      !_isLoadingRoute;
  List<RouteStep> _routeSteps = [];
  List<LatLng> _routeVia = [];
  List<double> _viaOffsetsMeters = [];
  String? _routeError;
  String? get routeError => _routeError;
  String? routeNotice;
  int _currentStepIndex = 0;
  double _navigationProgressMeters = 0;
  bool _needsRouteReacquire = false;
  DateTime? _lastNavigationFixAt;
  LatLng? _lastNavigationFixPosition;

  double? _routeDistanceKm;
  double? _routeDurationMin;
  int _elevationGainMeters = 0;
  int _elevationLossMeters = 0;

  /// Покрытие маршрута по данным OSM. `null` — Overpass недоступен или данных
  /// нет: UI показывает «нет данных», а не выдуманные проценты.
  SurfaceInfo? _surfaceInfo;
  ActivityType _selectedActivity = ActivityType.mountainBiking;

  bool _isLoadingRoute = false;
  DateTime? _lastRerouteTime;

  StreamSubscription<Position>? _positionStreamSubscription;
  StreamSubscription<ServiceStatus>? _locationServiceSubscription;
  Future<void>? _locationInitialization;
  bool _locationReady = false;
  bool _locationServiceWatchStarted = false;
  bool _disposed = false;
  bool _isSavingWorkout = false;
  bool get isSavingWorkout => _isSavingWorkout;
  int _routeGeneration = 0;
  int _streamGeneration = 0;
  Future<void> _streamRestartTail = Future.value();
  final Stopwatch _activeClock;
  Duration _elapsedBeforeCurrentSegment = Duration.zero;
  String? _sessionLocalId;
  DateTime? _lastDraftQueuedAt;
  DateTime? _sessionStartedAt;
  ActivityType? _sessionActivity;
  Vehicle? _sessionVehicle;
  bool _sessionEbike = false;
  double _calorieWeightKg = 70;
  double _sessionCalorieRate = 0;
  Map<String, dynamic>? _sessionEnergyModel;
  BrakeLoadRecorder? _brakeLoad;
  int _calorieAccountedMs = 0;
  Map<String, dynamic>? _sessionPowerModel;
  int _powerGradeGoodFixes = 0;
  bool _telemetryWasGood = false;
  void _onTelemetryQualityChanged() {
    final good = gpsSignal.value.quality == GpsQuality.good;
    if (!_disposed && _hasSession && _telemetryWasGood && !good) {
      _captureWorkoutSample(force: true);
    }
    _telemetryWasGood = good;
  }

  bool get hasPowerEstimate => _sessionPowerModel != null;
  Map<String, dynamic>? get powerModel =>
      _sessionPowerModel == null ? null : Map.unmodifiable(_sessionPowerModel!);
  double? get powerGradePercent =>
      _gradeDistances.length >= 4 &&
          _powerGradeGoodFixes >= _gradeDistances.length &&
          _gradeDistances.last - _gradeDistances.first >= 50 &&
          _workoutGradePercent.isFinite &&
          _workoutGradePercent.abs() <= 20
      ? _workoutGradePercent
      : null;
  double? get estimatedPowerWatts {
    final model = _sessionPowerModel;
    if (model == null ||
        !_isWorkoutActive ||
        gpsSignal.value.quality != GpsQuality.good) {
      return null;
    }
    return CyclingPower.estimate(
      speedKmh: _workoutSpeedKmh,
      riderKg: (model['rider_kg'] as num).toDouble(),
      bikeKg: (model['bike_kg'] as num).toDouble(),
      gradePercent: powerGradePercent,
      cargoKg: (model['cargo_kg'] as num?)?.toDouble() ?? 0,
      cda: (model['cda'] as num?)?.toDouble() ?? .45,
      crr: (model['crr'] as num?)?.toDouble() ?? .008,
    );
  }

  void setCalorieWeightKg(double value) {
    if (!_hasSession && value.isFinite && value >= 20 && value <= 250) {
      _calorieWeightKg = value;
    }
  }

  /// Planning uses the same energy method as a newly started cycling workout.
  double routeCalories(double minutes, double riderKg) {
    final vehicle = _sportMode == SportMode.vehicle ? _preRideVehicle : null;
    final rate =
        CyclingEnergy.supports(_selectedActivity) &&
            vehicle?.transportType != 'Самокат'
        ? CyclingEnergy.rate(
            riderKg: riderKg,
            speedKmh: _selectedActivity.avgSpeedKmH,
            ebike: vehicle?.isEbike ?? false,
            setup: vehicle?.drivetrain?.setup ?? const BikeSetup(),
          )
        : _selectedActivity.kcalPerHour * (riderKg / 70);
    return minutes / 60 * rate;
  }

  void _updateCalories() {
    final model = _sessionEnergyModel;
    final ms = _workoutDuration.inMilliseconds;
    if (model == null) {
      _workoutCalories = ms / 3600000 * _sessionCalorieRate;
      return;
    }
    final delta = ms - _calorieAccountedMs;
    if (delta <= 0) return;
    final fresh =
        _lastMotionTime != null &&
        DateTime.now().difference(_lastMotionTime!).inSeconds <= 5;
    final rate =
        delta <= 15000 && fresh && gpsSignal.value.quality == GpsQuality.good
        ? CyclingEnergy.rate(
            riderKg: (model['rider_kg'] as num).toDouble(),
            speedKmh: _workoutSpeedKmh,
            ebike: _sessionEbike,
            setup: BikeSetup.fromJson(model['setup']),
          )
        : _sessionCalorieRate;
    _workoutCalories += delta / 3600000 * rate;
    _calorieAccountedMs = ms;
  }

  LatLng? _lastMotionPoint;
  DateTime? _lastMotionTime;
  bool _breakTrackSegment = false;
  final String? _ownerId = UserScope.currentUserId();
  late final WorkoutDraftStore _draftStore = WorkoutDraftStore(_ownerId);
  bool get _hasSession => _isWorkoutActive || _isWorkoutPaused;
  bool get _hasCurrentOwner => UserScope.currentUserId() == _ownerId;
  double get currentGpsHeading => _currentHeading;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void setDisplayHeading(double heading) {
    if (!_disposed && heading.isFinite) headingListenable.value = heading;
  }

  Timer? _workoutTimer;
  Timer? _livePublishTimer;

  /// Фоновый режим (Этап 3): во время заезда трек пишется и с выключенным
  /// экраном. Переключается в Настройках; применяется при рестарте потока.
  bool _backgroundTrackingEnabled = true;

  /// Текущее состояние фонового режима (для экрана настроек).
  bool get backgroundTrackingEnabled => _backgroundTrackingEnabled;

  /// Включает/выключает фоновый режим и перезапускает GPS-поток
  /// (foreground service поднимается/опускается только при пересоздании
  /// подписки).
  void setBackgroundTrackingEnabled(bool enabled) {
    if (_backgroundTrackingEnabled == enabled) return;
    _backgroundTrackingEnabled = enabled;
    unawaited(restartPositionStream());
    notifyListeners();
  }

  /// Приватность: транслировать ли живую позицию друзьям в заезде.
  /// При выключении существующая позиция сразу убирается из трансляции.
  bool _shareLivePosition = false;
  bool get shareLivePosition => _shareLivePosition;

  void setShareLivePosition(bool enabled) {
    BackgroundLocationService.instance.setSharingAllowed(enabled);
    if (_shareLivePosition == enabled) return;
    _shareLivePosition = enabled;
    if (!enabled) {
      unawaited(_friendService.clearLivePosition());
    } else {
      unawaited(_publishLivePosition(_currentLocation));
    }
    notifyListeners();
  }

  /// Перезапускает GPS-поток (после смены настроек фонового режима или
  /// старта/финиша заезда — для foreground-уведомления).
  Future<void> restartPositionStream({bool? withForeground}) {
    final generation = ++_streamGeneration;
    final operation = _streamRestartTail.then((_) async {
      final old = _positionStreamSubscription;
      _positionStreamSubscription = null;
      await old?.cancel();
      if (_disposed || generation != _streamGeneration || !_locationReady)
        return;
      _positionStreamSubscription = _createPositionStreamSubscription(
        withForeground: withForeground ?? _hasSession,
      );
    });
    _streamRestartTail = operation.catchError((Object error) {
      debugPrint('[GPS] restart failed: $error');
    });
    return _streamRestartTail;
  }

  // Состояние тренировки (Workout Mode)
  WorkoutGoal? _workoutGoal;
  IntervalPlan? _intervalPlan;
  int? _lastIntervalStart;
  IntervalPlan? get intervalPlan => _intervalPlan;
  IntervalPhase? get intervalPhase =>
      _intervalPlan?.phaseAt(activeWorkoutDuration.inSeconds);
  void setIntervalPlan(IntervalPlan? plan) {
    if (_hasSession || _isSavingWorkout || (plan != null && !plan.isValid)) {
      return;
    }
    _intervalPlan = plan;
    notifyListeners();
  }

  int _autoLapMeters = 0;
  DistanceLaps _distanceLaps = DistanceLaps(0);
  int get autoLapMeters => _autoLapMeters;
  List<WorkoutLap> get automaticLaps => List.unmodifiable(_distanceLaps.laps);
  void setAutoLapMeters(int meters) {
    if (_hasSession ||
        _isSavingWorkout ||
        ![0, 1000, 5000, 10000].contains(meters)) {
      return;
    }
    _autoLapMeters = meters;
    notifyListeners();
  }

  final List<WorkoutLap> _workoutLaps = [];
  final List<int> _trackSegmentStarts = [];
  bool _isDiscardingWorkout = false;
  List<List<LatLng>> get recordedSegments =>
      WorkoutDetails.splitTrack(_recordedPath, _trackSegmentStarts);
  final List<WorkoutSample> _workoutSamples = [];
  double _maxWorkoutSpeed = 0;
  int _lastLapSeconds = 0;
  double _lastLapMeters = 0;
  String? _checkpointError;
  WorkoutGoal? get workoutGoal => _workoutGoal;
  List<WorkoutLap> get workoutLaps => List.unmodifiable(_workoutLaps);
  double get maxWorkoutSpeedKmh => _maxWorkoutSpeed;
  String? get checkpointError => _checkpointError;
  Duration get activeWorkoutDuration =>
      _hasSession ? _activeDuration : _workoutDuration;
  double get workoutGoalProgress =>
      _workoutGoal?.progress(
        _totalDistanceMeters,
        activeWorkoutDuration,
        calories: _workoutCalories,
      ) ??
      0;
  ActivityType get workoutActivity => _sessionActivity ?? _selectedActivity;

  void setWorkoutGoal(WorkoutGoal? goal) {
    if (_hasSession || _isSavingWorkout) return;
    _workoutGoal = goal;
    notifyListeners();
  }

  void markWorkoutLap() {
    if (!_isWorkoutActive || _isSavingWorkout || _workoutLaps.length >= 1000) {
      return;
    }
    final seconds = _activeDuration.inSeconds;
    if (seconds - _lastLapSeconds < 1) return;
    _workoutLaps.add(
      WorkoutLap(
        number: _workoutLaps.length + 1,
        distanceMeters: (_totalDistanceMeters - _lastLapMeters).clamp(
          0,
          double.infinity,
        ),
        activeSeconds: seconds - _lastLapSeconds,
        endSeconds: seconds,
      ),
    );
    _lastLapSeconds = seconds;
    _lastLapMeters = _totalDistanceMeters;
    _queueDraft(force: true);
    workoutTick.value++;
  }

  WorkoutDetails _trainingSnapshot({
    String notes = '',
    int? effort,
    bool finish = false,
  }) {
    _workoutDuration = _activeDuration;
    _updateCalories();
    final seconds = _activeDuration.inSeconds;
    final laps = List<WorkoutLap>.of(_workoutLaps);
    if (finish && laps.isNotEmpty && seconds > _lastLapSeconds) {
      laps.add(
        WorkoutLap(
          number: laps.length + 1,
          distanceMeters: (_totalDistanceMeters - _lastLapMeters).clamp(
            0,
            double.infinity,
          ),
          activeSeconds: seconds - _lastLapSeconds,
          endSeconds: seconds,
        ),
      );
    }
    return WorkoutDetails(
      walkingSteps: _stepTracker.snapshot,
      autoLapMeters: _autoLapMeters,
      intervalPlan: _intervalPlan,
      autoLaps: List.unmodifiable(_distanceLaps.laps),
      segmentStarts: List.unmodifiable(_trackSegmentStarts),
      goal: _workoutGoal,
      laps: List.unmodifiable(laps),
      samples: List.unmodifiable(_workoutSamples),
      maxSpeedKmh: _maxWorkoutSpeed,
      elapsedSeconds: _sessionStartedAt == null
          ? seconds
          : DateTime.now()
                .difference(_sessionStartedAt!)
                .inSeconds
                .clamp(seconds, 2147483647),
      notes: notes,
      effort: effort,
      calorieRatePerHour: _sessionCalorieRate,
      powerModel: _sessionPowerModel,
      brakeLoad: _brakeLoad?.snapshot,
      energyModel: _sessionEnergyModel == null
          ? null
          : {
              ..._sessionEnergyModel!,
              'kcal': _workoutCalories,
              'active_ms': _calorieAccountedMs,
            },
    );
  }

  void _captureWorkoutSample({bool force = false}) {
    final seconds = _activeDuration.inSeconds;
    if (!force &&
        _workoutSamples.isNotEmpty &&
        seconds - _workoutSamples.last.activeSeconds < 10) {
      return;
    }
    final reliable =
        gpsSignal.value.quality == GpsQuality.good && _isWorkoutActive;
    if (reliable && _workoutSpeedKmh > _maxWorkoutSpeed) {
      _maxWorkoutSpeed = _workoutSpeedKmh;
    }
    _workoutSamples.add(
      WorkoutSample(
        activeSeconds: seconds,
        distanceMeters: _totalDistanceMeters,
        speedKmh: reliable ? _workoutSpeedKmh : null,
        trackPointIndex: reliable && _recordedPath.isNotEmpty
            ? _recordedPath.length - 1
            : null,
        altitudeMeters:
            reliable && _gradeAltitudes.isNotEmpty && _powerGradeGoodFixes > 0
            ? _gradeAltitudes.last
            : null,
        estimatedWatts: reliable ? estimatedPowerWatts : null,
        powerGradePercent: reliable ? powerGradePercent : null,
        elapsedSeconds: _sessionStartedAt == null
            ? seconds
            : DateTime.now().difference(_sessionStartedAt!).inSeconds,
      ),
    );
    if (_workoutSamples.length > 7200) _workoutSamples.removeAt(0);
  }

  bool _isWorkoutActive = false;
  final List<LatLng> _recordedPath = [];
  DateTime? _workoutStartTime;
  double _totalDistanceMeters = 0.0;
  double _workoutSpeedKmh = 0.0;
  double _workoutCalories = 0.0;
  double _averageSpeedKmh = 0.0;
  Duration _workoutDuration = Duration.zero;
  bool _isWorkoutPaused = false;

  // --- Умная автопауза (Smart Auto-Pause) ---
  /// Порог автопаузы: ниже этой скорости (км/ч) считаем, что стоим.
  static const double _autoPauseBelowKmh = 1.5;

  /// Порог авторезюма: выше этой скорости (км/ч) продолжаем заезд.
  static const double _autoResumeAboveKmh = 2.0;

  /// Сколько секунд подряд скорость должна держаться ниже порога.
  static const Duration _autoPauseDelay = Duration(seconds: 3);

  bool _autoPauseEnabled = true;
  bool _isAutoPaused = false;
  DateTime? _lowSpeedSince;
  double _instantSpeedKmh = 0.0;

  // --- Фильтрация мусорных GPS-точек (Этап B) ---
  /// Максимальная допустимая погрешность точки: хуже — шум, не записываем.
  static const double _maxAcceptableAccuracyMeters = 20.0;

  /// Скорость между соседними точками выше этой — «телепорт» (глитч).
  static const double _maxPlausibleKmh = 100.0;
  DateTime? _lastAcceptedPointAt;

  /// Стоит ли записывать точку в трек: фильтр точности и телепортов.
  bool _acceptTrackPoint(LatLng point, Position position) {
    // Точность сигнала: GPS с погрешностью > 20 м рисует «пилу» сквозь дома.
    final accuracy = position.accuracy;
    if (!accuracy.isFinite ||
        accuracy < 0 ||
        accuracy > _maxAcceptableAccuracyMeters) {
      return false;
    }

    final last = _recordedPath.isEmpty ? null : _recordedPath.last;
    if (last == null) {
      _lastAcceptedPointAt = position.timestamp;
      return true;
    }

    // Телепорт: слишком быстрое перемещение между соседними точками
    // физически невозможно — это глитч, отбрасываем.
    final time = position.timestamp;
    final lastTime = _lastAcceptedPointAt;
    if (lastTime != null) {
      final dtSeconds = time.difference(lastTime).inMilliseconds / 1000.0;
      if (dtSeconds <= 0) return false;
      if (dtSeconds > 0) {
        final meters = GeoUtils.distanceBetween(last, point);
        final kmh = meters / dtSeconds * 3.6;
        if (kmh > _maxPlausibleKmh) return false;
      }
    }
    _lastAcceptedPointAt = time;
    return true;
  }

  // --- Скользящее окно скорости (по реальным таймстампам точек) ---
  /// Окно усреднения скорости: скорость = дистанция за окно / реальная
  /// длительность окна. Фиксированные «10 точек = 10 секунд» врали: точки
  /// приходят неравномерно (distanceFilter), при ходьбе 10 точек покрывают
  /// до 30–40 с, и скорость завышалась в разы.
  static const Duration _speedWindow = Duration(seconds: 15);
  static const double _speedWindowMinSpanSeconds = 3.0;
  final List<DateTime> _speedWindowTimes = [];
  final List<double> _speedWindowDistances = []; // накопленная дистанция
  /// Момент последней GPS-точки: если GPS молчит дольше порога — стоим.
  DateTime? _lastSpeedSampleAt;

  // --- Сообщество: друзья на карте ---
  /// Друзья (публичные профили + живая позиция, если друг сейчас в заезде).
  List<FriendProfile> get friends => List.unmodifiable(_friends.values);

  /// Друзья с актуальной (не протухшей) живой позицией.
  List<FriendProfile> get friendsOnMap =>
      _friends.values.where((friend) => friend.hasLivePosition).toList();

  /// Подписка на друзей и их живые позиции. Вызывается один раз при старте
  /// карты; изменения позиции друзей приходят в Realtime и уведомляют UI.
  Future<void> startFriendsTracking() async {
    if (_friendsTrackingStarted || !FriendService.isAvailable) return;
    _friendsTrackingStarted = true;
    _groupRideService.addListener(notifyListeners);
    unawaited(_groupRideService.restoreSession());
    _groupProgressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_publishGroupProgress()),
    );
    _friendStatusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_disposed &&
          _friends.values.any((friend) => friend.hasLivePosition)) {
        notifyListeners();
      }
    });
    final cached = await _friendService.loadCachedFriends();
    if (_disposed || !_hasCurrentOwner) return;
    if (cached != null) {
      _friends.addEntries(cached.map((friend) => MapEntry(friend.id, friend)));
      notifyListeners();
    }
    await _friendService.subscribePositions(_onFriendPositionChanged);
    await _refreshFriends();
  }

  /// Обновляет список друзей (после добавления/удаления в экране друзей).
  Future<void> _refreshFriends() async {
    if (_refreshingFriends || _disposed || !_hasCurrentOwner) return;
    _refreshingFriends = true;
    try {
      final friends = await _friendService.fetchFriends();
      if (_disposed || !_hasCurrentOwner) return;
      _friends
        ..clear()
        ..addEntries(friends.map((friend) => MapEntry(friend.id, friend)));
      notifyListeners();
    } finally {
      _refreshingFriends = false;
    }
  }

  /// Перечитать друзей (публичный вызов из экрана друзей после изменений).
  Future<void> refreshFriends() => _refreshFriends();

  void _onFriendPositionChanged(
    String userId,
    double lat,
    double lon,
    DateTime updatedAt,
    double? speedKmh,
    String? activity,
    bool paused,
  ) {
    final friend = _friends[userId];
    if (friend == null) return; // не друг — игнорируем
    _friends[userId] = friend.copyWith(
      liveLatitude: lat,
      liveLongitude: lon,
      liveUpdatedAt: updatedAt,
      liveSpeedKmh: speedKmh,
      liveActivity: activity,
      livePaused: paused,
    );
    notifyListeners();
  }

  // --- Предзапуск заезда (Pre-Ride HUD) ---
  /// Техника, выбранная в HUD предзапуска. По умолчанию — активная из `garage`
  /// (is_active == true); при «ПОЕХАЛИ» привязывается к сессии.
  Vehicle? _preRideVehicle;
  SportMode _sportMode = SportMode.vehicle;

  Vehicle? get preRideVehicle => _preRideVehicle;
  bool _gearLabEnabled = false;
  bool get gearLabEnabled => _gearLabEnabled;
  Vehicle? get gearVehicle => _hasSession ? _sessionVehicle : _preRideVehicle;
  void setGearLabEnabled(bool value) {
    _gearLabEnabled = value;
    notifyListeners();
    if (value) unawaited(refreshEquipment());
  }

  Future<void> refreshEquipment() async {
    if (_disposed || !_hasCurrentOwner) return;
    final vehicle = gearVehicle;
    if (vehicle == null) {
      await initPreRideVehicle();
      return;
    }
    try {
      final fresh = await _garageService.fetchVehicle(vehicle.id);
      if (_disposed || !_hasCurrentOwner) return;
      if (_hasSession && _sessionVehicle?.id == fresh.id) {
        _sessionVehicle = fresh;
      } else if (!_hasSession && _preRideVehicle?.id == fresh.id) {
        _preRideVehicle = fresh;
      }
      notifyListeners();
    } on GarageServiceException catch (_) {
      /* Остаётся последняя загруженная конфигурация. */
    }
  }

  Future<void> refreshPrimaryVehicle() async {
    if (_hasSession || _disposed || !_hasCurrentOwner) return;
    final vehicles = await _garageService.fetchVehicles();
    if (_hasSession ||
        _disposed ||
        !_hasCurrentOwner ||
        !_garageService.lastFetchSucceeded) {
      return;
    }
    _preRideVehicle = vehicles.where((v) => v.isActive).firstOrNull;
    _syncSelectedActivity();
    notifyListeners();
  }

  SportMode get sportMode => _sportMode;

  /// Электропривод — свойство выбранной техники из гаража (is_ebike),
  /// а не переключатель заезда.
  bool get isEbikeMode =>
      _sportMode == SportMode.vehicle && (_preRideVehicle?.isEbike ?? false);

  void setPreRideVehicle(Vehicle? vehicle) {
    if (_hasSession || _isSavingWorkout || _preRideVehicle == vehicle) return;
    _preRideVehicle = vehicle;
    _syncSelectedActivity();
    notifyListeners();
  }

  void setSportMode(SportMode mode) {
    if (_hasSession || _isSavingWorkout || _sportMode == mode) return;
    _sportMode = mode;
    _syncSelectedActivity();
    notifyListeners();
  }

  /// Тип заезда по режиму: вело — из техники (её транспортный тип мапится
  /// в ActivityType), пешком/бег — фиксированные типы без техники.
  ActivityType _resolvedActivity() {
    switch (_sportMode) {
      case SportMode.vehicle:
        return _preRideVehicle?.activityType ?? ActivityType.mountainBiking;
      case SportMode.walking:
        return ActivityType.hiking;
      case SportMode.running:
        return ActivityType.running;
      case SportMode.briskWalking:
        return ActivityType.briskWalking;
      case SportMode.nordicWalking:
        return ActivityType.nordicWalking;
      case SportMode.trekking:
        return ActivityType.trekking;
      case SportMode.trailRunning:
        return ActivityType.trailRunning;
    }
  }

  /// Синхронизирует _selectedActivity с режимом — от него зависят
  /// маршрутизация, калории и transport_type в таблице rides.
  void _syncSelectedActivity() {
    final next = _resolvedActivity();
    if (next != _selectedActivity) {
      _selectedActivity = next;
      _invalidateRouteForActivity();
    }
  }

  void _invalidateRouteForActivity() {
    VoiceGuidanceService.instance.resetTurns();
    unawaited(VoiceGuidanceService.instance.stop());
    _routeGeneration++;
    final hadRoute = _isLoadingRoute || _routePoints.isNotEmpty;
    _isLoadingRoute = false;
    if (_preserveTrack) {
      if (_routeDistanceKm != null)
        _routeDurationMin =
            _routeDistanceKm! / _selectedActivity.avgSpeedKmH * 60;
      return;
    }
    _routePoints = [];
    _routeSteps = [];
    _routeSegmentStarts = {};
    _viaOffsetsMeters = [];
    _routeDistanceKm = null;
    _routeDurationMin = null;
    _surfaceInfo = null;
    _elevationGainMeters = 0;
    _elevationLossMeters = 0;
    _isNavigating = false;
    _currentStepIndex = 0;
    _navigationProgressMeters = 0;
    _routeError = hadRoute
        ? 'Вид активности изменён. Постройте маршрут заново для ${_selectedActivity.label}.'
        : null;
  }

  /// Техника в кэше сервиса гаража (после [fetchGarageVehicles]).
  List<Vehicle> get garageVehicles => _garageService.vehicles;

  /// Подтягивает список техники из Supabase (`garage`).
  Future<List<Vehicle>> fetchGarageVehicles() => _garageService.fetchVehicles();

  /// Подставляет технику по умолчанию — активную из `garage` (is_active == true).
  /// Ничего не делает, если пользователь уже выбрал технику вручную.
  Future<void> initPreRideVehicle() async {
    if (_preRideVehicle != null) return;
    try {
      final vehicle = await _garageService.fetchActiveVehicle();
      if (!_disposed &&
          !_hasSession &&
          _preRideVehicle == null &&
          vehicle != null) {
        _preRideVehicle = vehicle;
        _syncSelectedActivity();
        notifyListeners();
      }
    } catch (error) {
      debugPrint('[PreRide] не удалось получить активную технику: $error');
    }
  }

  // --- Расчёт уклона (Grade %) ---
  /// Окно расчёта уклона: последние N GPS-точек.
  static const int _gradeSampleWindow = 10;

  /// Минимальная дельта дистанции (м), ниже которой уклон не считаем.
  static const double _gradeMinDistanceMeters = 1.0;
  final List<double> _gradeAltitudes = [];
  final List<double> _gradeDistances = [];
  double _workoutGradePercent = 0.0;

  // --- Реальный набор высоты ---
  /// Шум GPS-высоты (м): дельты меньше порога не учитываем.
  static const double _elevationNoiseMeters = 1.5;
  double _workoutElevationGain = 0.0;
  double _lastWorkoutAltitude = double.nan;

  // Геттеры
  LatLng get currentLocation => _currentLocation;
  double get currentHeading => _currentHeading;
  bool get isFollowingUser => _isFollowingUser;
  bool get autoRotateMap => _autoRotateMap;
  bool get isNavigating => _isNavigating;
  bool get isBookmarked => _isBookmarked;
  LatLng? get finishPoint => _finishPoint;
  String get finishAddress => _finishAddress;
  List<LatLng> get routePoints => _routePoints;
  List<RouteStep> get routeSteps => _routeSteps;
  int get currentStepIndex => _currentStepIndex;
  double? get distanceToNextTurnMeters => _routeSteps.isEmpty
      ? null
      : math.max(
          0.0,
          _routeSteps[_currentStepIndex.clamp(0, _routeSteps.length - 1)]
                  .routeOffsetMeters -
              _navigationProgressMeters,
        );
  double get remainingRouteMeters =>
      math.max(0.0, (_routeDistanceKm ?? 0) * 1000 - _navigationProgressMeters);
  double get remainingRouteMinutes {
    final total = (_routeDistanceKm ?? 0) * 1000;
    return total > 0
        ? (_routeDurationMin ?? 0) * remainingRouteMeters / total
        : 0;
  }

  double? get routeDistanceKm => _routeDistanceKm;
  double? get routeDurationMin => _routeDurationMin;
  int get elevationGainMeters => _elevationGainMeters;
  int get elevationLossMeters => _elevationLossMeters;

  /// Покрытие маршрута из Overpass; `null` — данных нет.
  SurfaceInfo? get surfaceInfo => _surfaceInfo;
  ActivityType get selectedActivity => _selectedActivity;
  bool get isLoadingRoute => _isLoadingRoute;

  // Геттеры тренировки
  bool get isWorkoutActive => _isWorkoutActive;

  /// Stable across pause/resume, unlike the moving segment start time.
  String? get workoutSessionId => _sessionLocalId;
  DateTime? get workoutSessionStartedAt => _sessionStartedAt;
  WorkoutDetails get achievementWorkoutDetails => WorkoutDetails(
    samples: List.unmodifiable(_workoutSamples),
    powerModel: _sessionPowerModel,
  );
  List<LatLng> get recordedPath => _recordedPath;
  List<int> get recordedSegmentStarts => List.unmodifiable(_trackSegmentStarts);
  DateTime? get workoutStartTime => _workoutStartTime;
  double get totalDistanceMeters => _totalDistanceMeters;
  double get workoutSpeedKmh => _workoutSpeedKmh;
  double get workoutCalories => _workoutCalories;
  double get averageSpeedKmh => _averageSpeedKmh;
  Duration get workoutDuration => _workoutDuration;
  bool get isWorkoutPaused => _isWorkoutPaused;

  // Геттеры автопаузы и уклона
  bool get autoPauseEnabled => _autoPauseEnabled;

  /// true, когда заезд остановлен именно автопаузой (не вручную).
  bool get isAutoPaused => _isAutoPaused;

  /// Мгновенная скорость по дельте GPS-точек (км/ч).
  double get instantSpeedKmh => _instantSpeedKmh;

  /// Текущий уклон в процентах: (delta_altitude / delta_distance) * 100
  /// за последние [_gradeSampleWindow] GPS-точек. Без данных о высоте или
  /// без движения — 0.
  double get workoutGradePercent => _workoutGradePercent;

  /// Набранный за заезд подъём в метрах (сумма положительных дельт высоты
  /// с отсечкой GPS-шума). 0 — данных о высоте не было.
  double get workoutElevationGain => _workoutElevationGain;

  // Сеттеры с уведомлением
  void setSelectedActivity(ActivityType activity) {
    if (_hasSession || _isSavingWorkout || _selectedActivity == activity) {
      return;
    }
    _selectedActivity = activity;
    _invalidateRouteForActivity();
    notifyListeners();
  }

  void setFinishPoint(LatLng point, String address) {
    clearRoute();
    _routeGeneration++;
    _finishPoint = point;
    _finishAddress = address;
    _isFollowingUser = false;
    _isNavigating = false;
    _isBookmarked = false;
    notifyListeners();
  }

  void setFollowingUser(bool following) {
    if (_isFollowingUser == following) return;
    _isFollowingUser = following;
    notifyListeners();
  }

  void setAutoRotateMap(bool autoRotate) {
    if (_autoRotateMap == autoRotate) return;
    _autoRotateMap = autoRotate;
    notifyListeners();
  }

  void setNavigating(bool navigating) {
    if (_isNavigating == navigating) return;
    _isNavigating = navigating;
    VoiceGuidanceService.instance.resetTurns();
    if (!navigating) unawaited(VoiceGuidanceService.instance.stop());
    _resetDeviation();
    if (_isNavigating) {
      _isFollowingUser = true;
      _autoRotateMap = true;
      _needsRouteReacquire = true;
      _lastNavigationFixAt = null;
      _lastNavigationFixPosition = null;
    }
    unawaited(restartPositionStream());
    notifyListeners();
  }

  void setBookmarked(bool bookmarked) {
    if (_isBookmarked == bookmarked) return;
    _isBookmarked = bookmarked;
    notifyListeners();
  }

  void toggleFollowingUser() {
    _isFollowingUser = !_isFollowingUser;
    notifyListeners();
  }

  void toggleAutoRotate() {
    _autoRotateMap = !_autoRotateMap;
    notifyListeners();
  }

  void toggleNavigation() {
    setNavigating(!_isNavigating);
  }

  void toggleBookmark() {
    _isBookmarked = !_isBookmarked;
    notifyListeners();
  }

  // Управление тренировкой
  Duration get _activeDuration =>
      _elapsedBeforeCurrentSegment + _activeClock.elapsed;

  WorkoutDraft _draftSnapshot() => WorkoutDraft(
    details: _trainingSnapshot(),
    ownerId: _ownerId!,
    localId: _sessionLocalId!,
    startedAt: _sessionStartedAt!,
    activeMilliseconds: _activeDuration.inMilliseconds,
    distanceMeters: _totalDistanceMeters,
    elevationGainMeters: _workoutElevationGain,
    activity: _sessionActivity!,
    path: List<LatLng>.of(_recordedPath),
    vehicleId: _sessionVehicle?.id,
    isEbike: _sessionEbike,
    groupRoomId: _workoutGroupRoomId,
  );

  void _queueDraft({bool force = false}) {
    if (!_hasSession ||
        _isDiscardingWorkout ||
        !_hasCurrentOwner ||
        _ownerId == null ||
        _sessionLocalId == null ||
        _sessionStartedAt == null ||
        _sessionActivity == null) {
      return;
    }
    final now = DateTime.now();
    if (!force &&
        _lastDraftQueuedAt != null &&
        now.difference(_lastDraftQueuedAt!) < const Duration(seconds: 5)) {
      return;
    }
    _lastDraftQueuedAt = now;
    unawaited(
      _draftStore.save(_draftSnapshot()).catchError((Object error) {
        debugPrint('[Workout] checkpoint failed: $error');
        if (!_disposed && _checkpointError == null) {
          _checkpointError = 'Не удалось сохранить контрольную точку. Завершите заезд и проверьте свободное место.';
          notifyListeners();
        }
      }),
    );
  }

  /// An interrupted ride is always resumed paused, so no distance is inferred
  /// across the period when the app was closed.
  Future<WorkoutDraft?> loadInterruptedWorkout() async {
    if (_ownerId == null || !_hasCurrentOwner || _hasSession) return null;
    final draft = await _draftStore.load();
    if (draft == null) return null;
    final history = await _workoutHistoryRepository.getWorkoutHistory();
    if (history.any((ride) => ride.localId == draft.localId)) {
      await _draftStore.delete();
      return null;
    }
    return draft;
  }

  void restoreInterruptedWorkout(WorkoutDraft draft) {
    if (_disposed ||
        _hasSession ||
        _ownerId == null ||
        !_hasCurrentOwner ||
        draft.ownerId != _ownerId) {
      return;
    }
    _workoutGroupRoomId = draft.groupRoomId;
    _trackSegmentStarts
      ..clear()
      ..addAll(draft.details.segmentStarts);
    _workoutGoal = draft.details.goal;
    _intervalPlan = draft.details.intervalPlan;
    _lastIntervalStart =
        _intervalPlan?.phaseAt(draft.activeMilliseconds ~/ 1000)?.start ?? -1;
    _autoLapMeters = draft.details.autoLapMeters;
    _distanceLaps =
        DistanceLaps(_autoLapMeters, completed: draft.details.autoLaps)..seed(
          draft.distanceMeters,
          Duration(milliseconds: draft.activeMilliseconds),
        );
    _workoutLaps
      ..clear()
      ..addAll(draft.details.laps);
    _workoutSamples
      ..clear()
      ..addAll(draft.details.samples);
    _maxWorkoutSpeed = draft.details.maxSpeedKmh;
    _lastLapSeconds = _workoutLaps.isEmpty ? 0 : _workoutLaps.last.endSeconds;
    _lastLapMeters = _workoutLaps.fold(
      0.0,
      (sum, lap) => sum + lap.distanceMeters,
    );
    _sessionLocalId = draft.localId;
    _sessionStartedAt = draft.startedAt;
    _sessionActivity = draft.activity;
    _selectedActivity = draft.activity;
    _sessionEbike = draft.isEbike;
    final energy = draft.details.energyModel;
    final storedKcal = energy?['kcal'];
    final storedRider = energy?['rider_kg'];
    final storedMs = energy?['active_ms'];
    final validEnergy =
        energy?['version'] == 1 &&
        storedKcal is num &&
        storedKcal.isFinite &&
        storedKcal >= 0 &&
        storedRider is num &&
        storedRider.isFinite &&
        storedRider >= 20 &&
        storedRider <= 250 &&
        storedMs is num &&
        storedMs.isFinite &&
        storedMs >= 0 &&
        storedMs <= draft.activeMilliseconds;
    _sessionEnergyModel = validEnergy ? energy : null;
    _brakeLoad = draft.details.brakeLoad == null
        ? null
        : BrakeLoadRecorder(restored: draft.details.brakeLoad);
    _calorieAccountedMs = validEnergy ? storedMs.toInt() : 0;
    _sessionCalorieRate =
        draft.details.calorieRatePerHour ??
        draft.activity.kcalPerHour * (_sessionEbike ? .5 : 1);
    final power = draft.details.powerModel;
    _sessionPowerModel =
        power != null &&
            power['rider_kg'] is num &&
            power['bike_kg'] is num &&
            power['version'] == 1
        ? power
        : null;
    _sessionVehicle = draft.vehicleId == null
        ? null
        : Vehicle(
            id: draft.vehicleId!,
            userId: _ownerId,
            name: 'Транспорт',
            transportType: draft.activity.name,
            isEbike: draft.isEbike,
          );
    _garageService.bindToSession(_sessionVehicle);
    _recordedPath
      ..clear()
      ..addAll(draft.path);
    _elapsedBeforeCurrentSegment = Duration(
      milliseconds: draft.activeMilliseconds,
    );
    _activeClock
      ..stop()
      ..reset();
    _workoutDuration = _elapsedBeforeCurrentSegment;
    _totalDistanceMeters = draft.distanceMeters;
    _waterReminder.configure(_waterReminderMinutes, _workoutDuration);
    _workoutElevationGain = draft.elevationGainMeters;
    _workoutCalories = validEnergy ? storedKcal.toDouble() : 0;
    _updateCalories();
    final hours = _workoutDuration.inMilliseconds / 3600000;
    _averageSpeedKmh = hours > 0 ? draft.distanceMeters / 1000 / hours : 0;
    _workoutStartTime = draft.startedAt;
    _stepTracker.restore(
      WalkingSteps.fromJson(
            draft.details.walkingSteps?.toJson(),
            restorePaused: true,
          ) ??
          (draft.activity.isFoot
              ? WalkingSteps(
                  device: '',
                  windows: const [],
                  observedAt: DateTime.now().millisecondsSinceEpoch,
                  stride: DailyActivityService.instance.strideMeters,
                )
              : null),
    );
    _isWorkoutActive = false;
    _isWorkoutPaused = true;
    _isAutoPaused = false;
    _breakTrackSegment = true;
    _lastAcceptedPointAt = null;
    _lastMotionPoint = null;
    _lastMotionTime = null;
    _startLivePublishTimer();
    unawaited(restartPositionStream());
    notifyListeners();
  }

  Future<void> discardInterruptedWorkout() => _draftStore.delete();

  void checkpointWorkout() => _queueDraft(force: true);

  /// Resolve equipment/sport before planning so starting cannot invalidate the route.
  void prepareWorkoutActivity() {
    if (_hasSession || _isSavingWorkout || _disposed) return;
    _syncSelectedActivity();
    notifyListeners();
  }

  void startWorkout({String? groupRoomId}) {
    if (_hasSession || _isSavingWorkout || _disposed || !_hasCurrentOwner) {
      return;
    }
    if (groupRoomId != null &&
        (groupRoomId != _groupRideService.activeRoomId ||
            _ownerId == null ||
            _groupRideService.userId != _ownerId)) {
      throw StateError('Группа изменилась. Выберите её перед стартом заново.');
    }
    _workoutGroupRoomId = groupRoomId;
    _workoutLaps.clear();
    _distanceLaps = DistanceLaps(_autoLapMeters);
    _lastIntervalStart = _intervalPlan?.phaseAt(0)?.start;
    _trackSegmentStarts.clear();
    _workoutSamples.clear();
    _powerGradeGoodFixes = 0;
    _maxWorkoutSpeed = 0;
    _lastLapSeconds = 0;
    _lastLapMeters = 0;
    _checkpointError = null;
    // Тип заезда определяется выбранным режимом (и техникой для вело):
    // он уедет в rides.transport_type и попадёт в статистику.
    _syncSelectedActivity();
    _isWorkoutActive = true;
    _isWorkoutPaused = false;
    _isAutoPaused = false;
    _lowSpeedSince = null;
    _instantSpeedKmh = 0.0;
    _gradeAltitudes.clear();
    _gradeDistances.clear();
    _workoutGradePercent = 0.0;
    _workoutElevationGain = 0.0;
    _lastWorkoutAltitude = double.nan;
    _speedWindowTimes.clear();
    _speedWindowDistances.clear();
    _lastSpeedSampleAt = null;
    _lastAcceptedPointAt = null;
    _recordedPath.clear();
    _totalDistanceMeters = 0.0;
    _workoutSpeedKmh = 0.0;
    _workoutCalories = 0.0;
    _averageSpeedKmh = 0.0;
    _workoutDuration = Duration.zero;
    _elapsedBeforeCurrentSegment = Duration.zero;
    _waterReminder.configure(_waterReminderMinutes, Duration.zero);
    _sessionLocalId = newRideId();
    _stationaryProbe = null;
    _waitingForRecoveredStream = false;
    _workoutStartTime = DateTime.now();
    _sessionStartedAt = _workoutStartTime;
    _activeClock
      ..reset()
      ..start();
    _lastMotionPoint = null;
    _lastMotionTime = null;
    _breakTrackSegment = false;
    _sessionActivity = _selectedActivity;
    _stepTracker.start(
      foot: _sessionActivity!.isFoot,
      stride: DailyActivityService.instance.strideMeters,
    );
    _sessionVehicle = _sportMode == SportMode.vehicle ? _preRideVehicle : null;
    _sessionEbike = _sessionVehicle?.isEbike ?? false;
    final bikeKg = _sessionVehicle?.weightKg ?? 0;
    final setup = _sessionVehicle?.drivetrain?.setup ?? const BikeSetup();
    _calorieAccountedMs = 0;
    _sessionEnergyModel =
        CyclingEnergy.supports(_selectedActivity) &&
            _sessionVehicle?.transportType != 'Самокат'
        ? {
            'version': 1,
            'method': 'compendium_2024_speed',
            'is_ebike': _sessionEbike,
            'rider_kg': _calorieWeightKg,
            'setup': setup.toJson(),
            'vehicle_id': _sessionVehicle?.id,
            'vehicle_title': _sessionVehicle?.name,
            'bike_kg': bikeKg,
            'component_ids':
                _sessionVehicle?.parts.map((p) => p.id).toList() ?? [],
            'component_names':
                _sessionVehicle?.parts.map((p) => p.name).toList() ?? [],
          }
        : null;
    _sessionPowerModel =
        !_selectedActivity.isFoot &&
            _selectedActivity != ActivityType.driving &&
            !_sessionEbike &&
            _sessionVehicle?.transportType != 'Самокат'
        ? {
            'version': 1,
            'rider_kg': _calorieWeightKg,
            'bike_kg': bikeKg >= 3 && bikeKg <= 80 ? bikeKg : 15.0,
            'bike_mass_assumed': bikeKg < 3 || bikeKg > 80,
            'cda': setup.cda,
            'crr': setup.crr,
            'cargo_kg': setup.cargoKg,
            'rho': 1.225,
            'efficiency': .97,
          }
        : null;
    _sessionCalorieRate = (_sessionEnergyModel != null
        ? CyclingEnergy.rate(
            riderKg: _calorieWeightKg,
            speedKmh: _selectedActivity.avgSpeedKmH,
            ebike: _sessionEbike,
            setup: setup,
          )
        : _selectedActivity.kcalPerHour *
              (_calorieWeightKg / 70) *
              (_sessionEbike ? .5 : 1));
    _brakeLoad = _sessionEnergyModel == null
        ? null
        : BrakeLoadRecorder(
            systemMassKg:
                _calorieWeightKg +
                (bikeKg >= 3 && bikeKg <= 80 ? bikeKg : 15) +
                setup.cargoKg,
            massAssumed: bikeKg < 3 || bikeKg > 80,
          );
    _garageService.bindToSession(_sessionVehicle);
    UsageStatistics.instance.record(UsageEvent.workoutStarted);
    _startWorkoutTimer();
    _captureWorkoutSample(force: true);
    _queueDraft(force: true);
    // No late network fallback: activity and vehicle are frozen at start.
    // Друзья видят вас сразу после старта — даже если вы ещё стоите:
    // первая публикация + таймер каждые 15 секунд (движение не требуется).
    if (_hasGpsFix && _shareLivePosition) {
      unawaited(_publishLivePosition(_currentLocation));
    }
    _startLivePublishTimer();
    // Уведомление в шторке (foreground service): на Android 13+ нужно
    // runtime-разрешение POST_NOTIFICATIONS — запрашиваем при старте.
    unawaited(
      _startRideNotification().catchError((Object error) {
        debugPrint('[Workout] foreground startup failed: $error');
      }),
    );
    notifyListeners();
  }

  /// Поднимает уведомление в шторке на время заезда: перезапускает GPS-поток
  /// с foreground-конфигурацией и запрашивает разрешение на уведомления.
  Future<void> _startRideNotification() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final notification = await NotificationPermissionService.request();
        debugPrint('[Workout] notification permission: $notification');
      } catch (error) {
        debugPrint('[Workout] notification permission failed: $error');
      }
    }
    if (!_disposed && _hasSession) {
      await restartPositionStream(withForeground: true);
    }
  }

  /// Публикация позиции друзьям: реже в покое, чаще во время тренировки.
  /// (в том числе на паузе — вы «висите» на месте остановки).
  Future<void> _publishLivePosition(LatLng point) async {
    if ((!_sharingForeground &&
            (!_hasSession || !_backgroundTrackingEnabled)) ||
        !_shareLivePosition ||
        _disposed ||
        !_hasCurrentOwner) {
      return;
    }
    final fix = gpsSignal.value;
    if (fix.quality != GpsQuality.good) {
      return;
    }
    await _friendService.updateLivePosition(
      point,
      speedKmh: _hasSession ? (_isWorkoutPaused ? 0 : _instantSpeedKmh) : null,
      activity: _hasSession
          ? (_sessionActivity ?? _selectedActivity).name
          : 'idle',
      paused: _hasSession && _isWorkoutPaused,
    );
  }

  void _startLivePublishTimer() {
    _livePublishTimer?.cancel();
    final interval = _hasSession
        ? const Duration(seconds: 5)
        : const Duration(seconds: 30);
    _livePublishTimer = Timer.periodic(interval, (_) {
      if (!_disposed &&
          _hasCurrentOwner &&
          _hasGpsFix &&
          (_sharingForeground || (_hasSession && _backgroundTrackingEnabled)) &&
          _shareLivePosition) {
        unawaited(_publishLivePosition(_currentLocation));
      }
    });
  }

  /// Подтягивает активную технику из `garage` и запоминает её на сессию,
  /// чтобы при «Финише» записать `vehicle_id` без сетевого запроса.
  /// Умная автопауза: как [pauseWorkout], но помечает паузу как автоматическую,
  /// чтобы возобновление произошло само при разгоне выше 2.0 км/ч.
  void _autoPause() {
    if (!_isWorkoutActive || _isWorkoutPaused) return;
    _stepTracker.pause();
    debugPrint(
      '[Workout] автопауза: скорость < $_autoPauseBelowKmh км/ч '
      '${_autoPauseDelay.inSeconds} с подряд',
    );
    _isWorkoutActive = false;
    _isWorkoutPaused = true;
    _brakeLoad?.breakSegment();
    _isAutoPaused = true;
    _activeClock.stop();
    _elapsedBeforeCurrentSegment += _activeClock.elapsed;
    _activeClock.reset();
    _workoutDuration = _elapsedBeforeCurrentSegment;
    _updateCalories();
    _queueDraft(force: true);
    _breakTrackSegment = true;
    _stopWorkoutTimer();
    _lowSpeedSince = null;
    unawaited(restartPositionStream());
    notifyListeners();
  }

  /// Включает/выключает автопаузу. Выключение во время автопаузы сразу
  /// возобновляет заезд; ручная пауза не трогается.
  void setAutoPauseEnabled(bool enabled) {
    if (_autoPauseEnabled == enabled) return;
    _autoPauseEnabled = enabled;
    if (!enabled) {
      _lowSpeedSince = null;
      if (_isWorkoutPaused && _isAutoPaused) resumeWorkout();
    }
    notifyListeners();
  }

  void pauseWorkout() {
    if (!_isWorkoutActive) return;
    UsageStatistics.instance.record(UsageEvent.workoutPaused);
    _stepTracker.pause();
    _isWorkoutActive = false;
    _isWorkoutPaused = true;
    _brakeLoad?.breakSegment();
    _isAutoPaused = false;
    _activeClock.stop();
    _elapsedBeforeCurrentSegment += _activeClock.elapsed;
    _activeClock.reset();
    _workoutDuration = _elapsedBeforeCurrentSegment;
    _updateCalories();
    _queueDraft(force: true);
    _breakTrackSegment = true;
    _stopWorkoutTimer();
    unawaited(restartPositionStream());
    notifyListeners();
  }

  void resumeWorkout() {
    _stationaryProbe = null;
    if (!_isWorkoutPaused || _isSavingWorkout || _disposed) return;
    UsageStatistics.instance.record(UsageEvent.workoutResumed);
    _stepTracker.resume();
    _brakeLoad?.breakSegment();
    _isWorkoutActive = true;
    _isWorkoutPaused = false;
    _isAutoPaused = false;
    _lowSpeedSince = null;
    _breakTrackSegment = true;
    _gradeAltitudes.clear();
    _gradeDistances.clear();
    _lastWorkoutAltitude = double.nan;
    _lastAcceptedPointAt = null;
    _speedWindowTimes.clear();
    _speedWindowDistances.clear();
    _lastSpeedSampleAt = null;
    _activeClock
      ..reset()
      ..start();
    _workoutStartTime = DateTime.now().subtract(_elapsedBeforeCurrentSegment);
    _startWorkoutTimer();
    _queueDraft(force: true);
    unawaited(restartPositionStream());
    notifyListeners();
  }

  void finishWorkout() {
    unawaited(
      finishAndSaveWorkout().catchError((Object error) {
        debugPrint('[Workout] finish failed: $error');
        return null;
      }),
    );
  }

  /// A non-null result means the immutable snapshot was durably saved locally.
  Future<SavedRoute?> finishAndSaveWorkout({
    String? title,
    String notes = '',
    int? effort,
  }) async {
    if (!_hasSession || _isSavingWorkout || _disposed) return null;
    if (!_hasCurrentOwner) throw StateError('Аккаунт изменился');
    _isSavingWorkout = true;
    _stepTracker.pause();
    if (_isWorkoutActive) {
      _activeClock.stop();
      _elapsedBeforeCurrentSegment += _activeClock.elapsed;
      _activeClock.reset();
    }
    _workoutDuration = _elapsedBeforeCurrentSegment;
    _stopWorkoutTimer();
    _startLivePublishTimer();
    _isWorkoutActive = false;
    _isWorkoutPaused = true;
    await _stepTracker.refresh().timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
    final activity = _sessionActivity ?? _selectedActivity;
    _updateCalories();
    _captureWorkoutSample(force: true);
    final route = SavedRoute(
      workoutDetails: _trainingSnapshot(
        notes: notes.trim(),
        effort: effort,
        finish: true,
      ),
      localId: _sessionLocalId,
      title: title?.trim().isNotEmpty == true
          ? title!.trim()
          : 'Тренировка ${(_sessionStartedAt ?? DateTime.now()).toString().substring(0, 16)}',
      distance: '${(_totalDistanceMeters / 1000).toStringAsFixed(2)} км',
      duration: workoutDurationLabel(_workoutDuration),
      distanceMeters: _totalDistanceMeters,
      durationSeconds: _workoutDuration.inSeconds,
      calories: _workoutCalories,
      vehicleId: _sessionVehicle?.id,
      transportType: activity.name,
      surfaceSummary: _recordedPath.isEmpty
          ? 'Без GPS-трека'
          : 'Записанный GPS-трек',
      finishPoint: _recordedPath.isNotEmpty
          ? _recordedPath.last
          : _currentLocation,
      // Preserve raw observations: car map matching must not rewrite a bike/foot ride.
      routePoints: List<LatLng>.unmodifiable(_recordedPath),
      activityType: activity,
      createdAt: _sessionStartedAt ?? DateTime.now(),
      elevationGainMeters: _workoutElevationGain,
    );
    notifyListeners();
    try {
      _queueDraft(force: true);
      await _workoutHistoryRepository.addWorkout(route);
      UsageStatistics.instance.record(UsageEvent.workoutSaved);
      if (!_disposed) _resetWorkoutState();
      try {
        await _draftStore.delete();
      } catch (error) {
        // The stable localId makes a stale draft recognizable on next launch.
        debugPrint('[Workout] checkpoint cleanup failed: $error');
      }
      // Local success is not contingent on a cloud round trip.
      unawaited(
        _workoutHistoryRepository.retryUnsynced().catchError((Object error) {
          debugPrint('[Workout] cloud retry failed: $error');
          return 0;
        }),
      );
      return route;
    } catch (_) {
      UsageStatistics.instance.record(UsageEvent.workoutSaveFailed);
      // Preserve the track on a local write error. Retry Finish or Resume.
      if (!_disposed) _startLivePublishTimer();
      rethrow;
    } finally {
      _isSavingWorkout = false;
      if (!_disposed) {
        await restartPositionStream();
        notifyListeners();
      }
    }
  }

  Future<void> discardWorkout() async {
    if (!_hasSession || _isSavingWorkout || !_hasCurrentOwner) return;
    if (_isWorkoutActive) pauseWorkout();
    _isSavingWorkout = true;
    _isDiscardingWorkout = true;
    _stopWorkoutTimer();
    _startLivePublishTimer();
    notifyListeners();
    try {
      await _draftStore.delete();
      UsageStatistics.instance.record(UsageEvent.workoutDiscarded);
      if (!_disposed) _resetWorkoutState();
    } finally {
      _isSavingWorkout = false;
      _isDiscardingWorkout = false;
      if (!_disposed) {
        await restartPositionStream();
        notifyListeners();
      }
    }
  }

  void _resetWorkoutState() {
    _stepTracker.stop();
    _brakeLoad = null;
    if (_hasSession &&
        _workoutGroupRoomId != null &&
        _workoutGroupRoomId == _groupRideService.activeRoomId) {
      _lastGroupRoom = _groupRideService.activeRoomId;
      _lastGroupRevision = _groupRideService.membershipRevision;
      _groupHadWorkout = true;
      _groupLastDistance = _totalDistanceMeters;
      _groupLastSeconds = _activeDuration.inSeconds;
      _lastGroupPublish = null;
    }
    _isWorkoutActive = false;
    _workoutGroupRoomId = null;
    _isWorkoutPaused = false;
    _isAutoPaused = false;
    _activeClock
      ..stop()
      ..reset();
    _stopWorkoutTimer();
    _startLivePublishTimer();
    _recordedPath.clear();
    _totalDistanceMeters = 0;
    _workoutSpeedKmh = 0;
    _instantSpeedKmh = 0;
    _workoutCalories = 0;
    _averageSpeedKmh = 0;
    _workoutDuration = Duration.zero;
    _elapsedBeforeCurrentSegment = Duration.zero;
    _sessionLocalId = null;
    _lastDraftQueuedAt = null;
    _workoutStartTime = null;
    _sessionStartedAt = null;
    _sessionActivity = null;
    _sessionVehicle = null;
    _garageService.bindToSession(null);
    _lowSpeedSince = null;
    _lastAcceptedPointAt = null;
    _lastMotionPoint = null;
    _lastMotionTime = null;
    _lastSpeedSampleAt = null;
    _speedWindowTimes.clear();
    _speedWindowDistances.clear();
    _gradeAltitudes.clear();
    _gradeDistances.clear();
    _workoutGradePercent = 0;
    _workoutElevationGain = 0;
    _lastWorkoutAltitude = double.nan;
    _lastLivePublish = null;
    unawaited(_publishGroupProgress());
  }

  void clearWorkout() {
    if (_isSavingWorkout) return;
    _resetWorkoutState();
    unawaited(
      _draftStore.delete().catchError((Object error) {
        debugPrint('[Workout] checkpoint cleanup failed: $error');
      }),
    );
    unawaited(restartPositionStream());
    notifyListeners();
  }

  // Исправлено: теперь очищаем ВСЕ поля маршрута, чтобы освободить память
  void clearRoute() {
    VoiceGuidanceService.instance.resetTurns();
    unawaited(VoiceGuidanceService.instance.stop());
    _preserveTrack = false;
    _resetDeviation();
    routeNotice = null;
    _routeVia = [];
    _viaOffsetsMeters = [];
    _routeError = null;
    _routeGeneration++;
    _isLoadingRoute = false;
    _surfaceInfo = null; // Очищаем покрытие маршрута
    _elevationGainMeters = 0;
    _elevationLossMeters = 0;
    _finishPoint = null;
    _routePoints.clear(); // Используем clear(), чтобы освободить память
    _routeSegmentStarts = {};
    _routeSteps.clear(); // Очищаем шаги
    _routeDistanceKm = null;
    _routeDurationMin = null;
    _currentStepIndex = 0;
    _navigationProgressMeters = 0;
    _needsRouteReacquire = true;
    _lastNavigationFixAt = null;
    _lastNavigationFixPosition = null;
    _isNavigating = false;
    _isBookmarked = false;
    notifyListeners();
  }

  // Загрузка сохранённого маршрута
  void loadSavedRoute(SavedRoute route) {
    routeNotice = 'Сохранённый маршрут доступен без сети. Перестроение по дорогам требует интернет.';
    _preserveTrack = true;
    _resetDeviation();
    _routeVia = [];
    _viaOffsetsMeters = [];
    _routeError = null;
    _routeGeneration++;
    _isLoadingRoute = false;
    _finishPoint = route.finishPoint;
    _finishAddress = route.title.isNotEmpty
        ? route.title
        : 'Сохранённый маршрут';
    _routePoints = List.from(route.routePoints);
    _routeSegmentStarts = route.workoutDetails.segmentStarts
        .where((s) => s > 0 && s < _routePoints.length)
        .toSet();
    _routeSteps = route.navigationSteps.isNotEmpty
        ? List.of(route.navigationSteps)
        : TrailGuidance.segmentedSteps(route.routePoints, routeSegmentStarts);
    if (_routeSegmentStarts.isNotEmpty) {
      routeNotice =
          'В треке есть разрывы. Путь между отдельными участками неизвестен.';
    }
    _currentStepIndex = 0;
    _navigationProgressMeters = 0;
    // Парсинг строк «12.5 км»/«1 ч 23 мин» живёт в модели SavedRoute —
    // единственном месте с этой логикой.
    _routeDistanceKm = route.distanceKm;
    _routeDurationMin = route.durationMin;
    _selectedActivity = route.activityType;
    _isBookmarked = true;
    _isNavigating = false;
    _isFollowingUser = false;
    _autoRotateMap = false;

    // Для сохранённых маршрутов покрытие не считали — данных нет.
    _elevationGainMeters = 0;
    _elevationLossMeters = 0;
    _surfaceInfo = null;

    notifyListeners();
  }

  /// Показывает GPX, полученный из другого приложения, как маршрут на карте.
  bool loadImportedTrack(
    List<LatLng> points, {
    String title = 'GPX-трек',
    List<int> segmentStarts = const [],
  }) {
    if (points.length < 2 || _hasSession || _isSavingWorkout) return false;
    _routeGeneration++;
    _routePoints = List<LatLng>.of(points);
    _routeSegmentStarts = segmentStarts
        .where((s) => s > 0 && s < points.length)
        .toSet();
    _routeSteps = TrailGuidance.segmentedSteps(points, routeSegmentStarts);
    _preserveTrack = true;
    _resetDeviation();
    _routeVia = [];
    _viaOffsetsMeters = [];
    _routeError = null;
    routeNotice = _routeSegmentStarts.isEmpty ? 'Импортированный трек из GPX' : 'Импортированный GPX содержит разрывы. Между участками путь неизвестен.';
    _isLoadingRoute = false;
    _finishPoint = points.last;
    _finishAddress = title.isEmpty ? 'GPX-трек' : title;
    _routeDistanceKm =
        routeSegments.fold<double>(
          0,
          (sum, segment) => sum + TrailGuidance.length(segment),
        ) /
        1000;
    _routeDurationMin = _routeDistanceKm! / _selectedActivity.avgSpeedKmH * 60;
    _surfaceInfo = null;
    _elevationGainMeters = 0;
    _elevationLossMeters = 0;
    _currentStepIndex = 0;
    _navigationProgressMeters = 0;
    _needsRouteReacquire = true;
    _lastNavigationFixAt = null;
    _lastNavigationFixPosition = null;
    _isNavigating = false;
    _isBookmarked = false;
    _isFollowingUser = false;
    _autoRotateMap = false;
    notifyListeners();
    return true;
  }

  // --- Кэш последней геопозиции (мгновенный старт карты) ---
  // Ключ привязан к аккаунту, чтобы после смены пользователя новый аккаунт
  // не начинал карту с последней позиции предыдущего.
  static const String _cachedLatKey = 'last_known_lat';
  static const String _cachedLonKey = 'last_known_lon';
  String get _cachedLatPref => UserScope.keyFor(_cachedLatKey, _ownerId);
  String get _cachedLonPref => UserScope.keyFor(_cachedLonKey, _ownerId);
  bool _hasGpsFix = false;
  DateTime? _lastPositionCacheSave;

  Future<void> _loadCachedPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble(_cachedLatPref);
      final lon = prefs.getDouble(_cachedLonPref);
      if (!_disposed && !_hasGpsFix && lat != null && lon != null) {
        _currentLocation = LatLng(lat, lon);
        positionNotifier.value = _currentLocation;
      }
    } catch (_) {}
  }

  Future<void> _saveCachedPosition(LatLng position) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_cachedLatPref, position.latitude);
      await prefs.setDouble(_cachedLonPref, position.longitude);
    } catch (_) {
      // Кэш позиции — необязательная оптимизация.
    }
  }

  Future<void> initLocationTracking({bool requestPermission = true}) {
    if (requestPermission) _gpsRecoveryAttempts = 0;
    return _locationInitialization ??= _initLocationOnce(requestPermission)
        .whenComplete(() => _locationInitialization = null);
  }

  /// Resume is silent: permission prompts remain attached to an explicit action.
  Future<void> resumeLocationTracking() async {
    if (_disposed) return;
    if (!_locationReady ||
        gpsSignal.value.checkedAt(DateTime.now()).quality == GpsQuality.lost) {
      try {
        await initLocationTracking(requestPermission: false);
      } catch (error) {
        debugPrint('[GPS] resume deferred: $error');
      }
    }
  }

  Future<void> _initLocationOnce(bool requestPermission) async {
    if (_disposed) return;
    if (!_locationServiceWatchStarted && !kIsWeb) {
      _locationServiceWatchStarted = true;
      _locationServiceSubscription = Geolocator.getServiceStatusStream().listen(
        (status) {
          if (_disposed) return;
          if (status == ServiceStatus.enabled) {
            unawaited(resumeLocationTracking());
          } else {
            _locationReady = false;
            gpsSignal.value = const GpsSignal(unavailable: true);
          }
        },
        onError: (Object error) {
          debugPrint('[GPS] service status unavailable: $error');
        },
      );
    }
    _gpsWatchdog ??= Timer.periodic(const Duration(seconds: 2), (_) {
      if (_disposed) return;
      final checked = gpsSignal.value.checkedAt(DateTime.now());
      if (checked.stale != gpsSignal.value.stale) gpsSignal.value = checked;
      unawaited(
        _gpsFreshnessProbe.check(
          DateTime.now(),
          enabled:
              _locationReady &&
              _locationInitialization == null &&
              _hasCurrentOwner &&
              (WidgetsBinding.instance.lifecycleState == null ||
                  WidgetsBinding.instance.lifecycleState ==
                      AppLifecycleState.resumed),
        ),
      );
    });
    try {
      await _initializeLocationTracking(requestPermission: requestPermission);
    } catch (_) {
      _locationReady = false;
      if (!_disposed) gpsSignal.value = const GpsSignal(unavailable: true);
      rethrow;
    }
  }

  Future<void> _initializeLocationTracking({
    bool requestPermission = true,
  }) async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Службы геолокации отключены');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && requestPermission) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Разрешение на геолокацию отклонено');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('Геолокация заблокирована в настройках');
    }
    if (permission == LocationPermission.denied) {
      throw Exception('Нет разрешения на геолокацию');
    }

    // До первого GPS-фикса показываем последнюю известную позицию из кэша
    // (вместо дефолтного Берлина, откуда карта потом «прыгает»).
    await _loadCachedPosition();
    if (_disposed) return;
    if (!_hasGpsFix) {
      notifyListeners();
    }

    // Subscribe before the one-shot request: a timeout of that request must
    // not leave the app permanently without location updates.
    await _positionStreamSubscription?.cancel();
    if (_disposed) return;
    _positionStreamSubscription = _createPositionStreamSubscription(
      withForeground: _hasSession,
    );
    _locationReady = true;
    _startLivePublishTimer();
    final Position initialPosition;
    try {
      initialPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );
    } catch (error) {
      if (!_disposed && !_hasGpsFix) {
        gpsSignal.value = const GpsSignal(unavailable: true);
      }
      debugPrint(
        '[GPS] initial fix unavailable; stream remains active: $error',
      );
      return;
    }
    if (_disposed || !_hasCurrentOwner || !_validPosition(initialPosition))
      return;
    final latestFixAt = gpsSignal.value.updatedAt;
    if (latestFixAt != null &&
        initialPosition.timestamp.isBefore(latestFixAt)) {
      return;
    }
    _hasGpsFix = true;
    _updateGpsSignal(initialPosition);
    _currentLocation = LatLng(
      initialPosition.latitude,
      initialPosition.longitude,
    );
    positionNotifier.value = _currentLocation;
    _saveCachedPosition(_currentLocation);
    _currentHeading =
        initialPosition.heading.isFinite &&
            initialPosition.heading >= 0 &&
            initialPosition.speed.isFinite &&
            initialPosition.speed >= 1
        ? initialPosition.heading
        : double.nan;
    // Display heading comes only from CompassService. GPS is a fallback input.
    notifyListeners();

    unawaited(_publishLivePosition(_currentLocation));
  }

  /// Создаёт подписку на поток GPS с учётом платформы и настроек
  /// фонового режима (foreground service на Android).
  StreamSubscription<Position> _createPositionStreamSubscription({
    bool withForeground = false,
  }) {
    final inActiveRide = _hasSession || _isNavigating;
    final distanceFilter = inActiveRide ? 5 : 20;
    const accuracy = LocationAccuracy.high;
    LocationSettings locationSettings = LocationSettings(
      accuracy: accuracy,
      distanceFilter: distanceFilter,
    );

    if (!kIsWeb) {
      if (Platform.isAndroid) {
        locationSettings = AndroidSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilter,
          intervalDuration: Duration(seconds: inActiveRide ? 1 : 15),
          // Foreground service с уведомлением — только ВО ВРЕМЯ заезда
          // (поднимается в startWorkout, опускается на финише).
          foregroundNotificationConfig:
              withForeground && _backgroundTrackingEnabled
              ? ForegroundNotificationConfig(
                  notificationTitle: _isWorkoutPaused
                      ? 'PulsePath — пауза'
                      : 'PulsePath — заезд идёт',
                  notificationText: _isWorkoutPaused
                      ? 'Продолжите или завершите тренировку в приложении'
                      : 'Запись тренировки',
                  notificationChannelName: 'PulsePath',
                  notificationIcon: const AndroidResource(
                    name: 'ic_launcher',
                    defType: 'mipmap',
                  ),
                  setOngoing: true,
                  enableWakeLock: true,
                )
              : null,
        );
      } else if (Platform.isIOS) {
        // iOS: фоновый режим включается через UIBackgroundModes в
        // Info.plist; индикатор системный. Настройка применяется при
        // пересборке.
        locationSettings = AppleSettings(
          accuracy: accuracy,
          distanceFilter: distanceFilter,
          allowBackgroundLocationUpdates:
              _backgroundTrackingEnabled && _hasSession,
          showBackgroundLocationIndicator:
              _backgroundTrackingEnabled && _hasSession,
          pauseLocationUpdatesAutomatically: false,
        );
      }
    }

    final epoch = ++_gpsStreamEpoch;
    _streamStartedAt = _gpsNow();
    _streamFailed = false;
    _gpsRecoveryTimer?.cancel();
    _gpsRecoveryTimer = null;
    return Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (position) {
        if (epoch != _gpsStreamEpoch ||
            _disposed ||
            !_hasCurrentOwner ||
            !_validPosition(position))
          return;
        _lastStreamPosition = position;
        _lastStreamFixAt = _gpsNow();
        _gpsRecoveryAttempts = 0;
        if (_waitingForRecoveredStream || _streamFailed)
          UsageStatistics.instance.record(UsageEvent.gpsRecovered);
        _waitingForRecoveredStream = false;
        _streamFailed = false;
        _locationReady = true;
        _gpsRecoveryTimer?.cancel();
        _gpsRecoveryTimer = null;
        _onPositionUpdate(position);
      },
      onError: (Object error) {
        if (_disposed || epoch != _gpsStreamEpoch) return;
        _streamFailed = true;
        _breakTrackSegment = true;
        _locationReady = false;
        _scheduleGpsRecovery();
        UsageStatistics.instance.record(UsageEvent.gpsStreamFailed);
        debugPrint('[GPS] stream failed: $error');
        if (!_disposed) gpsSignal.value = const GpsSignal(unavailable: true);
      },
      onDone: () {
        if (_disposed || epoch != _gpsStreamEpoch) return;
        _streamFailed = true;
        _breakTrackSegment = true;
        _locationReady = false;
        _scheduleGpsRecovery();
        if (!_disposed) gpsSignal.value = const GpsSignal(unavailable: true);
      },
    );
  }

  /// Обработчик GPS-точки (бывшее тело листенера).
  @visibleForTesting
  void applyGpsSampleForTesting(Position position, {DateTime? observedAt}) =>
      _onPositionUpdate(position, observedAt: observedAt);

  @visibleForTesting
  void setRouteForTesting({
    required List<LatLng> points,
    required List<RouteStep> steps,
  }) {
    _routePoints = points;
    _routeSegmentStarts = {};
    _routeSteps = steps;
    _currentStepIndex = 0;
    _navigationProgressMeters = 0;
  }

  void _onPositionUpdate(Position position, {DateTime? observedAt}) {
    if (_disposed ||
        !_hasCurrentOwner ||
        !_validPosition(position, observedAt: observedAt) ||
        !position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude.abs() > 90 ||
        position.longitude.abs() > 180) {
      return;
    }
    if (position.speed.isFinite && position.speed * 3.6 > _autoResumeAboveKmh) {
      _stationaryProbe = null;
    }
    final newLatLng = LatLng(position.latitude, position.longitude);
    final stationary = _stationaryProbe;
    if (stationary != null &&
        GeoUtils.distanceBetween(
              LatLng(stationary.latitude, stationary.longitude),
              newLatLng,
            ) >
            5) {
      _stationaryProbe = null;
    }
    _hasGpsFix = true;
    _updateGpsSignal(position, observedAt: observedAt);
    final double newHeading =
        position.heading.isFinite &&
            position.heading >= 0 &&
            position.speed.isFinite &&
            position.speed >= 1
        ? position.heading
        : double.nan;

    // Обновляем местоположение и направление — через лёгкие каналы:
    // маркер и камера подписаны отдельно, полный rebuild не нужен.
    _currentLocation = newLatLng;
    _currentHeading = newHeading;
    positionNotifier.value = newLatLng;
    // Кэш позиции для следующего запуска — не чаще раза в 30 секунд
    // (каждую точку на диск не пишем).
    if (_lastPositionCacheSave == null ||
        DateTime.now().difference(_lastPositionCacheSave!) >=
            const Duration(seconds: 30)) {
      _lastPositionCacheSave = DateTime.now();
      _saveCachedPosition(newLatLng);
    }

    // Режим следования: камеру двигает подписка экрана на positionNotifier
    // (императивно, без setState всего экрана).

    final qualityFix =
        position.accuracy.isFinite &&
        position.accuracy >= 0 &&
        position.accuracy <= _maxAcceptableAccuracyMeters;
    // Reuse the existing GPS stream. No extra sensor or background timer.
    if (_isWorkoutActive &&
        !_isWorkoutPaused &&
        DateTime.now().difference(position.timestamp).inSeconds.abs() <= 5) {
      _brakeLoad?.add(
        at: position.timestamp,
        speedMps: position.speed,
        accuracyMeters: position.accuracy,
        speedAccuracyMps: position.speedAccuracy,
      );
    } else {
      _brakeLoad?.breakSegment();
    }
    if (qualityFix && _hasSession) {
      final previous = _lastMotionPoint;
      final previousTime = _lastMotionTime;
      if (previous != null && previousTime != null) {
        final dt =
            position.timestamp.difference(previousTime).inMilliseconds / 1000;
        if (dt > 0) {
          final speed =
              GeoUtils.distanceBetween(previous, newLatLng) / dt * 3.6;
          _instantSpeedKmh = speed <= _maxPlausibleKmh ? speed : 0;
        }
      }
      if (_lastMotionTime == null ||
          position.timestamp.isAfter(_lastMotionTime!)) {
        _lastMotionPoint = newLatLng;
        _lastMotionTime = position.timestamp;
      }
    }
    // Если активна тренировка — фильтруем мусорные точки (Этап B):
    // низкая точность GPS и «телепорты» не попадают в трек и статистику.
    if (_isWorkoutActive && !_isWorkoutPaused) {
      if (_lastAcceptedPointAt != null &&
          position.timestamp.difference(_lastAcceptedPointAt!) >
              const Duration(seconds: 30)) {
        _breakTrackSegment = true;
      }
      if (_acceptTrackPoint(newLatLng, position)) {
        final gap = _breakTrackSegment;
        if (gap) {
          _trackSegmentStarts.add(_recordedPath.length);
          _speedWindowTimes.clear();
          _speedWindowDistances.clear();
          _lastWorkoutAltitude = double.nan;
          _gradeAltitudes.clear();
          _gradeDistances.clear();
        }
        _recordedPath.add(newLatLng);
        if (!gap) {
          _updateWorkoutStats(
            newLatLng,
            position.altitude,
            position.timestamp,
            position.altitudeAccuracy,
          );
        }
        _breakTrackSegment = false;
        _queueDraft();
      }
    }

    // Умная автопауза: оцениваем скорость и на паузе (для авторезюма),
    // и в активном заезде (для постановки на паузу).
    if (qualityFix) _updateAutoPause(position);

    // Друзьям видно, где мы: публикуем позицию не чаще раза в 15 секунд.
    if ((_sharingForeground || (_hasSession && _backgroundTrackingEnabled)) &&
        qualityFix &&
        _shareLivePosition &&
        (_lastLivePublish == null ||
            DateTime.now().difference(_lastLivePublish!) >=
                const Duration(seconds: 5))) {
      _lastLivePublish = DateTime.now();
      unawaited(_publishLivePosition(newLatLng));
    }

    if (_isNavigating && _routePoints.isNotEmpty && qualityFix) {
      final navigationGap =
          (_lastNavigationFixAt != null &&
              position.timestamp.difference(_lastNavigationFixAt!) >
                  const Duration(seconds: 30)) ||
          (_lastNavigationFixPosition != null &&
              GeoUtils.distanceBetween(_lastNavigationFixPosition!, newLatLng) >
                  350);
      _lastNavigationFixAt = position.timestamp;
      _lastNavigationFixPosition = newLatLng;
      final deviation = routeSegments.fold<double>(
        double.infinity,
        (best, segment) =>
            math.min(best, GeoUtils.minDistanceToPolyline(newLatLng, segment)),
      );
      final progress = deviation <= math.max(50, position.accuracy * 2)
          ? _projectedRouteProgress(
              newLatLng,
              allowReacquire: _needsRouteReacquire || navigationGap,
            )
          : null;
      if (progress != null) {
        _needsRouteReacquire = false;
        if (progress > _navigationProgressMeters) {
          _navigationProgressMeters = progress;
        }
        var advanced = false;
        while (_currentStepIndex < _routeSteps.length - 1 &&
            _navigationProgressMeters >=
                _routeSteps[_currentStepIndex].routeOffsetMeters) {
          _currentStepIndex++;
          advanced = true;
        }
        if (advanced) notifyListeners();
        while (_viaOffsetsMeters.isNotEmpty &&
            _routeVia.isNotEmpty &&
            _navigationProgressMeters >= _viaOffsetsMeters.first) {
          _viaOffsetsMeters.removeAt(0);
          _routeVia.removeAt(0);
        }
      }
      _routeDeviation = deviation;
      final wasOff = _offRoute;
      if (deviation > math.max(50, position.accuracy * 2)) {
        _offRouteSamples++;
        if (_offRouteSamples >= 3) _offRoute = true;
      } else {
        _offRouteSamples = 0;
        if (deviation < 30) _offRoute = false;
      }
      if (wasOff != _offRoute) {
        if (_offRoute) {
          unawaited(PushService.instance.showRouteDeviation());
          if (!_isWorkoutPaused) VoiceGuidanceService.instance.deviation();
        }
        notifyListeners();
      }
      if (!_offRoute &&
          progress != null &&
          !_isWorkoutPaused &&
          _routeSteps.isNotEmpty &&
          (_sharingForeground || _backgroundTrackingEnabled)) {
        VoiceGuidanceService.instance.turn(
          _routeSteps[_currentStepIndex.clamp(0, _routeSteps.length - 1)],
          distanceToNextTurnMeters ?? double.infinity,
          position.speed.isFinite ? position.speed * 3.6 : 0,
        );
      }
      final now = DateTime.now();
      if (_offRoute &&
          !_preserveTrack &&
          !_isLoadingRoute &&
          (_lastRerouteTime == null ||
              now.difference(_lastRerouteTime!) >=
                  const Duration(seconds: 30))) {
        _lastRerouteTime = now;
        unawaited(
          buildRoute().catchError((Object error) {
            debugPrint('[Routing] reroute failed: $error');
          }),
        );
      }
    }
  }

  /// Projects a GPS fix onto the route and returns its distance from the start.
  /// Progress is later kept monotonic so noisy fixes cannot move instructions
  /// backwards after a turn.
  double? _projectedRouteProgress(LatLng point, {bool allowReacquire = false}) {
    if (_routePoints.length < 2) return null;
    var bestDistance = double.infinity;
    double? bestProgress;
    var offset = 0.0;
    final cosLat = math.cos(point.latitude * math.pi / 180);

    for (var i = 0; i < _routePoints.length - 1; i++) {
      if (_routeSegmentStarts.contains(i + 1)) continue;
      final a = _routePoints[i];
      final b = _routePoints[i + 1];
      final ax = (a.longitude - point.longitude) * cosLat;
      final ay = a.latitude - point.latitude;
      final bx = (b.longitude - point.longitude) * cosLat;
      final by = b.latitude - point.latitude;
      final dx = bx - ax;
      final dy = by - ay;
      final lengthSquared = dx * dx + dy * dy;
      final t = lengthSquared == 0
          ? 0.0
          : (-(ax * dx + ay * dy) / lengthSquared).clamp(0.0, 1.0);
      final projected = LatLng(
        a.latitude + t * (b.latitude - a.latitude),
        a.longitude + t * (b.longitude - a.longitude),
      );
      final distance = GeoUtils.distanceBetween(point, projected);
      final segmentLength = GeoUtils.distanceBetween(a, b);
      final candidateProgress = offset + segmentLength * t;
      if (candidateProgress >= _navigationProgressMeters - 15 &&
          (allowReacquire ||
              candidateProgress <= _navigationProgressMeters + 500) &&
          distance < bestDistance) {
        bestDistance = distance;
        bestProgress = candidateProgress;
      }
      offset += segmentLength;
    }
    return bestDistance <= 40 ? bestProgress : null;
  }

  Future<void> buildRoundTrip({
    required double distanceKm,
    required double bearing,
  }) async {
    final start = _currentLocation;
    setFinishPoint(
      start,
      'Круговой маршрут · примерно ${distanceKm.round()} км',
    );
    final generation = ++_routeGeneration;
    final activity = _selectedActivity;
    _isLoadingRoute = true;
    notifyListeners();
    try {
      final result = await _routingService.buildRoundTrip(
        start: start,
        distanceKm: distanceKm,
        bearing: bearing,
        activity: activity,
      );
      if (_disposed || generation != _routeGeneration) return;
      _routeVia = List.of(result.via);
      _finishAddress =
          'Круговой маршрут · ${result.route.distanceKm.toStringAsFixed(1)} км';
      if ((result.route.distanceKm - distanceKm).abs() / distanceKm > .15) {
        routeNotice =
            'На доступных дорогах получилось ${result.route.distanceKm.toStringAsFixed(1)} км вместо ${distanceKm.round()}. Попробуйте другое направление.';
      }
      _acceptRoutingResult(result.route, generation, activity);
    } catch (error) {
      if (!_disposed && generation == _routeGeneration) {
        UsageStatistics.instance.record(UsageEvent.routeBuildFailed);
        _routeError = 'Не удалось построить круг. $error';
      }
      rethrow;
    } finally {
      if (!_disposed && generation == _routeGeneration) {
        _isLoadingRoute = false;
        notifyListeners();
      }
    }
  }

  void _acceptRoutingResult(
    RoutingResult result,
    int generation,
    ActivityType activity,
  ) {
    UsageStatistics.instance.record(UsageEvent.routeBuilt);
    _preserveTrack = false;
    _resetDeviation();
    _routePoints = result.points;
    _routeSegmentStarts = {};
    _routeSteps = result.steps;
    _viaOffsetsMeters = List.of(result.viaOffsetsMeters);
    _currentStepIndex = 0;
    _navigationProgressMeters = 0;
    _routeDistanceKm = result.distanceKm;
    _routeDurationMin = result.durationMin;
    _elevationGainMeters = 0;
    _elevationLossMeters = 0;
    _surfaceInfo = null;
    unawaited(_loadSurfaceInfo(result.points, generation, activity));
  }

  Future<void> buildRoute() async {
    final finish = _finishPoint;
    if (finish == null || _disposed) return;
    final generation = ++_routeGeneration;
    final activity = _selectedActivity;
    _isLoadingRoute = true;
    _routeError = null;
    notifyListeners();
    try {
      final result = await _routingService.buildRoute(
        start: _currentLocation,
        end: finish,
        activity: activity,
        via: List.of(_routeVia),
      );
      if (_disposed || generation != _routeGeneration) return;
      UsageStatistics.instance.record(UsageEvent.routeBuilt);
      _preserveTrack = false;
      _resetDeviation();
      _routePoints = result.points;
      _routeSegmentStarts = {};
      _routeSteps = result.steps;
      _viaOffsetsMeters = List.of(result.viaOffsetsMeters);
      _currentStepIndex = 0;
      _navigationProgressMeters = 0;
      _routeDistanceKm = result.distanceKm;
      _routeDurationMin = result.durationMin;
      // OSRM has no altitude data. Never manufacture ascent from distance.
      _elevationGainMeters = 0;
      _elevationLossMeters = 0;
      _surfaceInfo = null;
      unawaited(_loadSurfaceInfo(result.points, generation, activity));
    } catch (error) {
      if (!_disposed && generation == _routeGeneration) {
        UsageStatistics.instance.record(UsageEvent.routeBuildFailed);
        _routeError = error is TimeoutException
            ? 'Сервис маршрутов не ответил. Проверьте интернет и повторите.'
            : 'Не удалось построить маршрут. $error';
      }
      rethrow;
    } finally {
      if (!_disposed && generation == _routeGeneration) {
        _isLoadingRoute = false;
        notifyListeners();
      }
    }
  }

  /// Replanning is transactional: a failed request leaves the previous
  /// geometry, instructions and stop list available on the map.
  Future<void> replanWithWaypoints(List<LatLng> via) async {
    if (!canEditWaypoints) {
      throw StateError('Остановите навигацию перед изменением остановок');
    }
    if (via.length > 8 ||
        via.any(
          (p) =>
              !p.latitude.isFinite ||
              !p.longitude.isFinite ||
              p.latitude.abs() > 90 ||
              p.longitude.abs() > 180,
        )) {
      throw ArgumentError('Можно добавить до 8 корректных остановок');
    }
    final finish = _finishPoint!;
    final activity = _selectedActivity;
    final generation = ++_routeGeneration;
    _isLoadingRoute = true;
    _routeError = null;
    notifyListeners();
    try {
      final result = await _routingService.buildRoute(
        start: _currentLocation,
        end: finish,
        activity: activity,
        via: List.of(via),
      );
      if (_disposed || generation != _routeGeneration) return;
      _routeVia = List.of(via);
      _isBookmarked = false;
      routeNotice = null;
      _acceptRoutingResult(result, generation, activity);
    } catch (_) {
      if (!_disposed && generation == _routeGeneration) {
        UsageStatistics.instance.record(UsageEvent.routeBuildFailed);
        _routeError =
            'Не удалось изменить остановки. Предыдущий маршрут сохранён.';
      }
      rethrow;
    } finally {
      if (!_disposed && generation == _routeGeneration) {
        _isLoadingRoute = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadSurfaceInfo(
    List<LatLng> points,
    int generation,
    ActivityType activity,
  ) async {
    try {
      final surface = await _overpassService.fetchRouteSurface(
        points,
        _routeDistanceKm ?? 0,
        activity,
      );
      if (!_disposed && generation == _routeGeneration) {
        _surfaceInfo = surface;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('[Surface] $error');
    }
  }

  void updateCurrentLocation(LatLng location, double? heading) {
    _currentLocation = location;
    positionNotifier.value = location;
    if (heading != null) {
      _currentHeading = heading;
      if (!_disposed) headingListenable.value = heading;
    }
    notifyListeners();
  }

  // Приватные методы для тренировки
  void _startWorkoutTimer() {
    _workoutTimer?.cancel();
    _workoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_isWorkoutActive && !_isWorkoutPaused) {
        _workoutDuration = _activeDuration;
        final plan = _intervalPlan;
        if (plan != null) {
          final phase = plan.phaseAt(_workoutDuration.inSeconds);
          final start = phase?.start ?? -1;
          if (_lastIntervalStart != start) {
            _lastIntervalStart = start;
            final title = phase == null
                ? 'Интервальный план выполнен'
                : '${phase.label}${phase.repeat == null ? '' : ' · ${phase.repeat}/${plan.repeats}'}';
            final body = phase == null
                ? 'Запись тренировки продолжается.'
                : '${workoutTime(Duration(seconds: phase.remaining(_workoutDuration.inSeconds)))} до следующего этапа';
            NotificationService.instance.pushSystem(title, subtitle: body);
            if (_sharingForeground || _backgroundTrackingEnabled) {
              VoiceGuidanceService.instance.reminder('$title. $body');
              unawaited(PushService.instance.showWorkoutCue(title, body));
            }
            _queueDraft(force: true);
          }
        }
        if (_waterReminder.consumeIfDue(_workoutDuration) &&
            (_sharingForeground || _backgroundTrackingEnabled)) {
          unawaited(PushService.instance.showWaterReminder());
          VoiceGuidanceService.instance.reminder(
            'Время сделать глоток воды. Если удобно, сделайте небольшой перерыв.',
          );
        }
        _captureWorkoutSample();
        _queueDraft();
        final hours = _workoutDuration.inMilliseconds / 3600000;
        _averageSpeedKmh = hours > 0 ? _totalDistanceMeters / 1000 / hours : 0;
        _updateCalories();
        final lastMotion = _lastMotionTime;
        if (lastMotion != null &&
            DateTime.now().difference(lastMotion) >
                const Duration(seconds: 5)) {
          _instantSpeedKmh = 0;
          // Missing GPS is not evidence that the rider has stopped.
        }
        // При полной остановке GPS может перестать присылать обновления
        // (distanceFilter), поэтому автопаузу дожимаем и по таймеру: если
        // низкая скорость уже держится 3 секунды — ставим на паузу.
        if (_autoPauseEnabled &&
            gpsSignal.value.quality == GpsQuality.good &&
            _lastMotionTime != null &&
            DateTime.now().difference(_lastMotionTime!) <
                const Duration(seconds: 5) &&
            _lowSpeedSince != null &&
            DateTime.now().difference(_lowSpeedSince!) >= _autoPauseDelay) {
          _autoPause();
          return;
        }
        // GPS молчит — значит стоим: скорость плавно падает до нуля,
        // а не «залипает» на последнем значении.
        _decaySpeedIfStalled();
        workoutTick.value++;
      }
    });
  }

  void _stopWorkoutTimer() {
    unawaited(VoiceGuidanceService.instance.stop());
    _workoutTimer?.cancel();
    _workoutTimer = null;
    unawaited(PushService.instance.clearWaterReminder());
  }

  void _updateWorkoutStats(
    LatLng newPoint, [
    double altitudeMeters = double.nan,
    DateTime? timestamp,
    double? altitudeAccuracy,
  ]) {
    if (_recordedPath.length < 2) return;

    final previousPoint = _recordedPath[_recordedPath.length - 2];
    final distanceDelta = GeoUtils.distanceBetween(previousPoint, newPoint);
    _totalDistanceMeters += distanceDelta;
    final completed = _distanceLaps.update(
      _totalDistanceMeters,
      _activeDuration,
    );
    if (completed.isNotEmpty) {
      final lap = completed.last;
      if (_sharingForeground || _backgroundTrackingEnabled) {
        VoiceGuidanceService.instance.reminder(
          'Пройдено ${(_totalDistanceMeters / 1000).toStringAsFixed(1)} километров. '
          'Отсечка ${lap.number}. Средняя скорость ${lap.speedKmh.toStringAsFixed(1)} километров в час.',
        );
      }
      NotificationService.instance.pushSystem(
        'Отсечка ${lap.number} · ${_autoLapMeters ~/ 1000} км',
        subtitle:
            '${workoutTime(Duration(seconds: lap.activeSeconds))} · ${lap.speedKmh.toStringAsFixed(1)} км/ч',
      );
      unawaited(
        PushService.instance.showWorkoutCue(
          'Отсечка ${lap.number} · ${_autoLapMeters ~/ 1000} км',
          '${workoutTime(Duration(seconds: lap.activeSeconds))} · ${lap.speedKmh.toStringAsFixed(1)} км/ч',
        ),
      );
      _queueDraft(force: true);
    }

    final now = timestamp ?? DateTime.now();
    _powerGradeGoodFixes =
        altitudeMeters.isFinite &&
            altitudeAccuracy != null &&
            altitudeAccuracy.isFinite &&
            altitudeAccuracy > 0 &&
            altitudeAccuracy <= 5
        ? _powerGradeGoodFixes + 1
        : 0;
    // Скорость на панели — по скользящему окну с реальными таймстампами:
    // (дистанция за окно) / (длительность окна). Не зависит от того, как
    // часто приходят точки, и не «прыгает» после пауз: точки старше окна
    // выпадают по времени.
    _pushSpeedSample(now, _totalDistanceMeters);

    // Уклон (Grade %) и набор высоты: работаем только когда GPS отдаёт
    // высоту (иначе NaN — уклон 0, набор не копим).
    if (altitudeMeters.isFinite) {
      _gradeAltitudes.add(altitudeMeters);
      _gradeDistances.add(_totalDistanceMeters);
      if (_gradeAltitudes.length > _gradeSampleWindow) {
        _gradeAltitudes.removeAt(0);
        _gradeDistances.removeAt(0);
      }
      _workoutGradePercent = _computeGradePercent();

      // Набор высоты: сумма положительных дельт с отсечкой GPS-шума.
      // Высота меняется плавно — базу обновляем на каждой значимой дельте.
      if (_lastWorkoutAltitude.isFinite) {
        final altitudeDelta = altitudeMeters - _lastWorkoutAltitude;
        if (altitudeDelta >= _elevationNoiseMeters) {
          _workoutElevationGain += altitudeDelta;
          _lastWorkoutAltitude = altitudeMeters;
        } else if (-altitudeDelta >= _elevationNoiseMeters) {
          // Спуск: высоту не прибавляем, но базу сдвигаем.
          _lastWorkoutAltitude = altitudeMeters;
        }
      } else {
        _lastWorkoutAltitude = altitudeMeters;
      }
    } else {
      _workoutGradePercent = 0.0;
    }

    // Обновляем среднюю скорость
    final totalHours = _workoutDuration.inSeconds / 3600.0;
    if (totalHours > 0) {
      _averageSpeedKmh = (_totalDistanceMeters / 1000.0) / totalHours;
    }

    // Калории — по типу активности (у каждого свой kcalPerHour);
    // на электроприводе мотор забирает примерно половину нагрузки.
    _updateCalories();

    workoutTick.value++;
  }

  /// Оценивает и применяет автопаузу по текущей скорости.
  ///
  /// Активный заезд: скорость ниже 1.5 км/ч 3 секунды подряд → [_autoPause].
  /// Автопауза: скорость выше 2.0 км/ч → [resumeWorkout]. Ручная пауза не
  /// прерывается автоматически.
  void _updateAutoPause(Position position) {
    if (!_autoPauseEnabled) return;
    if (!_isWorkoutActive && !_isWorkoutPaused) return;
    if (!_isWorkoutActive && !_isAutoPaused) return; // ручная пауза

    // position.speed (м/с) надёжнее там, где устройство его отдаёт; иначе
    // берём мгновенную скорость по дельтам GPS-точек.
    final double speedMs = position.speed;
    final double speedKmh = speedMs.isFinite && speedMs > 0.05
        ? speedMs * 3.6
        : _instantSpeedKmh;

    if (_isWorkoutActive && !_isWorkoutPaused) {
      if (speedKmh < _autoPauseBelowKmh) {
        _lowSpeedSince ??= DateTime.now();
      } else {
        _lowSpeedSince = null;
      }
    } else if (_isAutoPaused && speedKmh > _autoResumeAboveKmh) {
      debugPrint(
        '[Workout] авторезюм: скорость ${speedKmh.toStringAsFixed(1)} км/ч',
      );
      resumeWorkout();
    }
  }

  /// Добавляет точку в окно скорости и пересчитывает скорость.
  void _pushSpeedSample(DateTime time, double cumulativeDistanceMeters) {
    _speedWindowTimes.add(time);
    _speedWindowDistances.add(cumulativeDistanceMeters);
    _lastSpeedSampleAt = time;

    // Точки старше окна выпадают — паузы и простои не искажают скорость.
    while (_speedWindowTimes.length > 2 &&
        time.difference(_speedWindowTimes.first) > _speedWindow) {
      _speedWindowTimes.removeAt(0);
      _speedWindowDistances.removeAt(0);
    }

    final spanSeconds =
        _speedWindowTimes.last
            .difference(_speedWindowTimes.first)
            .inMilliseconds /
        1000.0;
    // Слишком короткое окно — скорости по одной точке не доверяем.
    if (spanSeconds < _speedWindowMinSpanSeconds) return;

    final windowDistance =
        _speedWindowDistances.last - _speedWindowDistances.first;
    _workoutSpeedKmh = (windowDistance / spanSeconds) * 3.6;
    if (_workoutSpeedKmh.isFinite && _workoutSpeedKmh > _maxWorkoutSpeed) {
      _maxWorkoutSpeed = _workoutSpeedKmh;
    }
  }

  /// Обнуляет скорость, если GPS давно не присылал точек (стоим на месте —
  /// distanceFilter не генерирует обновлений, и счётчик «залипал»).
  void _decaySpeedIfStalled() {
    final last = _lastSpeedSampleAt;
    if (last == null) return;
    if (DateTime.now().difference(last) > const Duration(seconds: 5)) {
      _workoutSpeedKmh = 0.0;
      _instantSpeedKmh = 0.0;
      _speedWindowTimes.clear();
      _speedWindowDistances.clear();
    }
  }

  double _computeGradePercent() {
    if (_gradeAltitudes.length < 2) return 0.0;
    final altitudeDelta = _gradeAltitudes.last - _gradeAltitudes.first;
    final distanceDelta = _gradeDistances.last - _gradeDistances.first;
    // Движения почти нет — уклон не считаем, показываем 0%.
    if (distanceDelta < _gradeMinDistanceMeters) return 0.0;
    final grade = (altitudeDelta / distanceDelta) * 100.0;
    return grade.clamp(-99.0, 99.0).toDouble();
  }

  @override
  void dispose() {
    gpsSignal.removeListener(_onTelemetryQualityChanged);
    _stepTracker.removeListener(_onWorkoutStepsChanged);
    _stepTracker.dispose();
    unawaited(VoiceGuidanceService.instance.stop());
    _queueDraft(force: true);
    unawaited(PushService.instance.clearWaterReminder());
    _disposed = true;
    _streamGeneration++;
    _routeGeneration++;
    _activeClock.stop();
    _livePublishTimer?.cancel();
    positionNotifier.dispose();
    _gpsWatchdog?.cancel();
    _gpsRecoveryTimer?.cancel();
    _gpsStreamEpoch++;
    _gpsFreshnessProbe.dispose();
    _friendStatusTimer?.cancel();
    _groupProgressTimer?.cancel();
    _groupRideService.removeListener(notifyListeners);
    _groupRideService.clearSession();
    gpsSignal.dispose();
    headingListenable.dispose();
    workoutTick.dispose();
    _friendService.unsubscribePositions();
    _positionStreamSubscription?.cancel();
    _locationServiceSubscription?.cancel();

    _workoutTimer?.cancel();
    super.dispose();
  }
}
