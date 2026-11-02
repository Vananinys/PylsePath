import 'package:flutter/material.dart';

/// Screen-aligned speed beside a map avatar; missing GPS is never shown as zero.
class MapSpeedBadge extends StatelessWidget {
  const MapSpeedBadge({super.key, required this.speed});
  final double? speed;

  @override
  Widget build(BuildContext context) {
    final valid = speed != null && speed!.isFinite && speed! >= 0;
    final value = valid ? speed!.toStringAsFixed(0) : '—';
    if (!valid) return const SizedBox.shrink();
    return Semantics(
      label: valid ? 'Скорость $value километров в час' : 'Скорость неизвестна',
      child: Container(
        constraints: const BoxConstraints(minWidth: 28, maxWidth: 44),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: const Color(0xFFD5DADD), width: .5),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  textScaler: TextScaler.noScaling,
                  style: const TextStyle(
                    color: Color(0xFF253238),
                    fontSize: 10,
                    height: 1.1,
                  ),
                ),
                const Text(
                  ' км/ч',
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(color: Color(0xFF253238), fontSize: 8),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
