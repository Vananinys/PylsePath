import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/activity_type.dart';

/// Маркер райдера: синий круг, стрелка направления и конус обзора.
///
/// [screenAngleDeg] — угол стрелки относительно ВЕРХА ЭКРАНА в градусах,
/// по часовой стрелке: 0° = строго вверх, 90° = вправо, ±180° = вниз.
///
/// Почему именно экранный (относительный) угол, а не азимут компаса:
///  * flutter_map крутит весь слой карты на `camera.rotation`
///    (`MobileLayerTransformer` -> `Transform.rotate(+rotationRad)`);
///  * `Marker(rotate: true)` заставляет flutter_map скомпенсировать этот
///    поворот (`MarkerLayer` -> `Transform.rotate(angle: -map.rotationRad)`),
///    поэтому переданный сюда угол — уже чистый экранный;
///  * `main.dart` считает его как `heading + camera.rotation`:
///    - `CameraLockMode.follow` («Север вверху»): `camera.rotation == 0`,
///      значит угол равен азимуту телефона;
///    - `CameraLockMode.followAndHeading` («По направлению»): карта повёрнута
///      на `-heading`, поэтому угол равен 0° — стрелка строго вверх,
///      а под ней вращается карта.
class RiderMarker extends StatefulWidget {
  const RiderMarker({
    super.key,
    required this.screenAngleDeg,
    this.size = 96,
    this.animationDuration = const Duration(milliseconds: 120),
    this.activity,
  });

  final double screenAngleDeg;
  final double size;

  /// Тип активности (велосипед, бег, пешком) — для смены цвета и иконки
  final ActivityType? activity;

  /// Длительность доводки между двумя соседними значениями компаса.
  final Duration animationDuration;

  /// Нормализация в диапазон (-180, 180] градусов + защита от «мусора».
  ///
  /// Именно знаковый диапазон (а не [0, 360)) убирает разрыв на юге:
  /// 181° -> -179°, 359° -> -1° — то есть граница «перехода через 180°»
  /// перестаёт быть особой точкой.
  static double normalizeSigned(double deg) {
    if (!deg.isFinite) return 0.0;
    final d = deg % 360.0; // в Dart всегда [0, 360)
    return d > 180.0 ? d - 360.0 : d;
  }

  /// Кратчайшая разница углов `to - from` в диапазоне (-180, 180].
  /// Переход 359° -> 1° даёт +2°, а не -358°.
  static double shortestDelta(double from, double to) {
    final d = (to - from) % 360.0;
    return d > 180.0 ? d - 360.0 : d;
  }

  @override
  State<RiderMarker> createState() => _RiderMarkerState();
}

class _RiderMarkerState extends State<RiderMarker> {
  /// Близость к развороту на 180°, при которой направление поворота считаем
  /// неопределённым (см. гистерезис в [didUpdateWidget]).
  static const double _halfTurnEpsilonDeg = 179.5;

  /// Непрерывный («развёрнутый») угол: 179 -> 181 -> 183, а не 179 -> -179.
  /// Именно он уходит в анимацию, поэтому на переходе через 180°/360° маркер
  /// продолжает движение в ту же сторону, а не «залипает» и не крутится назад.
  late double _unwrappedDeg;

  /// Последний целевой угол, нормализованный в (-180, 180].
  /// Дельту считаем от него (а не от растущего `_unwrappedDeg`), чтобы
  /// арифметика оставалась в пределах одного оборота.
  late double _targetDeg;

  /// Сторона последнего поворота. Нужна только для вырожденного случая
  /// «ровно 180°»: `shortestDelta` всегда отдаёт +180, и без гистерезиса
  /// маркер дрожал бы на развороте, выбирая сторону каждый кадр.
  double _lastDirection = 1.0;

  @override
  void initState() {
    super.initState();
    _targetDeg = RiderMarker.normalizeSigned(widget.screenAngleDeg);
    _unwrappedDeg = _targetDeg;
  }

  @override
  void didUpdateWidget(covariant RiderMarker oldWidget) {
    super.didUpdateWidget(oldWidget);

    final target = RiderMarker.normalizeSigned(widget.screenAngleDeg);
    // Угол не изменился — не трогаем текущую анимацию.
    if (target == _targetDeg) return;

    var delta = RiderMarker.shortestDelta(_targetDeg, target);
    // Разворот «через юг»: ровно ±180° — вырожденный случай, где направление
    // поворота не определено. `shortestDelta` всегда отдаёт +180, поэтому без
    // гистерезиса маркер на этой границе дёргается между +180 и -180 и
    // выглядит замершим. Держим сторону предыдущего движения.
    if (delta.abs() >= _halfTurnEpsilonDeg) delta = 180.0 * _lastDirection;

    if (delta != 0) _lastDirection = delta > 0 ? 1.0 : -1.0;
    _targetDeg = target;
    _unwrappedDeg += delta;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: TweenAnimationBuilder<double>(
        // begin не задан: при первой сборке анимации нет, дальше значение
        // плавно «доезжает» до нового end. end — непрерывный угол, поэтому
        // анимация всегда идёт по короткой дуге в нужную сторону.
        tween: Tween<double>(end: _unwrappedDeg),
        duration: widget.animationDuration,
        curve: Curves.linear,
        builder: (context, deg, child) {
          // Градусы -> радианы: Transform.rotate работает в радианах,
          // и в экранных координатах положительный угол = по часовой стрелке.
          final double radians = (deg.isFinite ? deg : 0.0) * (math.pi / 180.0);
          return Transform.rotate(angle: radians, child: child);
        },
        // child не пересоздаётся на каждый кадр анимации.
        child: const CustomPaint(painter: _RiderPainter()),
      ),
    );
  }
}

class _RiderPainter extends CustomPainter {
  final ActivityType? activity;
  const _RiderPainter({this.activity});

  /// Цвет маркера по активности:
  /// - велосипед — синий, бег — оранжевый, пешком — зелёный
  static const Color _blue = Color(0xFF1E88E5);
  static const Color _orange = Color(0xFFFF7043);
  static const Color _green = Color(0xFF4CAF50);

  /// Цвет по типу активности
  Color get _activityColor {
    switch (activity) {
      case ActivityType.cycling:
      case ActivityType.mountainBiking:
      case ActivityType.roadCycling:
      case ActivityType.gravelRiding:
      case ActivityType.bikepacking:
      case ActivityType.driving:
        return _blue;
      case ActivityType.running:
      case ActivityType.trailRunning:
        return _orange;
      case ActivityType.hiking:
      case ActivityType.briskWalking:
      case ActivityType.nordicWalking:
      case ActivityType.trekking:
        return _green;
      case null:
        return _blue;
    }
  }

  static const double _fovDeg = 65; // ширина конуса обзора

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = size.width / 2;

    // 1. Конус обзора: сектор от центра вверх с градиентом к краю.
    const fov = _fovDeg * math.pi / 180.0;
    final conePath = Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(
        Rect.fromCircle(center: c, radius: radius),
        -math.pi / 2 - fov / 2, // 0° = вправо, поэтому «вверх» = -90°
        fov,
        false,
      )
      ..close();
    final conePaint = Paint()
      ..shader = RadialGradient(
        colors: [_blue.withValues(alpha: 0.55), _blue.withValues(alpha: 0.0)],
      ).createShader(Rect.fromCircle(center: c, radius: radius));
    canvas.drawPath(conePath, conePaint);

    // 2. Стрелка направления над точкой (белая обводка + синяя заливка).
    final arrow = Path()
      ..moveTo(c.dx, c.dy - 22)
      ..lineTo(c.dx + 7, c.dy - 8)
      ..lineTo(c.dx - 7, c.dy - 8)
      ..close();
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );
    // Исправлено: теперь цвет маркера меняется по активности
    canvas.drawPath(arrow, Paint()..color = _activityColor);

    // 3. Белый круг с тенью + синяя центральная точка.
    canvas.drawShadow(
      Path()..addOval(Rect.fromCircle(center: c, radius: 11)),
      Colors.black,
      3,
      true,
    );
    canvas.drawCircle(c, 11, Paint()..color = Colors.white);
    // Исправлено: теперь цвет маркера меняется по активности
    canvas.drawCircle(c, 7.5, Paint()..color = _activityColor);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
