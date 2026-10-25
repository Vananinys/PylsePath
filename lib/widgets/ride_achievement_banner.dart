import 'dart:async';

import 'package:flutter/material.dart';

import '../services/achievement_journey.dart';

class AchievementBannerController extends ChangeNotifier {
  List<JourneyMedal> medals = const [];
  Timer? _timer;
  void show(List<JourneyMedal> newlyEarned) {
    if (newlyEarned.isEmpty) return;
    medals = List.unmodifiable(newlyEarned);
    _timer?.cancel();
    notifyListeners();
    _timer = Timer(const Duration(seconds: 6), dismiss);
  }

  void dismiss() {
    _timer?.cancel();
    medals = const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// The only in-app notification banner: an achievement milestone during a ride.
class RideAchievementBanner extends StatelessWidget {
  const RideAchievementBanner({super.key, required this.controller});
  final AchievementBannerController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 280),
      child: controller.medals.isEmpty
          ? const SizedBox.shrink()
          : Semantics(
              liveRegion: true,
              child: Material(
                key: ValueKey(controller.medals.first.id),
                elevation: 8,
                color: const Color(0xFF15372F),
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
                  child: Row(
                    children: [
                      Text(
                        controller.medals.first.badge.icon,
                        style: const TextStyle(fontSize: 36),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'НОВЫЙ РУБЕЖ',
                              style: TextStyle(
                                color: Color(0xFFBFE5AE),
                                fontSize: 10,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              controller.medals.length == 1
                                  ? controller.medals.first.badge.title
                                  : '${controller.medals.length} новых достижений',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            const Text(
                              'Награда сохранится вместе с заездом',
                              style: TextStyle(
                                color: Color(0xFFC8D8D1),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: controller.dismiss,
                        tooltip: 'Скрыть',
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    ),
  );
}
