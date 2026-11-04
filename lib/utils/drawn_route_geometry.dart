import 'dart:ui';

/// Smooths only a hand-drawn screen gesture, never an imported or recorded track.
/// Resampling bounds corner cutting to a few screen pixels and retains endpoints.
List<Offset> smoothDrawnStroke(List<Offset> input) {
  if (input.length < 3) return List.unmodifiable(input);
  final samples = <Offset>[input.first];
  for (var i = 1; i < input.length && samples.length < 3000; i++) {
    final a = input[i - 1], b = input[i];
    final steps = ((b - a).distance / 4).ceil().clamp(1, 1000);
    for (var j = 1; j <= steps && samples.length < 3000; j++) {
      samples.add(Offset.lerp(a, b, j / steps)!);
    }
  }
  if (samples.last != input.last) return List.unmodifiable(input);
  final result = <Offset>[samples.first];
  for (var i = 1; i < samples.length; i++) {
    result.add(Offset.lerp(samples[i - 1], samples[i], .25)!);
    result.add(Offset.lerp(samples[i - 1], samples[i], .75)!);
  }
  result.add(samples.last);
  return List.unmodifiable(result);
}
