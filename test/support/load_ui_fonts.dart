import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Load a licensed test font consistently instead of test-only Ahem metrics.
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
    'Roboto': File('test/support/fonts/roboto-regular.ttf'),
    'MaterialIcons': Directory.fromUri(fonts)
        .listSync()
        .whereType<File>()
        .singleWhere(
          (file) =>
              file.uri.pathSegments.last.toLowerCase() ==
              'materialicons-regular.otf',
        ),
  }.entries) {
    final file = entry.value;
    await (FontLoader(
      entry.key,
    )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
  }
}
