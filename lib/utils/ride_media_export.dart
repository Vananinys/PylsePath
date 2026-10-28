import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;

Future<Uint8List> exportRidePhoto(Uint8List original) async {
  final codec = await ui.instantiateImageCodec(
    original,
    targetWidth: 2048,
    allowUpscaling: false,
  );
  ui.Image? image;
  try {
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Фото не удалось подготовить');
    return data.buffer.asUint8List();
  } finally {
    image?.dispose();
    codec.dispose();
  }
}

Future<String> exportRideVideo(String path) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    throw UnsupportedError(
      'Публикация видео на треке пока доступна на Android.',
    );
  }
  final result = await const MethodChannel('pulsepath/ride_media')
      .invokeMethod<String>('stripVideoMetadata', {'path': path})
      .timeout(const Duration(minutes: 2));
  if (result == null) throw StateError('Не удалось подготовить видео');
  return result;
}
