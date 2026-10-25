import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' hide Path;

/// Погода на текущий час для точки старта заезда (Open-Meteo).
///
/// Open-Meteo бесплатен и не требует ключа — для предзапуска этого достаточно.
/// При любой ошибке возвращает null: HUD просто не показывает погоду.
class WeatherService {
  static const String _url = 'https://api.open-meteo.com/v1/forecast';

  Future<WeatherInfo?> fetchCurrent(LatLng point) async {
    final uri = Uri.parse(
      '$_url?latitude=${point.latitude.toStringAsFixed(4)}'
      '&longitude=${point.longitude.toStringAsFixed(4)}'
      '&current=temperature_2m,precipitation,wind_speed_10m,weather_code'
      '&wind_speed_unit=kmh',
    );

    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final current = data['current'];
      if (current == null) return null;

      return WeatherInfo(
        temperatureC: _toDouble(current['temperature_2m']),
        windKmh: _toDouble(current['wind_speed_10m']),
        precipitationMm: _toDouble(current['precipitation']),
        code: (current['weather_code'] as num?)?.toInt() ?? -1,
      );
    } on TimeoutException {
      return null;
    } catch (error) {
      debugPrint('[Weather] fetch failed: $error');
      return null;
    }
  }

  static double? _toDouble(Object? value) =>
      value is num ? value.toDouble() : null;
}

/// Текущая погода в точке старта.
class WeatherInfo {
  final double? temperatureC;
  final double? windKmh;
  final double? precipitationMm;

  /// Код погоды WMO (0 — ясно, 1–3 — облачно, 51+ — дождь, 71+ — снег...).
  final int code;

  /// Дефолтное значение температуры, если данных нет
  static const double _defaultTemp = 0;

  const WeatherInfo({
    required this.temperatureC,
    required this.windKmh,
    required this.precipitationMm,
    required this.code,
  });

  /// Исправлено: теперь иконка проверена на валидность кода погоды
  IconData get icon {
    // Проверка валидности кода: отрицательный или >200 — ошибка сети
    if (code < 0 || code > 200) return Icons.help_outline;
    if (code == 0) return Icons.wb_sunny_outlined;
    if (code <= 3) return Icons.cloud_outlined;
    if (code <= 48) return Icons.cloud_queue;
    if (code <= 67) return Icons.umbrella;
    if (code <= 77) return Icons.ac_unit;
    if (code <= 82) return Icons.umbrella;
    return Icons.flash_on; // гроза
  }

  /// Исправлено: теперь показывается дефолт, если данных нет
  String get label {
    // Проверка валидности кода перед выводом
    if (code < 0 || code > 200) return 'Неизвестно';
    if (code == 0) return 'Ясно';
    if (code <= 2) return 'Малооблачно';
    if (code == 3) return 'Облачно';
    if (code <= 48) return 'Туман';
    if (code <= 57) return 'Морось';
    if (code <= 67) return 'Дождь';
    if (code <= 77) return 'Снег';
    if (code <= 82) return 'Ливни';
    return 'Гроза';
  }

  /// Строка для HUD: «14° · Ветер 12 км/ч · Дождь».
  String get shortDescription {
    final parts = <String>[];
    if (temperatureC != null) parts.add('${temperatureC!.round()}°');
    if (windKmh != null) parts.add('ветер ${windKmh!.round()} км/ч');
    final condition = label;
    if (condition.isNotEmpty) parts.add(condition.toLowerCase());
    return parts.join(' · ');
  }
}
