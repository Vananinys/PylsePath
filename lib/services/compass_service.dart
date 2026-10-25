import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';

/// Smoothed compass heading with circular filtering and GPS fallback.
/// 0° is a valid north bearing. Missing readings are null/nonfinite/negative,
/// never a particular direction. Mock rotation is explicitly debug-only.
class CompassService extends ChangeNotifier {
  CompassService({
    this.useCameraModeHeading = false,
    this.minAlpha = 0.2,
    this.maxAlpha = 0.65,
    this.fullSpeedDeltaDeg = 40.0,
    this.deadZoneDeg = 0.3,
    this.minPublishInterval = const Duration(milliseconds: 33),
    this.isDebugMockCompass = false,
    this.enableMockRotation = false,
    this.autoMockRotationOnZero = true,
    this.mockStepDeg = 2.0,
    this.mockInterval = const Duration(milliseconds: 100),
    this.watchdogTimeout = const Duration(seconds: 2),
  });

  /// Navigation follows the top edge of the phone. Camera mode follows
  /// the back-facing camera axis and is opt-in.
  final bool useCameraModeHeading;

  /// Коэффициент сглаживания при малых колебаниях (меньше = плавнее, но медленнее).
  final double minAlpha;

  /// Коэффициент при резком повороте (1.0 = без сглаживания).
  final double maxAlpha;

  /// Разница в градусах, при которой фильтр работает на [maxAlpha].
  final double fullSpeedDeltaDeg;

  /// Изменения меньше этого порога (в градусах) игнорируются.
  final double deadZoneDeg;

  /// Минимальный интервал между уведомлениями слушателей.
  final Duration minPublishInterval;

  /// Полностью ручной режим эмуляции: датчик не читается вообще, компас
  /// «крутится» с первого кадра. Удобно для отладки на эмуляторе.
  final bool isDebugMockCompass;

  /// Разрешить эмуляцию вращения. Сама по себе эмуляция не стартует —
  /// она включается либо через [isDebugMockCompass], либо автоматически,
  /// когда и компас, и GPS отдают 0.0 (см. [autoMockRotationOnZero]),
  /// либо вручную через [startMockRotation].
  final bool enableMockRotation;

  /// Автоматически подхватывать эмуляцию, если оба источника «залипли» на 0.0.
  final bool autoMockRotationOnZero;

  /// Шаг эмуляции за один тик (градусы).
  final double mockStepDeg;

  /// Период эмуляции.
  final Duration mockInterval;

  /// Сколько ждать первое валидное значение после [start], прежде чем
  /// считать датчик отсутствующим. Нужно для случая, когда поток событий
  /// формально есть, но не эмитит ни одного сэмпла (нет железа).
  final Duration watchdogTimeout;

  /// Сколько подряд «нулевых» сэмплов считаем отказом датчика.
  static const int _maxZeroCompassCount = 10;

  /// Значения по модулю меньше этого порога считаем «нет данных».
  /// Реальный азимут «ровно на север» приходит как 0.0001+ и не отбрасывается.
  static const double zeroEpsilon = 0.01;

  StreamSubscription<CompassEvent>? _subscription;
  Timer? _mockTimer;
  Timer? _watchdogTimer;
  double _filtered = 0.0; // внутреннее сглаженное значение
  double _published = 0.0; // то, что видят слушатели
  bool _hasReading = false;
  bool _isAvailable = true;
  DateTime _lastPublish = DateTime.fromMillisecondsSinceEpoch(0);

  /// Последний ВАЛИДНЫЙ (ненулевой) азимут. Fallback, чтобы 0.0 от залипшего
  /// датчика не сбрасывал ориентацию карты/маркера.
  double _lastValidHeading = 0.0;
  bool _hasValidHeading = false;

  // GPS fallback
  double _gpsBearing = 0.0;
  bool _hasGpsBearing = false;
  int _zeroCompassCount = 0;

  // Эмуляция вращения
  bool _isMockActive = false;
  double _mockAngle = 0.0;

  /// Первое значение после выхода из эмуляции применяем «как есть»,
  /// без плавного доезда от накрученного угла.
  bool _snapNextReading = false;

  /// Сглаженный азимут 0..360°.
  double get heading => _published;

  /// Последний валидный азимут (не сбрасывается в 0.0 при отказе датчиков).
  double get lastValidHeading => _lastValidHeading;

  /// Есть ли уже валидный (подтверждённый) азимут.
  bool get hasValidHeading => _hasValidHeading;

  /// Пришло ли хотя бы одно значение с датчика.
  bool get hasReading => _hasReading;

  /// false, если на устройстве нет магнитометра или поток дал ошибку.
  bool get isAvailable => _isAvailable;

  /// Активна ли сейчас эмуляция вращения (для отладки / индикации в UI).
  bool get isMockRotationActive => _isMockActive;

  /// GPS fallback; a negative or nonfinite bearing means missing data.
  DateTime? _lastSensorReading;

  void updateGpsBearing(double bearing) {
    if (!bearing.isFinite || bearing < 0) {
      _hasGpsBearing = false;
      return;
    }
    _hasGpsBearing = true;
    _gpsBearing = normalize(bearing);
    if (_lastSensorReading == null ||
        DateTime.now().difference(_lastSensorReading!) > watchdogTimeout) {
      _publishGpsFallback();
    }
  }

  /// Подписаться на датчик. Безопасно вызывать повторно.
  void start() {
    if (_subscription != null || _isMockActive) return;

    if (isDebugMockCompass) {
      debugPrint(
        '[CompassService] isDebugMockCompass = true -> sensor skipped, mock rotation only',
      );
      _startMockTimer();
      return;
    }

    final stream = FlutterCompass.events;
    if (stream == null) {
      // На устройстве нет компаса.
      _isAvailable = false;
      debugPrint('[CompassService] No compass stream available');
      _startMockIfAllowed('no compass stream');
      notifyListeners();
      return;
    }

    _isAvailable = true;
    debugPrint('[CompassService] Starting compass subscription');
    _subscription = stream.listen(
      _onEvent,
      onError: (error) {
        _isAvailable = false;
        debugPrint('[CompassService] Compass error: $error');
        _startMockIfAllowed('compass stream error');
        notifyListeners();
      },
    );
    _startWatchdog();
  }

  /// Страховка: если поток событий есть, но не эмитит ни одного сэмпла
  /// (нет физического датчика), через [watchdogTimeout] поднимаем эмуляцию.
  void _startWatchdog() {
    _watchdogTimer?.cancel();
    if (!enableMockRotation || !autoMockRotationOnZero) return;
    _watchdogTimer = Timer(watchdogTimeout, () {
      if (_hasValidHeading || _isMockActive) return;
      debugPrint(
        '[CompassService] Watchdog: no valid heading within ${watchdogTimeout.inMilliseconds}ms -> enabling mock rotation',
      );
      _startMockTimer();
    });
  }

  /// Отписаться (например, когда приложение свёрнуто — экономит батарею).
  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _mockTimer?.cancel();
    _mockTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _isMockActive = false;
    // После возобновления первое значение применится сразу, без «плавного
    // доезда» со старого азимута.
    _hasReading = false;
    _snapNextReading = true;
    debugPrint('[CompassService] Stopped');
  }

  void _onEvent(CompassEvent event) {
    final camera = event.headingForCameraMode;
    final raw = useCameraModeHeading && camera != null && camera.isFinite
        ? camera
        : event.heading;
    // null приходит, когда датчик не откалиброван или недоступен.
    // Android's SensorManager returns signed azimuths (-180..180).
    // Negative angles are real western headings, not missing readings.
    if (raw == null ||
        !raw.isFinite ||
        (defaultTargetPlatform == TargetPlatform.iOS && raw < 0)) {
      debugPrint(
        '[CompassService] Raw compass value is invalid. heading=${event.heading}, headingForCameraMode=${event.headingForCameraMode}',
      );
      _zeroCompassCount++;
      if (_hasGpsBearing &&
          (_lastSensorReading == null ||
              DateTime.now().difference(_lastSensorReading!) >
                  watchdogTimeout)) {
        _publishGpsFallback();
      } else {
        _onSensorStalled();
      }
      return;
    }

    _lastSensorReading = DateTime.now();
    _zeroCompassCount = 0;
    final effectiveRaw = raw;

    // Пришли реальные данные — эмуляция больше не нужна.
    _stopMockTimer();

    final target = normalize(effectiveRaw);
    final now = DateTime.now();

    debugPrint(
      '[CompassService] Raw heading=$raw, GPS bearing=$_gpsBearing, effective=$effectiveRaw, target=$target, hasReading=$_hasReading',
    );

    // Первое значение (или первое после эмуляции) принимаем как есть.
    if (!_hasReading || _snapNextReading) {
      _snapNextReading = false;
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      _filtered = target;
      _published = target;
      _hasReading = true;
      _hasValidHeading = true;
      _lastValidHeading = target;
      _lastPublish = now;
      debugPrint('[CompassService] First reading: $_published');
      notifyListeners();
      return;
    }

    // 3) Круговой адаптивный low-pass фильтр.
    final delta = shortestDelta(_filtered, target);
    final t = (delta.abs() / fullSpeedDeltaDeg).clamp(0.0, 1.0);
    final alpha = minAlpha + (maxAlpha - minAlpha) * t;
    _filtered = normalize(_filtered + delta * alpha);

    // 4) Троттлинг.
    if (now.difference(_lastPublish) < minPublishInterval) return;

    // 5) Мёртвая зона.
    if (shortestDelta(_published, _filtered).abs() < deadZoneDeg) return;

    _published = _filtered;
    _lastValidHeading = _published;
    _hasValidHeading = true;
    _lastPublish = now;
    debugPrint('[CompassService] Published heading=$_published');
    notifyListeners();
  }

  @visibleForTesting
  void applyCompassEventForTesting(CompassEvent event) => _onEvent(event);

  void _publishGpsFallback() {
    _stopMockTimer();
    _filtered = normalize(_gpsBearing);
    _published = _filtered;
    _lastValidHeading = _filtered;
    _hasReading = true;
    _hasValidHeading = true;
    notifyListeners();
  }

  /// Оба источника не дали данных: держим последний валидный угол и, если
  /// разрешено, поднимаем эмуляцию вращения, чтобы UI было видно живым.
  void _onSensorStalled() {
    if (_isMockActive) return; // эмуляция сама двигает _published

    if (enableMockRotation &&
        autoMockRotationOnZero &&
        _zeroCompassCount >= _maxZeroCompassCount) {
      debugPrint(
        '[CompassService] Sensors stuck at 0.0 -> enabling mock rotation fallback',
      );
      _startMockTimer();
      return;
    }

    if (_hasValidHeading) {
      // Ключевое: НЕ публикуем 0.0, восстанавливаем последний валидный угол.
      final bool changed = _published != _lastValidHeading;
      _filtered = _lastValidHeading;
      _published = _lastValidHeading;
      _hasReading = true;
      if (changed) notifyListeners();
    }
    // notifyListeners() не нужен, если значение не изменилось.
  }

  /// Публичный ручной запуск эмуляции (например, кнопкой в debug-меню).
  void startMockRotation() {
    if (!enableMockRotation) {
      debugPrint(
        '[CompassService] startMockRotation() ignored: enableMockRotation = false',
      );
      return;
    }
    _startMockTimer();
  }

  /// Публичная остановка эмуляции (дальше ждём реальные данные датчика).
  // Исправлено: теперь метод очищает таймеры и сбрасывает состояние
  void stopMockRotation() {
    if (!_isMockActive) return;
    _stopMockTimer();
    // Сбрасываем эмуляцию
    _isMockActive = false;
    notifyListeners();
  }

  /// Ручной запуск/остановка эмуляции вращения (для UI/тестов).
  void toggleMockRotation() {
    if (_isMockActive) {
      stopMockRotation();
    } else {
      startMockRotation();
    }
  }

  /// Запуск эмуляции вращения: +[mockStepDeg]° каждые [mockInterval].
  void _startMockTimer() {
    if (_isMockActive) return;
    _isMockActive = true;
    _isAvailable = true;
    _hasReading = true;
    // Стартуем с последнего валидного угла, чтобы не было скачка на экране.
    _mockAngle = _hasValidHeading ? _lastValidHeading : 0.0;
    _published = _mockAngle;
    _filtered = _mockAngle;
    _lastPublish = DateTime.now();
    debugPrint(
      '[CompassService] Mock rotation started: +$mockStepDeg° every ${mockInterval.inMilliseconds}ms from ${_mockAngle.toStringAsFixed(1)}°',
    );

    _mockTimer?.cancel();
    _mockTimer = Timer.periodic(mockInterval, (_) {
      _mockAngle = normalize(_mockAngle + mockStepDeg);
      _published = _mockAngle;
      _filtered = _mockAngle;
      _lastValidHeading = _mockAngle;
      _hasValidHeading = true;
      _lastPublish = DateTime.now();
      debugPrint(
        '[CompassService] Mock heading=${_mockAngle.toStringAsFixed(1)}°',
      );
      notifyListeners();
    });

    notifyListeners();
  }

  void _stopMockTimer() {
    if (!_isMockActive) return;
    _isMockActive = false;
    _mockTimer?.cancel();
    _mockTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _snapNextReading = true;
    _zeroCompassCount = 0;
    debugPrint(
      '[CompassService] Mock rotation stopped -> waiting for real sensor data',
    );
  }

  /// Включает эмуляцию, если она разрешена (нет датчика / ошибка потока).
  void _startMockIfAllowed(String reason) {
    if (!enableMockRotation || !autoMockRotationOnZero) return;
    debugPrint('[CompassService] Enabling mock rotation ($reason)');
    _startMockTimer();
  }

  /// Приводит угол к диапазону [0, 360). В Dart `%` для положительного
  /// делителя всегда неотрицателен, поэтому -10 % 360 == 350.
  static double normalize(double degrees) => degrees % 360.0;

  /// Кратчайшая разница углов (to - from) в диапазоне (-180, 180].
  static double shortestDelta(double from, double to) {
    var d = (to - from) % 360.0;
    if (d > 180.0) d -= 360.0;
    return d;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _mockTimer?.cancel();
    _mockTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _isMockActive = false;
    super.dispose();
  }
}
