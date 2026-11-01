import 'package:flutter/material.dart';

/// A readable introduction that grows with system text instead of clipping it.
class SectionIntro extends StatelessWidget {
  const SectionIntro({
    super.key,
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.description,
    this.trailing,
    this.children = const [],
    this.compact = false,
  });
  final IconData icon;
  final String eyebrow, title, description;
  final Widget? trailing;
  final List<Widget> children;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: colors.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  eyebrow,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: colors.primary),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          SizedBox(height: compact ? 8 : 16),
          Text(
            title,
            style:
                (compact
                        ? Theme.of(context).textTheme.titleLarge
                        : Theme.of(context).textTheme.headlineSmall)
                    ?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          if (children.isNotEmpty) ...[const SizedBox(height: 16), ...children],
        ],
      ),
    );
  }
}

class SectionStep extends StatelessWidget {
  const SectionStep({
    super.key,
    required this.number,
    required this.title,
    required this.description,
  });
  final int number;
  final String title, description;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 16,
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text(
            '$number',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 3),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
