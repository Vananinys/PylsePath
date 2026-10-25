import 'package:flutter/material.dart';

/// Shared PulsePath brand mark used in the app's identity screens.
class PulsePathLogo extends StatelessWidget {
  const PulsePathLogo({super.key, this.size = 88, this.radius = 22});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.deepOrange.withValues(alpha: 0.24),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/branding/pulsepath_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        semanticLabel: 'Логотип PulsePath',
      ),
    );
  }
}
