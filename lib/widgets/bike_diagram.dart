import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/bike_equipment.dart';
import '../models/bike_setup.dart';

/// All rendering and hit testing share these paths, in a 1000 × 680 board.
class BikeDiagramGeometry {
  BikeDiagramGeometry(
    this.kind, {
    this.setup = const BikeSetup(),
    this.drivetrain,
    this.parts = const [],
  });
  final String kind;
  final BikeSetup setup;
  final BikeDrivetrain? drivetrain;
  final List<BikePart> parts;
  bool has(String id) =>
      setup.accessories.contains(id) || parts.any((p) => p.template.id == id);
  bool get geared =>
      setup.transmission == 'geared' ||
      (setup.transmission == 'auto' &&
          drivetrain?.gearsConfigured == true &&
          drivetrain!.speeds > 1);
  bool get rearDerailleur => geared && rearCount > 1;
  int get rearCount => geared
      ? (drivetrain?.gearsConfigured == true
            ? drivetrain!.rear.length.clamp(1, 14)
            : 8)
      : 1;
  int get frontCount => geared && drivetrain?.gearsConfigured == true
      ? drivetrain!.front.length.clamp(1, 3)
      : 1;
  bool get suspension =>
      setup.fork == 'suspension' || (setup.fork == 'auto' && !dropBar);
  double get cassetteRadius => geared
      ? (drivetrain?.gearsConfigured == true
            ? ((drivetrain!.rear.firstOrNull ?? 28) * .90).clamp(12.0, 50.0)
            : 34)
      : drivetrain?.gearsConfigured == true && drivetrain!.rear.length == 1
      ? (drivetrain!.rear.single * .90).clamp(10.0, 50.0)
      : 14;
  double get ringRadius => drivetrain?.gearsConfigured == true
      ? ((drivetrain!.front.lastOrNull ?? 42) * .90).clamp(20.0, 55.0)
      : kind == 'road'
      ? 43
      : 37;
  bool get dropBar => kind == 'road' || kind == 'gravel';
  // All joints share wheelbase, BB drop, seat and steering axes.
  Offset get rear => const Offset(210, 448);
  Offset get front => Offset(switch (kind) {
    'road' => 735,
    'gravel' => 755,
    'enduro' => 795,
    _ => 770,
  }, 448);
  Offset get crank => Offset(400, dropBar ? 478 : 460);
  Offset seatAxis(double y) =>
      Offset(crank.dx - (crank.dy - y) * (kind == 'enduro' ? .24 : .30), y);
  Offset get seat => seatAxis(switch (kind) {
    'road' => 250,
    'gravel' => 275,
    'enduro' => 325,
    _ => 300,
  });
  Offset get saddle => seatAxis(kind == 'enduro' ? 200 : 180);
  Offset get head => switch (kind) {
    'road' => const Offset(663, 251),
    'gravel' => const Offset(666, 237),
    'enduro' => const Offset(664, 220),
    _ => const Offset(658, 232),
  };
  double get forkOffset => dropBar ? 18 : 22;
  Offset get steeringAxis =>
      Offset((front.dx - head.dx - forkOffset) / (front.dy - head.dy), 1);
  Offset get headBottom => head + steeringAxis * 49;
  Offset get steeringTop => head - (headBottom - head) * .60;
  Offset get bar => steeringTop + Offset(dropBar ? 43 : 31, -8);
  Offset get crown => headBottom + (headBottom - head) * .22;
  Offset get forkSeal => crown + steeringAxis * ((front.dy - crown.dy) * .45);
  Offset get forkDropout => front - Offset(forkOffset, 12);
  Offset get rearPivot => crank + const Offset(10, -44);
  Offset get rocker => seat + const Offset(20, 12);
  Offset get shockEnd => Offset.lerp(headBottom, crank, .49)!;
  Offset get upperPulley => rear + Offset(10, cassetteRadius + 20);
  Offset get lowerPulley => upperPulley + const Offset(-8, 35);
  Offset get pedal => crank + const Offset(65, 12);
  Offset get backPedal => crank - const Offset(65, 12);
  bool discAt(Offset center) =>
      BikeSetup.isDisc(setup.brakeType(center == front));
  double rotorRadius(Offset center) => setup.rotorMm(center == front) * .22;
  bool visible(String id) => switch (id) {
    'cassette' => geared && rearCount > 1,
    'rear_derailleur' => rearDerailleur,
    'front_derailleur' => geared && frontCount > 1,
    'shifters' => geared,
    'shock' => kind == 'enduro',
    'dropper' => has('dropper'),
    'front_rotor' => discAt(front),
    'rear_rotor' => discAt(rear),
    'front_pads' => setup.brakeType(true) != 'none',
    'rear_pads' =>
      setup.brakeType(false) != 'none' && setup.brakeType(false) != 'coaster',
    'front_brake' => setup.brakeType(true) != 'none',
    'rear_brake' => setup.brakeType(false) != 'none',
    'brakes' =>
      setup.brakeType(true) != 'none' || setup.brakeType(false) != 'none',
    'lights' || 'rack' || 'mudguards' || 'bottle_cage' => has(id),
    'custom' => false,
    _ => true,
  };
  double get tyreWidth => kind == 'road'
      ? 11
      : kind == 'gravel'
      ? 17
      : 25;
  Path lines(List<Offset> points, {bool close = false}) {
    final p = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      p.lineTo(point.dx, point.dy);
    }
    if (close) p.close();
    return p;
  }

  Path ring(Offset center, double r) =>
      Path()..addOval(Rect.fromCircle(center: center, radius: r));
  Path path(String id) {
    switch (id) {
      case 'front_tyre':
        return ring(front, 154);
      case 'rear_tyre':
        return ring(rear, 154);
      case 'front_tube':
        return ring(front, 146);
      case 'rear_tube':
        return ring(rear, 146);
      case 'front_wheel':
        return ring(front, 135);
      case 'rear_wheel':
        return ring(rear, 135);
      case 'frame':
        return Path()
          ..addPath(lines([seat, head, headBottom, crank, seat]), Offset.zero)
          ..addPath(
            kind == 'enduro'
                ? lines([rear, rocker, rearPivot, rear])
                : lines([seat, rear, crank]),
            Offset.zero,
          );
      case 'fork':
        return lines([headBottom, crown, forkSeal, forkDropout, front]);
      case 'chain':
        return chainPath();
      case 'cassette':
        return ring(rear, cassetteRadius);
      case 'chainrings':
        return ring(crank, ringRadius);
      case 'bottom_bracket':
        return ring(crank, 12);
      case 'cranks':
        return lines([backPedal, crank, pedal]);
      case 'pedals':
        return Path()
          ..addPath(
            lines([pedal + const Offset(-17, 0), pedal + const Offset(17, 0)]),
            Offset.zero,
          )
          ..addPath(
            lines([
              backPedal + const Offset(-17, 0),
              backPedal + const Offset(17, 0),
            ]),
            Offset.zero,
          );
      case 'rear_derailleur':
        return lines([
          rear,
          rear + const Offset(-12, 18),
          upperPulley,
          lowerPulley,
        ]);
      case 'front_derailleur':
        return lines([
          crank + const Offset(-20, -40),
          crank + const Offset(-35, -70),
        ]);
      case 'front_brake':
        return brakePath(front);
      case 'rear_brake':
        return brakePath(rear);
      case 'front_rotor':
        return ring(front, rotorRadius(front));
      case 'rear_rotor':
        return ring(rear, rotorRadius(rear));
      case 'front_hub':
        return ring(front, 11);
      case 'rear_hub':
        return ring(rear, 11);
      case 'front_pads':
        return caliperPath(front);
      case 'rear_pads':
        return caliperPath(rear);
      case 'brakes':
        return Path()
          ..addPath(brakePath(front), Offset.zero)
          ..addPath(brakePath(rear), Offset.zero);
      case 'shock':
        return lines([rocker, shockEnd]);
      case 'seatpost':
      case 'dropper':
        return lines([seat, saddle]);
      case 'saddle':
        return lines([
          saddle + const Offset(-43, -9),
          saddle + const Offset(45, -9),
        ]);
      case 'headset':
        return lines([steeringTop, head]);
      case 'stem':
        return lines([steeringTop, bar]);
      case 'handlebar':
      case 'grips':
        if (dropBar) {
          return Path()
            ..moveTo(bar.dx, bar.dy)
            ..cubicTo(
              bar.dx + 67,
              bar.dy - 8,
              bar.dx + 77,
              bar.dy + 68,
              bar.dx + 35,
              bar.dy + 68,
            )
            ..lineTo(bar.dx + 15, bar.dy + 68);
        }
        return lines([
          bar + const Offset(-13, 4),
          bar,
          bar + const Offset(60, -12),
        ]);
      case 'battery':
        return lines([
          Offset.lerp(headBottom, crank, .25)!,
          Offset.lerp(headBottom, crank, .80)!,
        ]);
      case 'lights':
        return Path()
          ..addPath(
            lines([bar, bar + const Offset(8, 9), bar + const Offset(30, 9)]),
            Offset.zero,
          )
          ..addPath(
            lines([
              seatAxis(seat.dy - 30),
              seatAxis(seat.dy - 30) + const Offset(-10, 0),
            ]),
            Offset.zero,
          );
      case 'rack':
        return lines([
          rear + const Offset(-80, -185),
          rear + const Offset(85, -185),
          rear + const Offset(30, -20),
        ]);
      case 'shifters':
        return lines([
          bar + Offset(dropBar ? 40 : 30, -2),
          bar + Offset(dropBar ? 47 : 35, 12),
          bar + Offset(dropBar ? 52 : 46, 29),
        ]);
      case 'bottle_cage':
        final base = Offset.lerp(crank, headBottom, .30)!;
        final tip = Offset.lerp(crank, headBottom, .63)!;
        return lines([
          base + const Offset(-14, -15),
          tip + const Offset(-14, -15),
          tip + const Offset(-30, -35),
          base + const Offset(-30, -35),
        ], close: true);
      case 'mudguards':
        return Path()
          ..addArc(
            Rect.fromCircle(center: rear, radius: 170),
            math.pi * 1.05,
            math.pi * .9,
          )
          ..addArc(
            Rect.fromCircle(center: front, radius: 170),
            math.pi * 1.08,
            math.pi * .8,
          );
      default:
        return ring(const Offset(520, 350), 20);
    }
  }

  Path chainPath() {
    final axis = crank - rear;
    final angle =
        math.atan2(axis.dy, axis.dx) -
        math.acos(
          ((cassetteRadius - ringRadius) / axis.distance).clamp(-1.0, 1.0),
        );
    Offset radial(double a, double r) =>
        Offset(math.cos(a) * r, math.sin(a) * r);
    final topRear = rear + radial(angle, cassetteRadius);
    final topRing = crank + radial(angle, ringRadius);
    final p = Path()
      ..moveTo(topRear.dx, topRear.dy)
      ..lineTo(topRing.dx, topRing.dy);
    final lowerAngle =
        math.atan2(axis.dy, axis.dx) +
        math.acos(
          ((cassetteRadius - ringRadius) / axis.distance).clamp(-1.0, 1.0),
        );
    p.arcTo(
      Rect.fromCircle(center: crank, radius: ringRadius),
      angle,
      lowerAngle - angle,
      false,
    );
    if (rearDerailleur) {
      p.lineTo(lowerPulley.dx + 8, lowerPulley.dy + 4);
      p.quadraticBezierTo(
        lowerPulley.dx + 6,
        lowerPulley.dy + 15,
        lowerPulley.dx - 8,
        lowerPulley.dy + 6,
      );
      p.lineTo(upperPulley.dx - 9, upperPulley.dy);
      p.quadraticBezierTo(
        upperPulley.dx - 10,
        upperPulley.dy - 7,
        upperPulley.dx - 4,
        upperPulley.dy - 9,
      );
      p.lineTo(rear.dx - cassetteRadius, rear.dy);
      p.arcTo(
        Rect.fromCircle(center: rear, radius: cassetteRadius),
        math.pi,
        math.pi + angle,
        false,
      );
    } else {
      final bottomRear = rear + radial(lowerAngle, cassetteRadius);
      p.lineTo(bottomRear.dx, bottomRear.dy);
      p.arcTo(
        Rect.fromCircle(center: rear, radius: cassetteRadius),
        lowerAngle,
        math.pi * 2 + angle - lowerAngle,
        false,
      );
    }
    return p..close();
  }

  Path caliperPath(Offset center) {
    final type = setup.brakeType(center == front);
    if (type == 'none') return Path();
    if (type == 'coaster') return lines([center, center + const Offset(58, 4)]);
    return discAt(center)
        ? (Path()..addRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center:
                    center +
                    Offset(
                      (center == front ? -.64 : .64) * rotorRadius(center),
                      -.77 * rotorRadius(center),
                    ),
                width: 15,
                height: 24,
              ),
              const Radius.circular(4),
            ),
          ))
        : lines([
            center + Offset(center == front ? -73 : 43, -123),
            center + Offset(center == front ? -59 : 57, -145),
            center + Offset(center == front ? -45 : 71, -123),
          ]);
  }

  Path brakePath(Offset center) => discAt(center)
      ? (Path()
          ..addPath(ring(center, rotorRadius(center)), Offset.zero)
          ..addPath(caliperPath(center), Offset.zero))
      : caliperPath(center);

  double distance(Path p, Offset point) {
    var result = double.infinity;
    for (final metric in p.computeMetrics()) {
      final count = math.max(1, (metric.length / 7).ceil());
      for (var i = 0; i <= count; i++) {
        final tangent = metric.getTangentForOffset(metric.length * i / count);
        if (tangent != null) {
          result = math.min(result, (tangent.position - point).distance);
        }
      }
    }
    return result;
  }

  List<BikePart> hit(Offset point, List<BikePart> parts, double tolerance) {
    final candidates =
        parts
            .where((p) => visible(p.template.id))
            .map(
              (p) => (part: p, distance: distance(path(p.template.id), point)),
            )
            .where((v) => v.distance <= tolerance)
            .toList()
          ..sort((a, b) => a.distance.compareTo(b.distance));
    if (candidates.isEmpty) return [];
    return candidates
        .where((v) => v.distance <= candidates.first.distance + tolerance * .45)
        .map((v) => v.part)
        .toList();
  }
}

class BikeDiagramPainter extends CustomPainter {
  BikeDiagramPainter({
    required this.geometry,
    required this.color,
    required this.parts,
    this.selectedId,
    required this.odometer,
    this.totalHours = 0,
    this.isEbike = false,
  });
  final BikeDiagramGeometry geometry;
  final Color color;
  final List<BikePart> parts;
  final String? selectedId;
  final double odometer, totalHours;
  final bool isEbike;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1000, size.height / 680);
    final g = geometry;
    void stroke(Path path, Color c, double width) => canvas.drawPath(
      path,
      Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..color = c
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawOval(
      const Rect.fromLTWH(45, 613, 900, 14),
      Paint()..color = Colors.black.withValues(alpha: .07),
    );
    for (final center in [g.rear, g.front]) {
      stroke(g.ring(center, 154), const Color(0xff263238), g.tyreWidth);
      stroke(
        g.ring(center, 143),
        const Color(0xff607d8b),
        g.setup.deepRims ? 17 : 5,
      );
      stroke(g.ring(center, 136), const Color(0xffcfd8dc), 3);
      for (var i = 0; i < 32; i++) {
        final a = i * math.pi / 16;
        stroke(
          g.lines([
            center + Offset(math.cos(a + .55) * 10, math.sin(a + .55) * 10),
            center + Offset(math.cos(a) * 136, math.sin(a) * 136),
          ]),
          const Color(0xff90a4ae),
          1.2,
        );
      }
      if (g.tyreWidth > 12 && g.setup.tyres != 'slick') {
        for (var i = 0; i < 64; i++) {
          final a = i * math.pi / 32;
          stroke(
            g.lines([
              center + Offset(math.cos(a) * 151, math.sin(a) * 151),
              center +
                  Offset(math.cos(a + .014) * 158, math.sin(a + .014) * 158),
            ]),
            const Color(0xff546e7a),
            g.kind == 'gravel' ? 2 : 4,
          );
        }
      }
      stroke(
        g.lines([center + const Offset(0, 126), center + const Offset(0, 139)]),
        const Color(0xff263238),
        3,
      );
      canvas.drawCircle(center, 11, Paint()..color = const Color(0xff455a64));
      if (g.discAt(center)) {
        final radius = g.rotorRadius(center);
        stroke(g.ring(center, radius), const Color(0xff90a4ae), 5);
        stroke(g.ring(center, radius - 5), const Color(0xffcfd8dc), 3);
        for (var i = 0; i < 6; i++) {
          final a = i * math.pi / 3;
          stroke(
            g.lines([
              center + Offset(math.cos(a) * 13, math.sin(a) * 13),
              center +
                  Offset(
                    math.cos(a + .3) * (radius - 5),
                    math.sin(a + .3) * (radius - 5),
                  ),
            ]),
            const Color(0xff90a4ae),
            4,
          );
        }
        for (var i = 0; i < 18; i++) {
          final a = i * math.pi / 9;
          canvas.drawCircle(
            center + Offset(math.cos(a), math.sin(a)) * (radius - 1),
            1.3,
            Paint()..color = const Color(0xff455a64),
          );
        }
      }
    }
    if (g.has('mudguards')) {
      stroke(g.path('mudguards'), const Color(0xff455a64), 7);
    }
    stroke(g.path('frame'), color, 13);
    stroke(
      g.lines([g.headBottom, g.crank]),
      color,
      g.kind == 'enduro' ? 23 : 19,
    );
    stroke(g.lines([g.head, g.headBottom]), color, 22);
    stroke(g.path('frame'), Colors.white.withValues(alpha: .22), 3);
    for (final joint in [g.head, g.headBottom, g.seat, g.crank]) {
      stroke(
        g.lines([joint + const Offset(-3, -4), joint + const Offset(3, 4)]),
        Colors.white.withValues(alpha: .28),
        2,
      );
    }
    stroke(g.path('seatpost'), const Color(0xff455a64), 10);
    if (g.has('dropper')) {
      final collar = Offset.lerp(g.seat, g.saddle, .45)!;
      stroke(g.lines([g.saddle, collar]), const Color(0xffb0bec5), 7);
      canvas.drawCircle(collar, 7, Paint()..color = const Color(0xff263238));
    }
    // A shaped saddle and rails remain legible when zooming in.
    stroke(
      g.lines([
        g.saddle + const Offset(-26, -3),
        g.saddle + const Offset(-7, 6),
        g.saddle + const Offset(26, -4),
      ]),
      const Color(0xff90a4ae),
      4,
    );
    canvas.drawPath(
      Path()
        ..moveTo(g.saddle.dx - 43, g.saddle.dy - 13)
        ..cubicTo(
          g.saddle.dx - 20,
          g.saddle.dy - 22,
          g.saddle.dx + 8,
          g.saddle.dy - 8,
          g.saddle.dx + 45,
          g.saddle.dy - 12,
        )
        ..quadraticBezierTo(
          g.saddle.dx + 55,
          g.saddle.dy - 3,
          g.saddle.dx + 34,
          g.saddle.dy,
        )
        ..lineTo(g.saddle.dx - 32, g.saddle.dy)
        ..close(),
      Paint()..color = const Color(0xff263238),
    );
    stroke(g.path('fork'), const Color(0xff455a64), g.suspension ? 20 : 12);
    if (g.suspension) {
      final crown = g.crown;
      final end = g.forkSeal;
      stroke(g.lines([crown, end]), const Color(0xffc5d3d9), 11);
      stroke(
        g.lines([crown + const Offset(-10, 8), crown + const Offset(15, 0)]),
        const Color(0xff263238),
        12,
      );
      canvas.drawCircle(
        crown + const Offset(8, -4),
        5,
        Paint()..color = Colors.blue.shade600,
      );
      stroke(
        g.lines([end, end + g.steeringAxis * 22]),
        const Color(0xff263238),
        23,
      );
    }
    stroke(g.path('headset'), const Color(0xff455a64), 16);
    stroke(g.path('stem'), const Color(0xff455a64), 10);
    stroke(g.path('handlebar'), const Color(0xff263238), 11);
    if (g.dropBar && g.setup.brakeType(true) != 'none') {
      stroke(g.path('shifters'), const Color(0xff455a64), 14);
    } else {
      stroke(
        g.lines([g.bar + const Offset(30, -6), g.bar + const Offset(60, -12)]),
        const Color(0xff111b20),
        16,
      );
      stroke(
        g.lines([g.bar + const Offset(27, -5), g.bar + const Offset(43, 17)]),
        const Color(0xff455a64),
        5,
      );
    }
    // Brake/shift housing is separate from the frame and handlebar.
    if (g.setup.brakeType(true) != 'none') {
      stroke(
        Path()
          ..moveTo(g.bar.dx + 40, g.bar.dy + 12)
          ..cubicTo(
            g.bar.dx + 110,
            g.bar.dy + 90,
            g.crown.dx - 20,
            g.crown.dy - 20,
            g.crown.dx - 5,
            g.crown.dy + 25,
          )
          ..lineTo(
            g.caliperPath(g.front).getBounds().center.dx,
            g.caliperPath(g.front).getBounds().center.dy,
          ),
        const Color(0xff607d8b),
        2,
      );
    }
    void sprocket(Offset center, double radius, int teeth, Color c) {
      final p = Path();
      for (var i = 0; i <= teeth * 4; i++) {
        final a = i * math.pi / (teeth * 2);
        final r = radius + (i % 4 == 1 || i % 4 == 2 ? 2.5 : 0);
        final point = center + Offset(math.cos(a) * r, math.sin(a) * r);
        if (i == 0) {
          p.moveTo(point.dx, point.dy);
        } else {
          p.lineTo(point.dx, point.dy);
        }
      }
      p.close();
      canvas.drawPath(p, Paint()..color = c);
      stroke(g.ring(center, radius - 4), const Color(0xffcfd8dc), 1.5);
    }

    // Nested sprockets reflect the configured number of gears, not a fixed 21.
    for (var i = 0; i < g.rearCount; i++) {
      final teeth =
          g.drivetrain?.gearsConfigured == true && i < g.drivetrain!.rear.length
          ? g.drivetrain!.rear[i]
          : 18;
      final r = g.rearCount == 1
          ? g.cassetteRadius
          : g.drivetrain?.gearsConfigured == true
          ? (teeth * .90).clamp(8.0, 50.0)
          : g.cassetteRadius - i * (g.cassetteRadius - 10) / (g.rearCount - 1);
      sprocket(
        g.rear + Offset(i * .25, 0),
        r,
        teeth,
        i.isEven ? const Color(0xff607d8b) : const Color(0xff90a4ae),
      );
    }
    for (var i = 0; i < g.frontCount; i++) {
      final teeth =
          g.drivetrain?.gearsConfigured == true &&
              i < g.drivetrain!.front.length
          ? g.drivetrain!.front[g.drivetrain!.front.length - 1 - i]
          : 28;
      sprocket(
        g.crank,
        i == 0 ? g.ringRadius : (teeth * .90).clamp(12.0, 55.0),
        teeth,
        i.isEven ? const Color(0xff455a64) : const Color(0xff90a4ae),
      );
    }
    for (var i = 0; i < 5; i++) {
      final a = i * math.pi * 2 / 5;
      stroke(
        g.lines([
          g.crank,
          g.crank + Offset(math.cos(a) * 27, math.sin(a) * 27),
        ]),
        const Color(0xffcfd8dc),
        4,
      );
    }
    stroke(g.path('chain'), const Color(0xff37474f), 6);
    stroke(g.path('chain'), const Color(0xffb0bec5), 2);
    for (final metric in g.path('chain').computeMetrics()) {
      for (double d = 0; d < metric.length; d += 10) {
        final tangent = metric.getTangentForOffset(d);
        if (tangent != null) {
          canvas.drawCircle(
            tangent.position,
            1.4,
            Paint()..color = const Color(0xff263238),
          );
        }
      }
    }
    stroke(g.path('cranks'), const Color(0xff455a64), 10);
    stroke(g.path('pedals'), const Color(0xff263238), 11);
    canvas.drawCircle(g.crank, 7, Paint()..color = const Color(0xffcfd8dc));
    if (g.rearDerailleur) {
      stroke(g.path('rear_derailleur'), const Color(0xff37474f), 9);
      for (final point in [g.upperPulley, g.lowerPulley]) {
        sprocket(point, 9, 10, const Color(0xff455a64));
        canvas.drawCircle(point, 3, Paint()..color = const Color(0xffcfd8dc));
      }
    }
    if (g.geared && g.frontCount > 1) {
      stroke(g.path('front_derailleur'), const Color(0xff90a4ae), 7);
    }
    for (final center in [g.rear, g.front]) {
      stroke(
        g.caliperPath(center),
        const Color(0xff263238),
        g.discAt(center) ? 5 : 6,
      );
    }
    if (g.kind == 'enduro') {
      stroke(
        g.lines([g.rocker, Offset.lerp(g.seat, g.head, .08)!]),
        const Color(0xff455a64),
        9,
      );
      stroke(g.lines([g.rearPivot, g.crank]), color, 13);
      stroke(g.path('shock'), const Color(0xff455a64), 16);
      final shockAxis = g.shockEnd - g.rocker;
      final normal =
          Offset(-shockAxis.dy, shockAxis.dx) / shockAxis.distance * 9;
      for (var i = 0; i < 7; i++) {
        final point = Offset.lerp(g.rocker, g.shockEnd, .25 + i * .08)!;
        stroke(
          g.lines([point - normal, point + normal + shockAxis * .025]),
          const Color(0xffcfd8dc),
          4,
        );
      }
      for (final point in [g.rearPivot, g.rocker, g.shockEnd]) {
        canvas.drawCircle(point, 6, Paint()..color = const Color(0xff263238));
        canvas.drawCircle(point, 2, Paint()..color = const Color(0xffb0bec5));
      }
    }
    if (g.has('rack')) {
      stroke(g.path('rack'), const Color(0xff455a64), 5);
      stroke(
        g.lines([g.rear + const Offset(85, -185), g.seat]),
        const Color(0xff455a64),
        4,
      );
      stroke(
        g.lines([g.rear + const Offset(-65, -185), g.rear]),
        const Color(0xff455a64),
        4,
      );
    }
    if (g.has('bottle_cage')) {
      for (final fraction in [.33, .55]) {
        final mount = Offset.lerp(g.crank, g.headBottom, fraction)!;
        stroke(
          g.lines([mount, mount + const Offset(-18, -20)]),
          const Color(0xff455a64),
          4,
        );
        canvas.drawCircle(mount, 3, Paint()..color = const Color(0xffcfd8dc));
      }
      canvas.drawPath(
        g.path('bottle_cage'),
        Paint()..color = Colors.blueGrey.shade200,
      );
      stroke(g.path('bottle_cage'), const Color(0xff455a64), 3);
      final tip = Offset.lerp(g.crank, g.headBottom, .63)!;
      stroke(
        g.lines([tip + const Offset(-14, -15), tip + const Offset(-30, -35)]),
        const Color(0xff263238),
        7,
      );
    }
    if (isEbike || g.has('battery')) {
      stroke(g.path('battery'), const Color(0xff263238), 23);
    }
    if (g.has('lights')) {
      stroke(g.path('lights'), const Color(0xff455a64), 14);
      canvas.drawCircle(
        g.bar + const Offset(30, 9),
        6,
        Paint()..color = Colors.amber.shade300,
      );
      canvas.drawCircle(
        g.seatAxis(g.seat.dy - 30) + const Offset(-10, 0),
        6,
        Paint()..color = Colors.red.shade500,
      );
    }
    for (final p in parts) {
      if (!g.visible(p.template.id)) continue;
      if (p.due(odometer, totalHours: totalHours)) {
        stroke(g.path(p.template.id), Colors.red.withValues(alpha: .72), 9);
      }
      if (p.id == selectedId) {
        stroke(g.path(p.template.id), Colors.teal.withValues(alpha: .20), 27);
        stroke(g.path(p.template.id), Colors.teal.shade600, 8);
      }
    }
    if (g.setup.showLabels) {
      void label(String text, Offset origin, Offset anchor) {
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: const TextStyle(fontSize: 16, color: Color(0xff263238)),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 230);
        stroke(
          g.lines([anchor, origin + Offset(8, painter.height + 5)]),
          const Color(0xff78909c),
          1.5,
        );
        final bounds = Rect.fromLTWH(
          origin.dx - 5,
          origin.dy - 3,
          painter.width + 10,
          painter.height + 6,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(bounds, const Radius.circular(5)),
          Paint()..color = Colors.white.withValues(alpha: .94),
        );
        painter.paint(canvas, origin);
      }

      label(
        g.geared
            ? (g.drivetrain?.gearsConfigured == true
                  ? 'Кассета · ${g.rearCount} звёзд'
                  : 'Кассета')
            : 'Задняя звезда',
        const Offset(75, 340),
        g.rear + const Offset(-20, -20),
      );
      label(
        'Система · ${g.frontCount} ${g.frontCount == 1 ? 'звезда' : 'звезды'}',
        const Offset(385, 565),
        g.crank + const Offset(20, 25),
      );
      label(
        g.suspension ? 'Амортизационная вилка' : 'Жёсткая вилка',
        const Offset(742, 205),
        Offset.lerp(g.head, g.front, .5)!,
      );
      label(
        g.discAt(g.front)
            ? 'Ротор ${g.setup.frontRotorMm} мм'
            : BikeSetup.individualBrakeTypes[g.setup.brakeType(true)] ??
                  'Тормоз',
        const Offset(740, 560),
        g.discAt(g.front)
            ? g.front + const Offset(30, 30)
            : g.front + const Offset(0, -145),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(BikeDiagramPainter old) =>
      old.geometry.kind != geometry.kind ||
      old.geometry.setup != geometry.setup ||
      old.geometry.parts != geometry.parts ||
      old.geometry.cassetteRadius != geometry.cassetteRadius ||
      old.geometry.ringRadius != geometry.ringRadius ||
      old.geometry.geared != geometry.geared ||
      old.geometry.rearCount != geometry.rearCount ||
      old.geometry.frontCount != geometry.frontCount ||
      old.isEbike != isEbike ||
      old.color != color ||
      old.parts != parts ||
      old.selectedId != selectedId ||
      old.odometer != odometer ||
      old.totalHours != totalHours;
}
