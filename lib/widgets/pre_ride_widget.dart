import 'package:flutter/material.dart';

import '../controllers/map_navigation_controller.dart' show SportMode;
import '../models/vehicle.dart';
import 'vehicle_selector_sheet.dart';

/// Панель подготовки к заезду (Pre-Ride / Start HUD).
///
/// Открывается по кнопке «Свободный заезд» в нижней панели карты и закрывается
/// стрелкой в заголовке. Внутри:
///  1) чип выбранной техники из Гаража (открывает [VehicleSelectorSheet]);
///  2) быстрые тумблеры: «Автопауза» и «Электропривод (E-bike)»;
///  3) крупная кнопка «ПОЕХАЛИ» — старт записи трека.
///
/// Стиль — общий светлый стиль приложения (белая карточка, серые подписи,
/// фирменный deepOrange-акцент), как у остальных шторок карты.
class PreRideWidget extends StatelessWidget {
  static const Color _accent = Color(0xFFFF6D1F);

  final Vehicle? selectedVehicle;
  final VoidCallback onSelectVehicle;
  final bool autoPauseEnabled;
  final ValueChanged<bool> onAutoPauseChanged;

  /// Вид тренировки: на технике из гаража, пешком или бегом.
  final SportMode sportMode;
  final ValueChanged<SportMode> onSportModeChanged;
  final VoidCallback onStartRide;

  /// Свернуть панель обратно в нижнюю панель карты (стрелка вниз в заголовке).
  final VoidCallback onCollapse;

  /// Блокировка экрана: панель только для чтения.
  final bool isLocked;

  final Widget? preparation;
  final String? routeLabel;
  final Widget? readiness;
  final String? settingsSummary;
  final VoidCallback? onPlanRoute;

  const PreRideWidget({
    super.key,
    required this.selectedVehicle,
    required this.onSelectVehicle,
    required this.autoPauseEnabled,
    required this.onAutoPauseChanged,
    required this.sportMode,
    required this.onSportModeChanged,
    required this.onStartRide,
    required this.onCollapse,
    this.isLocked = false,
    this.preparation,
    this.routeLabel,
    this.readiness,
    this.settingsSummary,
    this.onPlanRoute,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: _buildHeader(),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (routeLabel != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF1E8),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.route, color: _accent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                routeLabel!.startsWith('Точка на карте')
                                    ? 'До выбранной точки на карте'
                                    : 'По маршруту: $routeLabel',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    _buildSportModeRow(),
                    if (sportMode == SportMode.vehicle) ...[
                      const SizedBox(height: 10),
                      _buildVehicleChip(),
                    ],
                    if (readiness != null) ...[
                      const SizedBox(height: 10),
                      Align(alignment: Alignment.centerLeft, child: readiness!),
                    ],
                    if (routeLabel == null && onPlanRoute != null)
                      TextButton.icon(
                        onPressed: isLocked ? null : onPlanRoute,
                        icon: const Icon(Icons.route_outlined, size: 18),
                        label: const Text('Добавить маршрут'),
                      ),
                    const SizedBox(height: 8),
                    ExpansionTile(
                      key: const PageStorageKey('pre-ride-options'),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      leading: const Icon(Icons.tune, size: 22),
                      title: const Text('Настройки тренировки'),
                      subtitle: Text(
                        settingsSummary ??
                            (autoPauseEnabled
                                ? 'Автопауза включена · цель, интервалы и доступ'
                                : 'Автопауза выключена · цель, интервалы и доступ'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      children: [
                        _buildQuickToggles(),
                        if (preparation != null) preparation!,
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: _buildStartButton(),
            ),
          ],
        ),
      ),
    );
  }

  /// Заголовок: подпись и кнопка «свернуть» вниз.
  Widget _buildHeader() {
    return Row(
      children: [
        const Icon(Icons.directions_bike, size: 18, color: _accent),
        const SizedBox(width: 6),
        const Expanded(
          child: Text(
            'Подготовка к тренировке',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
        ),
        // Свернуть панель обратно в нижнюю панель карты.
        Tooltip(
          message: 'Свернуть',
          child: InkResponse(
            onTap: isLocked ? null : onCollapse,
            radius: 20,
            child: const Icon(
              Icons.keyboard_arrow_down,
              size: 26,
              color: Colors.grey,
            ),
          ),
        ),
      ],
    );
  }

  /// Чип техники: [ 🚴 Название (29") ▾ ]
  Widget _buildVehicleChip() {
    final vehicle = selectedVehicle;
    return Material(
      color: Colors.grey.shade50,
      borderRadius: BorderRadius.circular(30),
      child: InkWell(
        onTap: isLocked ? null : onSelectVehicle,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: vehicle == null ? Colors.grey.shade300 : _accent,
              width: vehicle == null ? 1 : 1.5,
            ),
          ),
          child: Row(
            children: [
              _VehicleChipAvatar(vehicle: vehicle),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  vehicle == null
                      ? 'Выбрать технику'
                      : '${vehicle.name}'
                            '${vehicle.wheelSize > 0 ? ' (${vehicle.wheelSize.toStringAsFixed(0)}")' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              const Icon(
                Icons.keyboard_arrow_down,
                color: Colors.grey,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Выбор сначала делит тренировку на занятия на технике и на ногах.
  Widget _buildSportModeRow() {
    final onFoot = sportMode != SportMode.vehicle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _SportChip(
                icon: Icons.directions_bike,
                label: 'На транспорте',
                selected: !onFoot,
                enabled: !isLocked,
                onTap: () => onSportModeChanged(SportMode.vehicle),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SportChip(
                icon: Icons.directions_walk,
                label: 'На ногах',
                selected: onFoot,
                enabled: !isLocked,
                onTap: () => onSportModeChanged(SportMode.walking),
              ),
            ),
          ],
        ),
        if (onFoot) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: SportMode.values.length - 1,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final mode = SportMode.values[index + 1];
                final icon = switch (mode) {
                  SportMode.running ||
                  SportMode.trailRunning => Icons.directions_run,
                  SportMode.nordicWalking || SportMode.trekking => Icons.hiking,
                  _ => Icons.directions_walk,
                };
                return _SportChip(
                  icon: icon,
                  label: mode.label,
                  selected: sportMode == mode,
                  enabled: !isLocked,
                  onTap: () => onSportModeChanged(mode),
                  compact: true,
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  /// Автопауза полезна для всех видов тренировок.
  Widget _buildQuickToggles() {
    return _PreRideToggle(
      icon: Icons.motion_photos_paused,
      label: 'Автопауза',
      value: autoPauseEnabled,
      enabled: !isLocked,
      onChanged: onAutoPauseChanged,
    );
  }

  /// Крупная кнопка старта с фирменным градиентом.
  Widget _buildStartButton() {
    return Opacity(
      opacity: isLocked ? 0.45 : 1.0,
      child: Material(
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        color: Colors.transparent,
        child: Ink(
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(
              colors: [Color(0xFFFF8A3D), _accent],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: isLocked ? 0 : 0.4),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: InkWell(
            onTap: isLocked ? null : onStartRide,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'НАЧАТЬ',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2.0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Пилюля-тумблер в стиле приложения: активная — залита фирменным акцентом
/// с оранжевой рамкой, неактивная — светло-серая с серой рамкой.
class _PreRideToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _PreRideToggle({
    required this.icon,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final Color background = value
        ? PreRideWidget._accent.withValues(alpha: 0.1)
        : Colors.grey.shade50;
    final Color borderColor = value
        ? PreRideWidget._accent
        : Colors.grey.shade300;
    final Color textColor = value ? PreRideWidget._accent : Colors.black45;

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? () => onChanged(!value) : null,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor, width: value ? 1.5 : 1),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: value ? PreRideWidget._accent : Colors.grey,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // Индикатор состояния: заполненная/пустая точка.
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: value ? PreRideWidget._accent : Colors.transparent,
                    border: Border.all(
                      color: value
                          ? PreRideWidget._accent
                          : Colors.grey.shade400,
                      width: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Мини-аватар в чипе техники: фото из облака (если есть), иначе иконка типа.
class _VehicleChipAvatar extends StatelessWidget {
  final Vehicle? vehicle;

  const _VehicleChipAvatar({this.vehicle});

  @override
  Widget build(BuildContext context) {
    final url = vehicle?.photoUrl;
    final hasPhoto =
        url != null &&
        (url.startsWith('http://') || url.startsWith('https://'));
    if (hasPhoto) {
      return CircleAvatar(radius: 12, backgroundImage: NetworkImage(url));
    }
    return Icon(
      vehicle == null
          ? Icons.pedal_bike
          : vehicleIconFor(vehicle!.transportType),
      color: PreRideWidget._accent,
      size: 20,
    );
  }
}

/// Чип выбора вида тренировки — в том же стиле, что и тумблеры панели.
class _SportChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final bool compact;

  const _SportChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color background = selected
        ? PreRideWidget._accent.withValues(alpha: 0.12)
        : Colors.grey.shade50;
    final Color borderColor = selected
        ? PreRideWidget._accent
        : Colors.grey.shade300;
    final Color contentColor = selected
        ? PreRideWidget._accent
        : Colors.black54;

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: compact ? 42 : 46,
            padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
              children: [
                Icon(icon, size: 19, color: contentColor),
                const SizedBox(width: 6),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: contentColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
