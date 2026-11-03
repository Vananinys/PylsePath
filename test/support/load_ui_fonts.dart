import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Use the same SDK fonts on Windows and CI instead of test-only Ahem metrics.
Future<void> loadUiFonts() async {
  final config = File('.dart_tool/package_config.json');
  final packages =
      (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
  final flutter = packages.cast<Map>().singleWhere(
    (p) => p['name'] == 'flutter',
  );
  final packageRoot = Directory.fromUri(
    config.absolute.uri.resolve(flutter['rootUri'] as String),
  ).uri;
  final fonts = packageRoot.resolve(
    '../../bin/cache/artifacts/material_fonts/',
  );
  for (final entry in {
    'Roboto': 'roboto-regular.ttf',
    'MaterialIcons': 'materialicons-regular.otf',
  }.entries) {
    final file = File.fromUri(fonts.resolve(entry.value));
    await (FontLoader(
      entry.key,
    )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
  }
}
