import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

class ChatMediaDraft {
  const ChatMediaDraft({
    required this.file,
    required this.isVideo,
    required this.size,
    this.editedBytes,
  });
  static const maxItems = 20;
  static const photoLimit = 20 * 1024 * 1024;
  static const videoLimit = 50 * 1024 * 1024;
  static const batchLimit = 100 * 1024 * 1024;
  final XFile file;
  final bool isVideo;
  final int size;
  final Uint8List? editedBytes;
  int get byteLength => editedBytes?.length ?? size;

  String get extension {
    if (editedBytes != null) return '.png';
    final name = file.name.toLowerCase();
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot);
  }

  String? get validationError {
    final allowed = isVideo
        ? const ['.mp4', '.mov', '.m4v', '.webm']
        : const ['.jpg', '.jpeg', '.png', '.webp'];
    if (!allowed.contains(extension)) {
      return isVideo
          ? 'Выберите видео MP4, MOV, M4V или WebM'
          : 'Выберите фото JPEG, PNG или WebP';
    }
    if (byteLength <= 0) return 'Файл пуст';
    if (byteLength > (isVideo ? videoLimit : photoLimit)) {
      return isVideo
          ? 'Видео должно быть не больше 50 МБ'
          : 'Фото должно быть не больше 20 МБ';
    }
    return null;
  }

  ChatMediaDraft edited(Uint8List bytes) => ChatMediaDraft(
    file: file,
    isVideo: isVideo,
    size: size,
    editedBytes: bytes,
  );

  static String? validateBatch(List<ChatMediaDraft> items) {
    if (items.isEmpty) return 'Добавьте вложения';
    if (items.length > maxItems) return 'Можно отправить до 20 файлов за раз';
    for (final item in items) {
      if (item.validationError != null) return item.validationError;
    }
    if (items.fold<int>(0, (sum, item) => sum + item.byteLength) > batchLimit) {
      return 'Общий размер вложений должен быть не больше 100 МБ';
    }
    return null;
  }
}
