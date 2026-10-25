import 'dart:io';
import 'dart:typed_data';

/// Реализация для Android/iOS/desktop: файл читается напрямую с диска.
Future<Uint8List> readBytesFromPath(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('Локальный файл фото не найден', path);
  }
  return file.readAsBytes();
}
