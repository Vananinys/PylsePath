import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Ошибка выбора фото с готовым для UI текстом (в том числе отказ в доступе).
class ProfilePhotoException implements Exception {
  const ProfilePhotoException(this.message, {this.isPermissionDenied = false});

  final String message;

  /// true — пользователь запретил доступ к галерее (нужно вести в настройки).
  final bool isPermissionDenied;

  @override
  String toString() => message;
}

/// Загрузка пользовательского фото профиля из галереи устройства.
///
/// Важно: путь, который отдаёт `image_picker`, лежит во временном кэше
/// (`.../cache/...`) и может быть очищен системой в любой момент. Поэтому
/// выбранный файл КОПИРУЕТСЯ в каталог документов приложения, и в
/// SharedPreferences сохраняется уже этот постоянный путь.
class ProfilePhotoService {
  ProfilePhotoService({ImagePicker? picker})
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static const String _photosFolderName = 'profile_photos';
  static const int _maxSidePx = 1024;
  static const int _imageQuality = 85;

  /// Открывает галерею и возвращает путь к сохранённой копии фото.
  ///
  /// `null` означает, что пользователь закрыл галерею, ничего не выбрав.
  /// При отказе в доступе бросает [ProfilePhotoException].
  Future<String?> pickFromGallery() async {
    final XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: ImageSource.gallery,
        // Аватар не нужен в полном разрешении: экономим память и место.
        maxWidth: _maxSidePx.toDouble(),
        maxHeight: _maxSidePx.toDouble(),
        imageQuality: _imageQuality,
      );
    } on PlatformException catch (error) {
      throw ProfilePhotoException(
        _describePlatformError(error),
        isPermissionDenied: _isPermissionDenied(error),
      );
    } on MissingPluginException {
      throw const ProfilePhotoException(
        'Выбор фото не поддерживается на этой платформе',
      );
    }

    if (picked == null) return null; // отмена выбора
    return _copyToDocuments(picked);
  }

  /// Выбирает пейзажное фото для баннера и сохраняет копию до завершения
  /// загрузки в облако.
  Future<String?> pickCoverFromGallery() async {
    final XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1200,
        imageQuality: 88,
      );
    } on PlatformException catch (error) {
      throw ProfilePhotoException(
        _describePlatformError(error),
        isPermissionDenied: _isPermissionDenied(error),
      );
    } on MissingPluginException {
      throw const ProfilePhotoException(
        'Выбор фото не поддерживается на этой платформе',
      );
    }

    if (picked == null) return null;
    return _copyToDocuments(picked, prefix: 'cover');
  }

  /// Копирует выбранный файл в постоянный каталог и возвращает новый путь.
  Future<String> _copyToDocuments(
    XFile picked, {
    String prefix = 'avatar',
  }) async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      final folder = Directory('${documents.path}/$_photosFolderName');
      if (!folder.existsSync()) {
        await folder.create(recursive: true);
      }

      final extension =
          _extensionOf(picked.path) ?? _extensionOf(picked.name) ?? '.jpg';
      final targetPath =
          '${folder.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}$extension';

      await File(picked.path).copy(targetPath);
      debugPrint('[ProfilePhotoService] Фото сохранено: $targetPath');
      return targetPath;
    } on FileSystemException catch (error) {
      throw ProfilePhotoException(
        'Не удалось сохранить фото: ${error.message}',
      );
    }
  }

  /// Удаляет ранее сохранённый файл фото (best effort).
  Future<void> deletePhoto(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
        debugPrint('[ProfilePhotoService] Старое фото удалено: $path');
      }
    } catch (error) {
      debugPrint('[ProfilePhotoService] Не удалось удалить фото: $error');
    }
  }

  /// Существует ли файл по сохранённому пути (проверка перед отрисовкой).
  static Future<File?> resolveExistingFile(String? path) async {
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    return await file.exists() ? file : null;
  }

  static bool _isPermissionDenied(PlatformException error) {
    const permissionCodes = {
      'photo_access_denied',
      'camera_access_denied',
      'permission_denied',
    };
    return permissionCodes.contains(error.code) ||
        (error.message?.toLowerCase().contains('permission') ?? false);
  }

  static String _describePlatformError(PlatformException error) {
    switch (error.code) {
      case 'photo_access_denied':
        return 'Нет доступа к галерее. Разрешите доступ к фото в настройках приложения.';
      case 'camera_access_denied':
        return 'Нет доступа к камере';
      case 'invalid_image':
        return 'Выбранный файл не является изображением';
      default:
        return 'Не удалось открыть галерею: ${error.message ?? error.code}';
    }
  }

  /// Расширение файла вместе с точкой ('.jpg'); null, если его нет.
  /// `package:path` намеренно не тянем — хватает десяти строк.
  static String? _extensionOf(String? path) {
    if (path == null || path.isEmpty) return null;
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    if (dot <= slash || dot == path.length - 1) return null; // нет расширения
    final extension = path.substring(dot).toLowerCase();
    // .jpg .png .heic .webp — разумный предел, отсекаем мусор.
    if (extension.length < 2 || extension.length > 6) return null;
    return extension;
  }
}
