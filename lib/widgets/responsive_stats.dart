import 'package:flutter/material.dart';

/// Metrics keep their text size and wrap to another row on narrow displays.
class ResponsiveStats extends StatelessWidget {
  const ResponsiveStats({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      final columns = (constraints.maxWidth / (140 * scale)).floor().clamp(
        1,
        4,
      );
      final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final child in children)
            if (child is! SizedBox)
              SizedBox(
                width: width,
                child: child is Expanded ? child.child : child,
              ),
        ],
      );
    },
  );
}
