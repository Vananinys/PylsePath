/// Personal estimates for this bicycle. Stored inside drivetrain.setup so old
/// bicycles and old application versions can still read their gear ratios.
class BikeSetup {
  const BikeSetup({
    this.cargoKg = 0,
    this.posture = 'touring',
    this.tyres = 'mixed',
    this.assistance = 'light',
    this.frameColor = 0xfffc5b22,
    this.diagram = 'auto',
    this.maintenanceReminders = true,
    this.transmission = 'auto',
    this.brakes = 'disc',
    this.frontBrake,
    this.rearBrake,
    this.frontRotorMm = 180,
    this.rearRotorMm = 160,
    this.frontPadMaterial = 'unknown',
    this.rearPadMaterial = 'unknown',
    this.fork = 'auto',
    this.deepRims = false,
    this.showLabels = false,
    this.accessories = const [],
  });
  final double cargoKg;
  final String posture, tyres, assistance;
  final int frameColor;
  final String diagram;
  final bool maintenanceReminders;
  final String transmission, brakes, fork;

  /// Nullable overrides preserve the common brake setting of older bicycles.
  final String? frontBrake, rearBrake;
  final int frontRotorMm, rearRotorMm;
  final String frontPadMaterial, rearPadMaterial;
  String brakeType(bool front) => (front ? frontBrake : rearBrake) ?? brakes;
  int rotorMm(bool front) => front ? frontRotorMm : rearRotorMm;
  String padMaterial(bool front) => front ? frontPadMaterial : rearPadMaterial;
  final bool deepRims, showLabels;
  final List<String> accessories;
  static const transmissions = {
    'auto': 'По настройкам передач',
    'geared': 'С переключателями и кассетой',
    'single': 'Одна передача',
  };
  static const brakeTypes = {'disc': 'Дисковые', 'rim': 'Ободные'};
  static const individualBrakeTypes = {
    'disc': 'Дисковые · тип не указан',
    'mechanical': 'Дисковые · механика',
    'hydraulic': 'Дисковые · гидравлика',
    'rim': 'Ободные',
    'coaster': 'Ножной / втулочный',
    'none': 'Не установлен',
  };
  static const rotorSizes = [140, 160, 180, 183, 185, 200, 203, 220, 223];
  static const padMaterials = {
    'unknown': 'Не указано',
    'resin': 'Органика / resin',
    'metal': 'Металл / sintered',
    'semi': 'Полуметалл',
  };
  static bool isDisc(String type) =>
      ['disc', 'mechanical', 'hydraulic'].contains(type);
  static const forkTypes = {
    'auto': 'По типу велосипеда',
    'rigid': 'Жёсткая',
    'suspension': 'Амортизационная',
  };
  static const accessoryTypes = {
    'bottle_cage': 'Фляга и держатель',
    'rack': 'Багажник',
    'lights': 'Фонари',
    'mudguards': 'Крылья',
  };
  static const diagrams = {
    'auto': 'По типу велосипеда',
    'gravel': 'Гревел',
    'hardtail': 'МТБ · хардтейл',
    'enduro': 'МТБ · эндуро',
    'road': 'Шоссейник',
  };
  static const postures = {
    'upright': 'Прямая посадка',
    'touring': 'Обычная посадка',
    'sport': 'Спортивная посадка',
  };
  static const tyreTypes = {
    'slick': 'Гладкие',
    'mixed': 'Универсальные',
    'knobby': 'Грунтовые / МТБ',
  };
  static const assistModes = {
    'off': 'Помощь выключена',
    'light': 'Небольшая помощь',
    'high': 'Сильная помощь',
  };
  static const colors = [
    0xfffc5b22,
    0xff00897b,
    0xff1976d2,
    0xff7b1fa2,
    0xffd32f2f,
    0xff424242,
    0xff687448,
  ];
  double get cda => switch (posture) {
    'upright' => .60,
    'sport' => .32,
    _ => .45,
  };
  double get crr => switch (tyres) {
    'slick' => .005,
    'knobby' => .012,
    _ => .008,
  };
  Map<String, dynamic> toJson() => {
    'cargo_kg': cargoKg,
    'posture': posture,
    'tyres': tyres,
    'assistance': assistance,
    'frame_color': frameColor,
    'diagram': diagram,
    'maintenance_reminders': maintenanceReminders,
    'transmission': transmission,
    'brakes': brakes,
    'front_brake': frontBrake,
    'rear_brake': rearBrake,
    'front_rotor_mm': frontRotorMm,
    'rear_rotor_mm': rearRotorMm,
    'front_pad_material': frontPadMaterial,
    'rear_pad_material': rearPadMaterial,
    'fork': fork,
    'deep_rims': deepRims,
    'show_labels': showLabels,
    'accessories': accessories,
  };
  factory BikeSetup.fromJson(dynamic raw) {
    final v = raw is Map ? raw : const {};
    final cargo = v['cargo_kg'];
    return BikeSetup(
      diagram: diagrams.containsKey(v['diagram'])
          ? v['diagram'] as String
          : 'auto',
      maintenanceReminders: v['maintenance_reminders'] != false,
      transmission: transmissions.containsKey(v['transmission'])
          ? v['transmission'] as String
          : 'auto',
      brakes: brakeTypes.containsKey(v['brakes'])
          ? v['brakes'] as String
          : 'disc',
      frontBrake:
          individualBrakeTypes.containsKey(v['front_brake']) &&
              v['front_brake'] != 'coaster'
          ? v['front_brake'] as String
          : null,
      rearBrake: individualBrakeTypes.containsKey(v['rear_brake'])
          ? v['rear_brake'] as String
          : null,
      frontRotorMm: rotorSizes.contains(v['front_rotor_mm'])
          ? (v['front_rotor_mm'] as num).toInt()
          : 180,
      rearRotorMm: rotorSizes.contains(v['rear_rotor_mm'])
          ? (v['rear_rotor_mm'] as num).toInt()
          : 160,
      frontPadMaterial: padMaterials.containsKey(v['front_pad_material'])
          ? v['front_pad_material'] as String
          : 'unknown',
      rearPadMaterial: padMaterials.containsKey(v['rear_pad_material'])
          ? v['rear_pad_material'] as String
          : 'unknown',
      fork: forkTypes.containsKey(v['fork']) ? v['fork'] as String : 'auto',
      deepRims: v['deep_rims'] == true,
      showLabels: v['show_labels'] == true,
      accessories:
          (v['accessories'] is List ? v['accessories'] as List : const [])
              .whereType<String>()
              .where(accessoryTypes.containsKey)
              .toSet()
              .toList(),
      cargoKg: cargo is num && cargo.isFinite
          ? cargo.toDouble().clamp(0, 60)
          : 0,
      posture: postures.containsKey(v['posture'])
          ? v['posture'] as String
          : 'touring',
      tyres: tyreTypes.containsKey(v['tyres']) ? v['tyres'] as String : 'mixed',
      assistance: assistModes.containsKey(v['assistance'])
          ? v['assistance'] as String
          : 'light',
      frameColor: colors.contains(v['frame_color'])
          ? v['frame_color'] as int
          : colors.first,
    );
  }
}

class BikePartTemplate {
  const BikePartTemplate(this.id, this.name, this.category, this.x, this.y);
  final String id, name, category;
  final double x, y;
  static const categories = [
    'Трансмиссия',
    'Колёса',
    'Тормоза',
    'Подвеска',
    'Кокпит',
    'Аксессуары',
  ];
  static const all = [
    BikePartTemplate('chain', 'Цепь', 'Трансмиссия', .38, .69),
    BikePartTemplate('cassette', 'Кассета', 'Трансмиссия', .22, .64),
    BikePartTemplate('chainrings', 'Передние звёзды', 'Трансмиссия', .49, .65),
    BikePartTemplate('cranks', 'Шатуны', 'Трансмиссия', .53, .70),
    BikePartTemplate('bottom_bracket', 'Каретка', 'Трансмиссия', .49, .64),
    BikePartTemplate(
      'rear_derailleur',
      'Задний переключатель',
      'Трансмиссия',
      .25,
      .76,
    ),
    BikePartTemplate(
      'front_derailleur',
      'Передний переключатель',
      'Трансмиссия',
      .46,
      .53,
    ),
    BikePartTemplate('pedals', 'Педали', 'Трансмиссия', .58, .73),
    BikePartTemplate('front_tyre', 'Передняя покрышка', 'Колёса', .88, .74),
    BikePartTemplate('rear_tyre', 'Задняя покрышка', 'Колёса', .12, .74),
    BikePartTemplate('front_wheel', 'Переднее колесо', 'Колёса', .80, .64),
    BikePartTemplate('rear_wheel', 'Заднее колесо', 'Колёса', .20, .64),
    BikePartTemplate(
      'front_tube',
      'Передняя камера / герметик',
      'Колёса',
      .86,
      .50,
    ),
    BikePartTemplate(
      'rear_tube',
      'Задняя камера / герметик',
      'Колёса',
      .14,
      .50,
    ),
    BikePartTemplate('front_brake', 'Передний тормоз', 'Тормоза', .75, .53),
    BikePartTemplate('rear_brake', 'Задний тормоз', 'Тормоза', .26, .53),
    BikePartTemplate('brakes', 'Тормоза', 'Тормоза', .75, .53),
    BikePartTemplate('front_pads', 'Передние колодки', 'Тормоза', .76, .60),
    BikePartTemplate('rear_pads', 'Задние колодки', 'Тормоза', .24, .60),
    BikePartTemplate('fork', 'Вилка', 'Подвеска', .72, .42),
    BikePartTemplate('shock', 'Задний амортизатор', 'Подвеска', .49, .43),
    BikePartTemplate('headset', 'Рулевая колонка', 'Кокпит', .65, .29),
    BikePartTemplate('handlebar', 'Руль и грипсы', 'Кокпит', .68, .17),
    BikePartTemplate('stem', 'Вынос', 'Кокпит', .64, .21),
    BikePartTemplate('saddle', 'Седло', 'Кокпит', .39, .23),
    BikePartTemplate('seatpost', 'Подседельный штырь', 'Кокпит', .41, .34),
    BikePartTemplate('frame', 'Рама', 'Кокпит', .54, .36),
    BikePartTemplate('battery', 'Аккумулятор', 'Аксессуары', .59, .47),
    BikePartTemplate('lights', 'Фонари', 'Аксессуары', .72, .23),
    BikePartTemplate('rack', 'Багажник', 'Аксессуары', .25, .36),
    BikePartTemplate(
      'front_rotor',
      'Передний тормозной диск',
      'Тормоза',
      .78,
      .66,
    ),
    BikePartTemplate(
      'rear_rotor',
      'Задний тормозной диск',
      'Тормоза',
      .20,
      .66,
    ),
    BikePartTemplate('front_hub', 'Передняя втулка', 'Колёса', .79, .66),
    BikePartTemplate('rear_hub', 'Задняя втулка', 'Колёса', .20, .66),
    BikePartTemplate('dropper', 'Дроппер', 'Кокпит', .40, .35),
    BikePartTemplate('grips', 'Грипсы / обмотка', 'Кокпит', .72, .25),
    BikePartTemplate('shifters', 'Манетки / дуалы', 'Трансмиссия', .71, .26),
    BikePartTemplate('bottle_cage', 'Флягодержатель', 'Аксессуары', .56, .48),
    BikePartTemplate('mudguards', 'Крылья', 'Аксессуары', .80, .42),
    BikePartTemplate('custom', 'Своя деталь', 'Аксессуары', .50, .50),
  ];
  static BikePartTemplate find(String id) =>
      all.where((t) => t.id == id).firstOrNull ?? all.last;
}
