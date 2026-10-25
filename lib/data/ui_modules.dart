import 'package:flutter/material.dart';

import '../models/user_profile.dart';

/// Реестр модулей интерфейса (Этап 0 мастер-плана).
///
/// Каждый пункт дровера — модуль с флагом вкл/выкл. Набор включённых
/// модулей задаётся пресетом при онбординге и правится в Настройках;
/// хранится в профиле ([UserProfile.modulesEnabled]) и синхронизируется
/// с облаком как обычное поле профиля.
abstract final class UiModules {
  /// Псевдо-модуль «летающие стикеры на карте»: флаг без пункта дровера.
  static const String stickers = 'stickers';

  /// Псевдо-модуль «городской»: micro-reports на карте, слой парковок,
  /// счётчик светофоров на маршруте. Без пункта дровера.
  static const String urban = 'urban';

  /// Модули, доступные в виде пунктов дровера (в порядке показа).
  static const List<UiModule> drawerModules = [
    UiModule('saved_routes', 'Сохранённые маршруты', Icons.bookmark_border),
    UiModule('chats', 'Сообщения', Icons.chat_bubble_outline),
    UiModule('community', 'Сообщество', Icons.groups_2_outlined),
    UiModule('history', 'Тренировочный центр и история', Icons.history),
    UiModule('achievements', 'Достижения', Icons.emoji_events_outlined),
    UiModule('heatmap', 'Тепловая карта', Icons.local_fire_department_outlined),
    UiModule('offline_maps', 'Офлайн-карты', Icons.map_outlined),
    UiModule(
      'group_rides',
      'Совместная заездка',
      Icons.directions_bike_outlined,
    ),
    UiModule('garage', 'Мой гараж', Icons.pedal_bike_outlined),
  ];

  static const optionalModules = [
    ...drawerModules,
    UiModule(stickers, 'Стикеры на карте', Icons.emoji_emotions_outlined),
    UiModule(urban, 'Городские инструменты', Icons.location_city_outlined),
  ];

  static const groups = {
    'Маршруты и тренировки': [
      'history',
      'saved_routes',
      'heatmap',
      'offline_maps',
      'garage',
    ],
    'Друзья и общение': ['chats', 'community', 'group_rides', stickers],
    'Мотивация и город': ['achievements', urban],
  };
  static const descriptions = {
    'history': 'Календарь, история тренировок, динамика нагрузки и личные цели. Здесь же детали, круги, шаги и аналитика сохранённых занятий.',
    'saved_routes': 'Избранные маршруты и импорт GPX для следующей прогулки или заезда. Для построения маршрута по дорогам нужен интернет.',
    'heatmap': 'Где вы уже тренировались: фильтры по времени и активности, личный след и популярные участки. Публикация маршрутов настраивается отдельно.',
    'offline_maps': 'Загрузка участков карты перед поездкой без интернета. Скачанная карта не заменяет интернет для поиска и построения нового маршрута.',
    'garage': 'Ваши велосипеды, комплектация и вес для расчётов энергии. Подсказка передачи включается отдельно в помощниках тренировки.',
    'chats': 'Личные сообщения друзьям. Звук, содержимое на экране блокировки и разрешения задаются в системных уведомлениях телефона.',
    'community': 'Публикации, комментарии, друзья и их профили. Передача вашей геопозиции управляется отдельно в приватности.',
    'group_rides': 'Планирование совместных поездок, приглашения и участники. Для общения и обновления данных нужен интернет.',
    'achievements': 'Медали, XP, титулы пути, цели недели и награды за шаги в тренировках. Огонёк отражает регулярность; прогресс сохраняется при скрытом разделе.',
    'stickers': 'Эмодзи друзьям прямо на карте. Это короткие реакции; личный чат включается отдельным модулем.',
    'urban': 'Парковки, отметки проблем и светофоры на маршруте. Набор доступных объектов зависит от данных карты.',
  };

  /// Все известные id, включая псевдо-модули без пункта дровера.
  static Set<String> get allIds => {
    for (final module in drawerModules) module.id,
    stickers,
    urban,
  };

  static String? titleOf(String id) {
    for (final module in drawerModules) {
      if (module.id == id) return module.title;
    }
    return optionalModules
        .where((module) => module.id == id)
        .firstOrNull
        ?.title;
  }
}

class UiModule {
  final String id;
  final String title;
  final IconData icon;

  const UiModule(this.id, this.title, this.icon);
}

/// Пресеты интерфейса. [laconic] — дефолт: и для существующих пользователей
/// (ui_preset IS NULL), и как начальный выбор онбординга.
enum UiPreset {
  laconic(
    'laconic',
    'Лаконичный',
    '✨',
    'Тренировки, календарь и история. Остальные разделы скрыты.',
  ),
  athlete(
    'athlete',
    'Спортсмен',
    '🎯',
    'История, маршруты, гараж, достижения и офлайн-карты.',
  ),
  gamer(
    'gamer',
    'Геймер',
    '🎮',
    'Все разделы меню, стикеры и городские инструменты.',
  ),
  urban('urban', 'Город', '🏙️', 'Чаты, сообщество и совместные заездки.');

  final String id;
  final String title;
  final String emoji;
  final String description;

  const UiPreset(this.id, this.title, this.emoji, this.description);

  /// Модули, включаемые пресетом. `history` есть во всех — базовая функция.
  Set<String> get modules {
    switch (this) {
      case laconic:
        return {'history'};
      case athlete:
        return {
          'saved_routes',
          'history',
          'achievements',
          'offline_maps',
          'garage',
        };
      case gamer:
        return UiModules.allIds;
      case urban:
        return {'history', 'chats', 'community', 'group_rides'};
    }
  }

  static UiPreset fromId(String? id) {
    for (final preset in UiPreset.values) {
      if (preset.id == id) return preset;
    }
    return laconic;
  }
}

/// Разрешение флагов модулей: явный набор профиля приоритетнее,
/// при его отсутствии — набор пресета (null-пресет = Лаконичный).
Set<String> effectiveEnabledModules(UserProfile profile) {
  final manual = profile.modulesEnabled;
  if (manual != null) return manual;
  return UiPreset.fromId(profile.uiPreset).modules;
}
