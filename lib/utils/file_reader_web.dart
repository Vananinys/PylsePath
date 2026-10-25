import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Реализация для web: файл представлен blob/URL, читаем через [XFile].
Future<Uint8List> readBytesFromPath(String path) => XFile(path).readAsBytes();
