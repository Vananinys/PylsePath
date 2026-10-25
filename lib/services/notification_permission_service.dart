import 'package:permission_handler/permission_handler.dart';

/// One outstanding runtime permission request shared by FCM and GPS recording.
class NotificationPermissionService {
  static Future<bool>? _pending;
  static Future<bool> request() => _pending ??= _request();
  static Future<bool> _request() async {
    try {
      return (await Permission.notification.request()).isGranted;
    } finally {
      _pending = null;
    }
  }
}
