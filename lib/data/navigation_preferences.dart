import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local map appearance; no account or route data is changed.
class NavigationPreferences extends ChangeNotifier {
  static final instance = NavigationPreferences._();
  NavigationPreferences._();
  static const palette = [
    Colors.deepOrange,
    Colors.blue,
    Colors.purple,
    Colors.teal,
  ];
  int colorIndex = 0;
  double lineWidth = 5.5;
  double followZoom = 17;
  bool cachedMapOnly = false;
  Color get routeColor => palette[colorIndex];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    colorIndex = (prefs.getInt('nav_color') ?? 0).clamp(0, palette.length - 1);
    lineWidth = (prefs.getDouble('nav_line_width') ?? 5.5).clamp(3, 10);
    followZoom = (prefs.getDouble('nav_follow_zoom') ?? 17).clamp(14, 19);
    cachedMapOnly = prefs.getBool('nav_cached_map_only') ?? false;
  }

  Future<void> update({
    int? color,
    double? width,
    double? zoom,
    bool? cachedOnly,
  }) async {
    if (cachedOnly != null) cachedMapOnly = cachedOnly;
    if (color != null) colorIndex = color.clamp(0, palette.length - 1);
    if (width != null) lineWidth = width.clamp(3, 10);
    if (zoom != null) followZoom = zoom.clamp(14, 19);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('nav_color', colorIndex);
    await prefs.setDouble('nav_line_width', lineWidth);
    await prefs.setDouble('nav_follow_zoom', followZoom);
    await prefs.setBool('nav_cached_map_only', cachedMapOnly);
  }
}
