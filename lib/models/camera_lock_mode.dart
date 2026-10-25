import 'package:flutter/material.dart';

/// Режим фиксации камеры на карте (как в Komoot).
enum CameraLockMode {
  /// Пользователь свободно управляет картой (перетаскивание, вращение).
  free,

  /// Карта следует за местоположением пользователя, но не вращается.
  follow,

  /// Карта следует за местоположением и вращается по компасу (heading).
  followAndHeading;

  /// Следующий режим по кругу (для кнопки-переключателя).
  CameraLockMode get next {
    switch (this) {
      case CameraLockMode.free:
        return CameraLockMode.follow;
      case CameraLockMode.follow:
        return CameraLockMode.followAndHeading;
      case CameraLockMode.followAndHeading:
        return CameraLockMode.free;
    }
  }

  String get label {
    switch (this) {
      case CameraLockMode.free:
        return 'Свободный';
      case CameraLockMode.follow:
        return 'Следовать';
      case CameraLockMode.followAndHeading:
        return 'Следовать + Поворот';
    }
  }

  IconData get icon {
    switch (this) {
      case CameraLockMode.free:
        return Icons.pan_tool;
      case CameraLockMode.follow:
        return Icons.my_location;
      case CameraLockMode.followAndHeading:
        return Icons.navigation;
    }
  }

  /// Возвращает true, если режим включает следование за пользователем.
  bool get isFollowing =>
      this == CameraLockMode.follow || this == CameraLockMode.followAndHeading;

  /// Возвращает true, если режим включает вращение карты по компасу.
  bool get isRotating => this == CameraLockMode.followAndHeading;
}
