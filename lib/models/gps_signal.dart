enum GpsQuality { searching, good, weak, lost }

class GpsSignal {
  const GpsSignal({
    this.accuracy,
    this.updatedAt,
    this.unavailable = false,
    this.stale = false,
  });

  final double? accuracy;
  final DateTime? updatedAt;
  final bool unavailable;
  final bool stale;

  GpsQuality get quality {
    if (unavailable || stale) return GpsQuality.lost;
    if (updatedAt == null) return GpsQuality.searching;
    final meters = accuracy;
    return meters != null && meters.isFinite && meters >= 0 && meters <= 20
        ? GpsQuality.good
        : GpsQuality.weak;
  }

  GpsSignal checkedAt(DateTime now) => GpsSignal(
    accuracy: accuracy,
    updatedAt: updatedAt,
    unavailable: unavailable,
    stale:
        updatedAt != null &&
        now.difference(updatedAt!) >= const Duration(seconds: 30),
  );
}
