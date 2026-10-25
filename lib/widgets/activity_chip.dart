import 'package:flutter/material.dart';

import '../models/activity_type.dart';

class ActivityChip extends StatelessWidget {
  final ActivityType activity;
  final bool isSelected;
  final bool isDarkMode;
  final VoidCallback onTap;

  const ActivityChip({
    super.key,
    required this.activity,
    required this.isSelected,
    required this.isDarkMode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.deepOrange
              : (isDarkMode ? Colors.grey.shade800 : const Color(0xFFF6F7F9)),
          borderRadius: BorderRadius.circular(14),
          border: isSelected
              ? null
              : Border.all(
                  color: isDarkMode
                      ? Colors.grey.shade700
                      : Colors.grey.shade300,
                  width: 1,
                ),
        ),
        child: Row(
          children: [
            Icon(
              activity.icon,
              size: 18,
              color: isSelected
                  ? Colors.white
                  : (isDarkMode ? Colors.white : Colors.black87),
            ),
            const SizedBox(width: 6),
            Text(
              activity.label,
              style: TextStyle(
                color: isSelected
                    ? Colors.white
                    : (isDarkMode ? Colors.white : Colors.black87),
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
