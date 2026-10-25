import 'dart:typed_data';

// Платформенная реализация чтения файла:
//  * Android/iOS/desktop → File(path)
//  * web                 → XFile(path) (blob/URL)
import 'file_reader_io.dart'
    if (dart.library.html) 'file_reader_web.dart'
    as impl;

/// Ошибка чтения локального файла с готовым для UI текстом.
class FileReadException implements Exception {
  const FileReadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Читает файл по пути в байты.
///
/// Единая точка входа для загрузок в Supabase Storage: конкретная реализация
/// подставляется через conditional import, поэтому код одинаково работает на
/// мобильных и на web. Любая ошибка заворачивается в [FileReadException].
Future<Uint8List> readBytesFromPath(String path) async {
  try {
    return await impl.readBytesFromPath(path);
  } on FileReadException {
    rethrow;
  } catch (error) {
    throw FileReadException('Не удалось прочитать файл фото: $error');
  }
}
