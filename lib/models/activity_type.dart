import 'package:flutter/material.dart';

enum ActivityType {
  mountainBiking('МТБ', Icons.terrain, 'cycling-regular', 12.0, 550),
  roadCycling('Шоссе', Icons.directions_bike, 'cycling-road', 22.0, 480),
  gravelRiding(
    'Грейвел',
    Icons.directions_bike_outlined,
    'cycling-regular',
    17.0,
    520,
  ),
  bikepacking('Туризм', Icons.backpack_outlined, 'cycling-regular', 14.0, 420),
  cycling('Город', Icons.pedal_bike, 'cycling-regular', 15.0, 350),
  hiking('Пешком', Icons.hiking, 'foot-walking', 4.0, 280),
  running('Бег', Icons.directions_run, 'foot-walking', 9.5, 680),
  driving('Авто', Icons.directions_car, 'driving-car', 45.0, 0),
  briskWalking(
    'Быстрая ходьба',
    Icons.directions_walk,
    'foot-walking',
    5.8,
    336,
  ),
  nordicWalking('Скандинавская ходьба', Icons.hiking, 'foot-walking', 5.0, 301),
  trekking('Поход', Icons.backpack_outlined, 'foot-walking', 3.5, 371),
  trailRunning('Трейловый бег', Icons.terrain, 'foot-walking', 8.0, 651);

  final String label;
  final IconData icon;
  final String orsProfile;
  final double avgSpeedKmH;
  final int kcalPerHour;
  bool get isRunning => this == running || this == trailRunning;
  bool get isFoot =>
      isRunning ||
      this == hiking ||
      this == briskWalking ||
      this == nordicWalking ||
      this == trekking;

  const ActivityType(
    this.label,
    this.icon,
    this.orsProfile,
    this.avgSpeedKmH,
    this.kcalPerHour,
  );
}
