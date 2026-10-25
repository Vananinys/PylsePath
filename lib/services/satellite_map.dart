import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class SatelliteMap {
  static String? template;
  static String attribution = '© MapTiler';
  static int maxZoom = 18;
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    template = prefs.getString('satellite_template');
    attribution = prefs.getString('satellite_attribution') ?? '© MapTiler';
    maxZoom = prefs.getInt('satellite_max_zoom') ?? 18;
  }

  static Future<void> configure(String key) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{10,200}$').hasMatch(key))
      throw const FormatException('Проверьте ключ MapTiler');
    final response = await http
        .get(
          Uri.https('api.maptiler.com', '/tiles/satellite-v4/tiles.json', {
            'key': key,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200)
      throw const FormatException(
        'Ключ не принят или спутниковый слой недоступен по вашему тарифу.',
      );
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final tile = (data['tiles'] as List).first as String;
    final uri = Uri.parse(tile);
    if (uri.scheme != 'https' || uri.host != 'api.maptiler.com')
      throw const FormatException('Неподдерживаемый адрес тайлов');
    final url = tile.contains('key=')
        ? tile
        : '$tile${tile.contains('?') ? '&' : '?'}key=${Uri.encodeQueryComponent(key)}';
    final label = (data['attribution'] as String? ?? '© MapTiler')
        .replaceAll(RegExp('<[^>]*>'), '')
        .replaceAll('&copy;', '©')
        .replaceAll('&amp;', '&');
    final zoom = (data['maxzoom'] as num?)?.toInt() ?? 18;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('satellite_template', url);
    await prefs.setString('satellite_attribution', label);
    await prefs.setInt('satellite_max_zoom', zoom);
    template = url;
    attribution = label;
    maxZoom = zoom;
  }

  static Future<void> remove() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('satellite_template');
    await prefs.remove('satellite_attribution');
    await prefs.remove('satellite_max_zoom');
    template = null;
  }
}
