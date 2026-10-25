import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/saved_route.dart';
import 'gpx_utils.dart';

/// Sharing in-memory bytes also works on web and does not leave temporary
/// coordinate files in the application's document directory.
class GpxShare {
  static Future<void> route(BuildContext context, SavedRoute route) => text(
    context,
    GpxUtils.build(
      points: route.routePoints,
      name: route.title,
      createdAt: route.dateTime,
      segmentStarts: route.workoutDetails.segmentStarts,
    ),
    route.title,
  );

  static Future<void> text(
    BuildContext context,
    String gpx,
    String name,
  ) async {
    final safe = name.replaceAll(RegExp(r'[^\w\-а-яА-ЯёЁ ]'), '').trim();
    final filename =
        '${safe.isEmpty ? 'PulsePath' : safe.substring(0, safe.length.clamp(0, 80))}.gpx';
    final box = context.findRenderObject();
    final origin = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 1, 1);
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(utf8.encode(gpx), mimeType: 'application/gpx+xml'),
        ],
        fileNameOverrides: [filename],
        sharePositionOrigin: origin,
      ),
    );
  }
}
