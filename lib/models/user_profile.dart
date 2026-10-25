enum BikeType {
  hardtail('Хардтейл'),
  semiFat('Семи-фэт'),
  fatbike('Фэтбайк'),
  gravel('Грэвел'),
  road('Шоссейный'),
  city('Городской'),
  mountain('МТБ'), // для обратной совместимости
  roadLegacy('Шоссе'), // для обратной совместимости
  gravelLegacy('Грейвел'); // для обратной совместимости

  final String label;
  const BikeType(this.label);
}

enum RidingType {
  crossCountry('Кросс-кантри'),
  gravel('Грэвел'),
  road('Шоссе'),
  city('Город');

  final String label;
  const RidingType(this.label);
}

class Bike {
  final String id;
  final String name;
  final double weightKg;
  final BikeType type;
  final double wheelSize; // диаметр колес в дюймах
  final double totalDistance; // пробег в км
  final bool isEbike; // электропривод — свойство техники

  Bike({
    String? id,
    required this.name,
    required this.weightKg,
    required this.type,
    this.wheelSize = 29.0,
    this.totalDistance = 0.0,
    this.isEbike = false,
  }) : id = id ?? DateTime.now().millisecondsSinceEpoch.toString();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'weightKg': weightKg,
    // Тип храним по имени: числовой индекс молча ломает сохранённый
    // гараж при вставке нового значения в середину enum'а.
    'type': type.name,
    'wheelSize': wheelSize,
    'totalDistance': totalDistance,
    'isEbike': isEbike,
  };

  factory Bike.fromJson(Map<String, dynamic> json) => Bike(
    id: json['id'] as String?,
    name: json['name'] as String,
    weightKg: (json['weightKg'] as num).toDouble(),
    // Имя типа — новый формат; числовой индекс — легаси (старые записи).
    type: _bikeTypeFromJson(json['type']),
    wheelSize: (json['wheelSize'] as num?)?.toDouble() ?? 29.0,
    totalDistance: (json['totalDistance'] as num?)?.toDouble() ?? 0.0,
    isEbike: json['isEbike'] as bool? ?? false,
  );

  static BikeType _bikeTypeFromJson(Object? value) {
    if (value is String) {
      for (final type in BikeType.values) {
        if (type.name == value) return type;
      }
    }
    // Легаси: в старых записях лежал индекс enum'а.
    if (value is int && value >= 0 && value < BikeType.values.length) {
      return BikeType.values[value];
    }
    return BikeType.hardtail;
  }
}

class UserProfile {
  // ── Физические границы параметров райдера ────────────────────────────────
  // Единый источник правды: используются и валидаторами формы, и хранилищем,
  // чтобы аномальные значения (вес 148852 кг, рост 1488 см, возраст 1488 лет)
  // нельзя было ни ввести, ни сохранить, ни прочитать из старого профиля.
  static const double minWeightKg = 20.0;
  static const double maxWeightKg = 250.0;
  static const double minHeightCm = 100.0;
  static const double maxHeightCm = 230.0;
  static const int minAge = 5;
  static const int maxAge = 120;

  static bool isValidWeight(double value) =>
      value.isFinite && value >= minWeightKg && value <= maxWeightKg;

  static bool isValidHeight(double value) =>
      value.isFinite && value >= minHeightCm && value <= maxHeightCm;

  static bool isValidAge(int value) => value >= minAge && value <= maxAge;

  /// Приводит значение к допустимому диапазону.
  /// NaN/Infinity (могут прийти из JSON или из `double.tryParse('1e999')`)
  /// заменяются на нижнюю границу, потому что `clamp` их не отсекает.
  static double clampWeight(double value) => value.isFinite
      ? value.clamp(minWeightKg, maxWeightKg).toDouble()
      : minWeightKg;

  static double clampHeight(double value) => value.isFinite
      ? value.clamp(minHeightCm, maxHeightCm).toDouble()
      : minHeightCm;

  static int clampAge(int value) => value.clamp(minAge, maxAge);

  double weightKg;
  double heightCm;
  int age;
  List<Bike> garage;
  Bike? selectedBike;
  String username;
  String status;
  String city;
  RidingType preferredRidingType;
  int avatarIndex;

  /// Пол: 'male' / 'female' / null (не указан). Виден друзьям,
  /// если не скрыт настройкой приватности [showGender].
  String? gender;

  /// Приватность: что показывать другим райдерам в публичном профиле.
  /// По умолчанию всё видно — скрытие опционально.
  bool showWeight;
  bool showAge;
  bool showGender;

  /// Путь к локальному файлу пользовательского фото профиля.
  /// `null` — используется иконка из встроенного набора [avatarIndex].
  String? photoPath;

  /// Публичный URL аватара в Supabase Storage (бакет `avatars`).
  /// Локальный файл быстрее и работает офлайн, поэтому UI предпочитает
  /// [photoPath], а [avatarUrl] нужен для синхронизации между устройствами.
  String? avatarUrl;

  /// Пресет интерфейса: 'laconic' / 'athlete' / 'gamer' / 'urban'.
  /// `null` — пресет ещё не выбран (трактуется как «Лаконичный»);
  /// так живут все профили, созданные до появления онбординга.
  String? uiPreset;

  /// Включённые модули интерфейса (id из UiModules). Заполняется набором
  /// пресета при его выборе и далее правится переключателями в Настройках.
  /// `null` — модули ещё не настроены; UI должен вывести набор пресета.
  Set<String>? modulesEnabled;

  UserProfile({
    required this.weightKg,
    required this.heightCm,
    required this.age,
    List<Bike>? garage,
    this.selectedBike,
    this.username = 'Райдер',
    this.status = 'Начинающий',
    this.city = 'Не указан',
    this.preferredRidingType = RidingType.road,
    this.avatarIndex = 0,
    this.gender,
    this.showWeight = false,
    this.showAge = false,
    this.showGender = false,
    this.photoPath,
    this.avatarUrl,
    this.uiPreset,
    Set<String>? modulesEnabled,
  }) : garage = garage ?? [],
       modulesEnabled = modulesEnabled == null ? null : Set.of(modulesEnabled);

  Map<String, dynamic> toJson() => {
    'weightKg': weightKg,
    'heightCm': heightCm,
    'age': age,
    'garage': garage.map((bike) => bike.toJson()).toList(),
    'selectedBike': selectedBike?.toJson(),
    'username': username,
    'status': status,
    'city': city,
    // По имени — та же причина, что и у типа велосипеда выше.
    'preferredRidingType': preferredRidingType.name,
    'avatarIndex': avatarIndex,
    'gender': gender,
    'showWeight': showWeight,
    'showAge': showAge,
    'showGender': showGender,
    'photoPath': photoPath,
    'avatarUrl': avatarUrl,
    'uiPreset': uiPreset,
    'modulesEnabled': modulesEnabled?.toList(),
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final garage =
        (json['garage'] as List<dynamic>?)
            ?.map((item) => Bike.fromJson(item as Map<String, dynamic>))
            .toList() ??
        [];
    final selectedBikeJson = json['selectedBike'];
    Bike? selectedBike;
    if (selectedBikeJson != null) {
      selectedBike = Bike.fromJson(selectedBikeJson as Map<String, dynamic>);
    }
    return UserProfile(
      // Значения из хранилища тоже прогоняем через границы: если в старом
      // профиле лежит 148852 кг, он не попадёт ни в UI, ни в расчёты.
      weightKg: clampWeight((json['weightKg'] as num).toDouble()),
      heightCm: clampHeight((json['heightCm'] as num).toDouble()),
      age: clampAge(json['age'] as int),
      garage: garage,
      selectedBike: selectedBike,
      username: json['username'] as String? ?? 'Райдер',
      status: json['status'] as String? ?? 'Начинающий',
      city: json['city'] as String? ?? 'Не указан',
      preferredRidingType: _ridingTypeFromJson(json['preferredRidingType']),
      avatarIndex: json['avatarIndex'] as int? ?? 0,
      gender: json['gender'] as String?,
      showWeight: json['showWeight'] as bool? ?? false,
      showAge: json['showAge'] as bool? ?? false,
      showGender: json['showGender'] as bool? ?? false,
      photoPath: json['photoPath'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      uiPreset: json['uiPreset'] as String?,
      modulesEnabled: (json['modulesEnabled'] as List<dynamic>?)
          ?.map((item) => item as String)
          .toSet(),
    );
  }

  /// Имя типа — новый формат; числовой индекс — легаси.
  static RidingType _ridingTypeFromJson(Object? value) {
    if (value is String) {
      for (final type in RidingType.values) {
        if (type.name == value) return type;
      }
    }
    if (value is int && value >= 0 && value < RidingType.values.length) {
      return RidingType.values[value];
    }
    return RidingType.road;
  }

  UserProfile copyWith({
    double? weightKg,
    double? heightCm,
    int? age,
    List<Bike>? garage,
    Bike? selectedBike,
    String? username,
    String? status,
    String? city,
    RidingType? preferredRidingType,
    int? avatarIndex,
    String? gender,
    bool? showWeight,
    bool? showAge,
    bool? showGender,
    String? photoPath,
    String? avatarUrl,
    bool clearPhoto = false,
    String? uiPreset,
    Set<String>? modulesEnabled,
  }) {
    return UserProfile(
      weightKg: weightKg ?? this.weightKg,
      heightCm: heightCm ?? this.heightCm,
      age: age ?? this.age,
      garage: garage ?? this.garage,
      selectedBike: selectedBike ?? this.selectedBike,
      username: username ?? this.username,
      status: status ?? this.status,
      city: city ?? this.city,
      preferredRidingType: preferredRidingType ?? this.preferredRidingType,
      avatarIndex: avatarIndex ?? this.avatarIndex,
      gender: gender ?? this.gender,
      showWeight: showWeight ?? this.showWeight,
      showAge: showAge ?? this.showAge,
      showGender: showGender ?? this.showGender,
      // Отдельный флаг нужен, чтобы можно было именно ОЧИСТИТЬ фото
      // (обычный `photoPath ?? this.photoPath` не отличит null от «не задано»).
      photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
      // Вместе с локальным фото убираем и ссылку на облачный аватар.
      avatarUrl: clearPhoto ? null : (avatarUrl ?? this.avatarUrl),
      uiPreset: uiPreset ?? this.uiPreset,
      modulesEnabled: modulesEnabled == null
          ? this.modulesEnabled
          : Set.of(modulesEnabled),
    );
  }
}
