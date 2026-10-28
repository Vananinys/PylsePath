import 'live_trail_style.dart';

/// Модели сообщества: друзья, заявки в друзья, живая позиция друга.
class FriendProfile {
  final LiveTrailStyle? liveTrailStyle;
  final double? liveSpeedKmh;
  final String? liveActivity;
  final bool livePaused;
  final String id;
  final String username;
  final String? avatarUrl;
  final String? status;
  final String? city;

  /// Тип катания — имя RidingType (из публичной проекции профилей).
  final String? preferredRidingType;

  /// Вес/возраст/пол — приходят из публичной проекции; если пользователь
  /// скрыл поле (настройка приватности), БД отдаёт null.
  final double? weightKg;
  final int? age;
  final String? gender;

  /// Скрывает ли пользователь список своих друзей (приватный профиль).
  final bool showFriends;

  /// Живая позиция (обновляется в Realtime, пока друг в заезде).
  final double? liveLatitude;
  final double? liveLongitude;
  final DateTime? liveUpdatedAt;

  const FriendProfile({
    this.liveTrailStyle,
    this.liveSpeedKmh,
    this.liveActivity,
    this.livePaused = false,
    required this.id,
    required this.username,
    this.avatarUrl,
    this.status,
    this.city,
    this.preferredRidingType,
    this.weightKg,
    this.age,
    this.gender,
    this.showFriends = true,
    this.liveLatitude,
    this.liveLongitude,
    this.liveUpdatedAt,
  });

  /// Есть ли вообще последняя известная позиция (показываем всегда,
  /// в том числе в простое — как просил пользователь).
  bool get hasLivePosition =>
      liveLatitude != null && liveLongitude != null && liveUpdatedAt != null;

  /// Друг прямо сейчас в заезде (позиция свежее 10 минут).
  bool get isLive {
    if (!hasLivePosition) return false;
    return hasFreshMotion && liveActivity != null && liveActivity != 'idle';
  }

  /// Сколько времени назад была обновлена позиция (для подписи).
  String get positionAgeText {
    if (liveUpdatedAt == null) return '';
    final diff = DateTime.now().difference(liveUpdatedAt!);
    if (diff.inMinutes < 1) return 'только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
    final hours = diff.inHours;
    if (hours < 24) return '$hours ч назад';
    return '${diff.inDays} дн назад';
  }

  bool get hasFreshMotion =>
      liveUpdatedAt != null &&
      DateTime.now().difference(liveUpdatedAt!) < const Duration(seconds: 30);

  /// Keep map labels compact; position age remains in the friend's details.
  String get mapLabel => isLive ? '$username\n$motionText' : username;

  String get motionText {
    if (!hasFreshMotion) return 'Обновлено $positionAgeText';
    if (livePaused) return 'На паузе';
    final activity = switch (liveActivity) {
      'running' || 'trailRunning' => 'Бежит',
      'hiking' ||
      'briskWalking' ||
      'nordicWalking' ||
      'trekking' => 'Идёт пешком',
      'driving' => 'В поездке на авто',
      'idle' => 'Позиция обновляется',
      'mountainBiking' ||
      'roadCycling' ||
      'gravelRiding' ||
      'bikepacking' ||
      'cycling' => 'В заезде',
      _ => 'Позиция обновляется',
    };
    final speed = liveSpeedKmh;
    return speed != null && speed.isFinite && speed >= 0
        ? '$activity · ${speed.toStringAsFixed(1)} км/ч'
        : activity;
  }

  factory FriendProfile.fromRow(Map<String, dynamic> row) {
    final liveUpdatedAt = _parseDate(row['live_updated_at']);
    return FriendProfile(
      liveTrailStyle: row['live_trail_style'] is Map
          ? LiveTrailStyle.fromRow(
              Map<String, dynamic>.from(row['live_trail_style'] as Map),
            )
          : null,
      liveSpeedKmh: _toDouble(row['live_speed_kmh']),
      liveActivity: row['live_activity'] as String?,
      livePaused: row['live_paused'] == true,
      id: (row['id'] ?? '').toString(),
      username: (row['username'] as String?)?.trim().isNotEmpty == true
          ? (row['username'] as String).trim()
          : 'Райдер',
      avatarUrl: row['avatar_url'] as String?,
      status: row['status'] as String?,
      city: row['city'] as String?,
      preferredRidingType: row['preferred_riding_type'] as String?,
      weightKg: _toDouble(row['weight']),
      age: _toInt(row['age']),
      gender: row['gender'] as String?,
      showFriends: row['show_friends'] as bool? ?? true,
      liveLatitude: _toDouble(row['live_latitude']),
      liveLongitude: _toDouble(row['live_longitude']),
      liveUpdatedAt: liveUpdatedAt,
    );
  }

  FriendProfile copyWith({
    LiveTrailStyle? liveTrailStyle,
    double? liveSpeedKmh,
    String? liveActivity,
    bool? livePaused,
    double? liveLatitude,
    double? liveLongitude,
    DateTime? liveUpdatedAt,
  }) {
    return FriendProfile(
      liveTrailStyle: liveTrailStyle ?? this.liveTrailStyle,
      liveSpeedKmh: liveSpeedKmh,
      liveActivity: liveActivity,
      livePaused: livePaused ?? this.livePaused,
      showFriends: showFriends,
      id: id,
      username: username,
      avatarUrl: avatarUrl,
      status: status,
      city: city,
      preferredRidingType: preferredRidingType,
      weightKg: weightKg,
      age: age,
      gender: gender,
      liveLatitude: liveLatitude,
      liveLongitude: liveLongitude,
      liveUpdatedAt: liveUpdatedAt,
    );
  }

  static double? _toDouble(Object? value) =>
      value is num ? value.toDouble() : null;

  static int? _toInt(Object? value) => value is num ? value.toInt() : null;

  static DateTime? _parseDate(Object? value) {
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }
}

/// Заявка в друзья: входящая (ко мне) или исходящая.
class FriendRequest {
  final String id;

  /// Пользователь, с которым хотят дружить (для входящих — это я? см. [incoming]).
  final String fromUserId;
  final String fromUsername;
  final String? fromAvatarUrl;

  final String toUserId;
  final String toUsername;
  final String? toAvatarUrl;

  final DateTime createdAt;

  const FriendRequest({
    required this.id,
    required this.fromUserId,
    required this.fromUsername,
    this.fromAvatarUrl,
    required this.toUserId,
    required this.toUsername,
    this.toAvatarUrl,
    required this.createdAt,
  });

  factory FriendRequest.fromRow(Map<String, dynamic> row) {
    return FriendRequest(
      id: (row['id'] ?? '').toString(),
      fromUserId: (row['from_user'] ?? '').toString(),
      fromUsername: (row['from_username'] as String?)?.trim().isNotEmpty == true
          ? (row['from_username'] as String).trim()
          : 'Райдер',
      fromAvatarUrl: row['from_avatar_url'] as String?,
      toUserId: (row['to_user'] ?? '').toString(),
      toUsername: (row['to_username'] as String?)?.trim().isNotEmpty == true
          ? (row['to_username'] as String).trim()
          : 'Райдер',
      toAvatarUrl: row['to_avatar_url'] as String?,
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
