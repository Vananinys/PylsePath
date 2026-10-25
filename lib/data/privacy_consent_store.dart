import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/privacy_consent.dart';
import 'user_scope.dart';

/// Local evidence only. Never exports age or consent into a sports profile.
class PrivacyConsentStore {
  static const pendingKey = 'privacy_registration_pending_v1';
  static String accountKey(String owner) =>
      UserScope.keyFor('privacy_consent_v1', owner);

  Future<void> savePending(PrivacyConsentReceipt receipt) =>
      _write(pendingKey, receipt);

  Future<void> saveForAccount(String owner, PrivacyConsentReceipt receipt) {
    if (owner.isEmpty || owner.length > 128) {
      throw ArgumentError.value(owner, 'owner');
    }
    return _write(accountKey(owner), receipt);
  }

  Future<PrivacyConsentReceipt?> readForAccount(String owner) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(accountKey(owner));
    if (raw == null) return null;
    if (raw.length > 4096) {
      throw const FormatException('Local consent record too large');
    }
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid local consent record');
    }
    return PrivacyConsentReceipt.fromJson(json);
  }

  Future<void> _write(String key, PrivacyConsentReceipt receipt) async {
    // Reject attempts to bypass the age restriction through a caller.
    if (!receipt.isCurrent ||
        (receipt.source != 'registration' && receipt.source != 'settings')) {
      throw StateError('Current consent for age 14+ required');
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, jsonEncode(receipt.toJson()))) {
      throw StateError('Не удалось сохранить подтверждение на телефоне');
    }
  }
}
