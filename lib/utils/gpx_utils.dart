import 'package:latlong2/latlong.dart' hide Path;
import 'package:xml/xml.dart';

class ParsedGpxTrack {
  const ParsedGpxTrack({
    this.points = const [],
    this.segmentStarts = const [],
    this.name = '',
  });
  final List<LatLng> points;
  final List<int> segmentStarts;
  final String name;
}

/// Сборка и разбор GPX-трека.
///
/// Трек хранится в `rides.gpx_data` как обычный XML — так его можно отдать
/// в любой сторонний сервис, а мы читаем из него точки маршрута для истории.
class GpxUtils {
  const GpxUtils._();

  /// Собирает GPX 1.1 с одним треком.
  ///
  /// Точки без времени: у нас нет метки времени на каждую записанную точку,
  /// а выдумывать её хуже, чем не указывать (GPX допускает `<trkpt>` без `<time>`).
  static String build({
    required List<LatLng> points,
    String name = 'PulsePath ride',
    DateTime? createdAt,
    List<int> segmentStarts = const [],
  }) {
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<gpx version="1.1" creator="PulsePath" '
        'xmlns="http://www.topografix.com/GPX/1/1">',
      )
      ..writeln('  <metadata>')
      ..writeln('    <name>${_escape(name)}</name>');
    if (createdAt != null) {
      buffer.writeln('    <time>${createdAt.toUtc().toIso8601String()}</time>');
    }
    buffer
      ..writeln('  </metadata>')
      ..writeln('  <trk>')
      ..writeln('    <name>${_escape(name)}</name>')
      ..writeln('    <trkseg>');

    final starts = segmentStarts
        .where((i) => i > 0 && i < points.length)
        .toSet();
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      if (starts.contains(index)) buffer.writeln('    </trkseg>\n    <trkseg>');
      buffer.writeln(
        '      <trkpt lat="${point.latitude.toStringAsFixed(6)}" '
        'lon="${point.longitude.toStringAsFixed(6)}" />',
      );
    }

    buffer
      ..writeln('    </trkseg>')
      ..writeln('  </trk>')
      ..writeln('</gpx>');

    return buffer.toString();
  }

  /// Достаёт точки трека из GPX через XML-парсер (устойчив к экранированию и
  /// порядку атрибутов, в отличие от регэкспа). Возвращает пустой список,
  /// если данных нет или формат неожиданный — вызывающий код просто покажет
  /// заезд без карты.
  static List<LatLng> parse(String? gpx) {
    return parseTrack(gpx).points;
  }

  static ParsedGpxTrack parseTrack(String? gpx) {
    if (gpx == null || gpx.isEmpty || gpx.length > 20 * 1024 * 1024) {
      return const ParsedGpxTrack();
    }
    try {
      final document = XmlDocument.parse(gpx);
      var groups = document
          .findAllElements('trkseg', namespaceUri: '*')
          .map((s) => s.findAllElements('trkpt', namespaceUri: '*'))
          .toList();
      if (groups.isEmpty) {
        final trackPoints = document.findAllElements(
          'trkpt',
          namespaceUri: '*',
        );
        groups = trackPoints.isNotEmpty
            ? [trackPoints]
            : document
                  .findAllElements('rte', namespaceUri: '*')
                  .map((r) => r.findAllElements('rtept', namespaceUri: '*'))
                  .toList();
      }
      final points = <LatLng>[], starts = <int>[];
      for (final nodes in groups) {
        var newSegment = true;
        for (final node in nodes) {
          if (points.length >= 100000) break;
          final lat = double.tryParse(node.getAttribute('lat') ?? '');
          final lon = double.tryParse(node.getAttribute('lon') ?? '');
          if (lat == null ||
              lon == null ||
              !lat.isFinite ||
              !lon.isFinite ||
              lat.abs() > 90 ||
              lon.abs() > 180) {
            newSegment = true;
            continue;
          }
          if (newSegment) {
            starts.add(points.length);
            newSegment = false;
          }
          points.add(LatLng(lat, lon));
        }
        if (points.length >= 100000) break;
      }
      final name =
          document
              .findAllElements('name', namespaceUri: '*')
              .firstOrNull
              ?.innerText
              .trim() ??
          '';
      return ParsedGpxTrack(
        points: List.unmodifiable(points),
        segmentStarts: List.unmodifiable(starts),
        name: name.substring(0, name.length.clamp(0, 240)),
      );
    } on XmlException {
      return const ParsedGpxTrack();
    } on ArgumentError {
      return const ParsedGpxTrack();
    }
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
