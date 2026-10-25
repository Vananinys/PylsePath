import 'dart:io';

import 'package:flutter/painting.dart';

ImageProvider? localProfilePhoto(String? path) {
  if (path == null) return null;
  try {
    final file = File(path);
    return file.existsSync() ? FileImage(file) : null;
  } catch (_) {
    return null;
  }
}
