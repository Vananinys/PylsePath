import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/user_scope.dart';
import '../models/vehicle.dart';
import '../models/bike_setup.dart';
import 'notification_service.dart';
import 'push_service.dart';

/// Uses existing garage refreshes; no GPS, background service or polling timer.
class GarageMaintenanceReminders {
  static bool _checking = false;
  static List<String> dueLines(List<Vehicle> vehicles) => [
    for (final v in vehicles)
      if ((v.drivetrain?.setup ?? const BikeSetup()).maintenanceReminders)
        for (final p in v.parts)
          if (p.due(v.totalDistance, totalHours: v.recordedHours))
            '${v.name}: ${p.name}',
  ];
  static Future<void> check(List<Vehicle> vehicles) async {
    final uid = UserScope.currentUserId();
    if (uid == null || _checking) return;
    _checking = true;
    try {
      final own = vehicles.where((v) => v.userId == uid).toList();
      final lines = dueLines(own);
      NotificationService.instance.bindToUser(uid);
      NotificationService.instance.setMaintenance(
        lines.isEmpty ? null : lines.join('\n'),
      );
      if (lines.isEmpty) {
        await PushService.instance.clearMaintenanceReminder();
        return;
      }
      final now = DateTime.now();
      final fingerprint = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                '${now.year}-${now.month}-${now.day}',
                for (final v in own)
                  for (final p in v.parts)
                    if ((v.drivetrain?.setup ?? const BikeSetup())
                            .maintenanceReminders &&
                        p.due(v.totalDistance, totalHours: v.recordedHours))
                      [
                        v.id,
                        p.id,
                        p.lastServiceKm,
                        p.lastServiceHours,
                        p.lastServiceAt?.toIso8601String(),
                        p.intervalKm,
                        p.intervalHours,
                        p.intervalDays,
                        p.brakeInspection?.toJson(),
                      ],
              ]),
            ),
          )
          .toString();
      final prefs = await SharedPreferences.getInstance();
      final key = UserScope.keyFor('garage_maintenance_notice', uid);
      if (UserScope.currentUserId() != uid ||
          prefs.getString(key) == fingerprint) {
        return;
      }
      final shown = await PushService.instance.showMaintenanceReminder(
        uid,
        lines.take(4).join('\n') +
            (lines.length > 4
                ? '\nЕщё ${lines.length - 4} деталей в гараже'
                : ''),
      );
      if (shown && UserScope.currentUserId() == uid) {
        await prefs.setString(key, fingerprint);
      }
    } catch (error) {
      debugPrint('[Garage] reminders deferred: $error');
    } finally {
      _checking = false;
    }
  }
}
