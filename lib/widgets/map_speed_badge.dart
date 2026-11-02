import 'package:flutter/material.dart';

/// Screen-aligned speed beside a map avatar; missing GPS is never shown as zero.
class MapSpeedBadge extends StatelessWidget {
  const MapSpeedBadge({super.key, required this.speed});
  final double? speed;

  @override
  Widget build(BuildContext context) {
    final valid = speed != null && speed!.isFinite && speed! >= 0;
    final value = valid ? speed!.toStringAsFixed(0) : '—';
    return Semantics(
      label: valid ? 'Скорость $value километров в час' : 'Скорость неизвестна',
      child: Container(
        width: 36,
        padding: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFF595959),
          borderRadius: BorderRadius.circular(9),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
        ),
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                textScaler: TextScaler.noScaling,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  height: 1.1,
                ),
              ),
              const Text(
                'км/ч',
                textScaler: TextScaler.noScaling,
                style: TextStyle(color: Colors.white, fontSize: 9),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
