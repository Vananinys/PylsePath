import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Repeated OS action delivery retries the same insert instead of sending twice.
String notificationReplyId(String owner, String messageId, String text) {
  final bytes = sha256
      .convert(utf8.encode(jsonEncode([owner, messageId, text])))
      .bytes
      .toList();
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .take(16)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

int chatNotificationId(String receiver, String sender) {
  var value = 2166136261;
  for (final unit in '$receiver:$sender'.codeUnits) {
    value = ((value ^ unit) * 16777619) & 0x7fffffff;
  }
  return value;
}
