import 'package:latlong2/latlong.dart' hide Path;
import 'package:xml/xml.dart';

/// Итог разбора GPX: не сводить все проблемы к пустому списку точек.
enum GpxParseStatus {
  /// Файл прочитан целиком, все поддерживаемые точки трека сохранены.
  ok,

  /// Часть точек за капом 100 000 не прочитана: трек неполный.
  truncatedPoints,

  /// Файл больше ограничения размера (20 млн символов Dart-строки) —
  /// разбор даже не начинался.
  oversized,

  /// XML не удалось разобрать.
  invalidXml,

  /// Файл корректен, но поддерживаемого трека (trkpt/rtept) в нём нет.
  noTrack,
}

class ParsedGpxTrack {
  const ParsedGpxTrack({
    this.points = const [],
    this.segmentStarts = const [],
    this.name = '',
    this.sourcePointIndices = const [],
    this.status = GpxParseStatus.noTrack,
    this.totalTrackPoints = 0,
  });
  final List<LatLng> points;
  final List<int> segmentStarts;
  final String name;

  /// Original XML point index for each retained point; invalid points count too.
  final List<int> sourcePointIndices;

  /// Явный результат разбора (см. [GpxParseStatus]).
  final GpxParseStatus status;

  /// Сколько узлов трек-точек было в файле всего (0, если разбор не шёл).
  final int totalTrackPoints;
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
    if (gpx == null || gpx.isEmpty) {
      return const ParsedGpxTrack(status: GpxParseStatus.noTrack);
    }
    // Ограничение по длине Dart-строки (UTF-16 символам), а не по байтам.
    // Сообщение об ошибке должно называть символы, а не мегабайты файла.
    if (gpx.length > 20 * 1024 * 1024) {
      return const ParsedGpxTrack(status: GpxParseStatus.oversized);
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
      final totalTrackPoints = groups.fold<int>(
        0,
        (sum, nodes) => sum + nodes.length,
      );
      final points = <LatLng>[], starts = <int>[];
      final sourceIndices = <int>[];
      var sourceIndex = 0;
      var pointLimitHit = false;
      for (final nodes in groups) {
        var newSegment = true;
        for (final node in nodes) {
          // Кап срабатывает только когда есть СЛЕДУЮЩАЯ непрочитанная точка:
          // ровно 100 000 точек в файле — это полный трек, не усечение.
          if (points.length >= 100000) {
            pointLimitHit = true;
            break;
          }
          final originalIndex = sourceIndex++;
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
          sourceIndices.add(originalIndex);
          points.add(LatLng(lat, lon));
        }
        // Внешний break убран: он молча пропускал целые сегменты после капа.
        // Внутренний break и так прекращает добавление точек, а проход по
        // следующим сегментам стоит O(1) на сегмент.
      }
      final name =
          document
              .findAllElements('name', namespaceUri: '*')
              .firstOrNull
              ?.innerText
              .trim() ??
          '';
      final GpxParseStatus status;
      if (pointLimitHit) {
        status = GpxParseStatus.truncatedPoints;
      } else if (points.isEmpty) {
        status = GpxParseStatus.noTrack;
      } else {
        status = GpxParseStatus.ok;
      }
      return ParsedGpxTrack(
        points: List.unmodifiable(points),
        segmentStarts: List.unmodifiable(starts),
        sourcePointIndices: List.unmodifiable(sourceIndices),
        name: name.substring(0, name.length.clamp(0, 240)),
        status: status,
        totalTrackPoints: totalTrackPoints,
      );
    } on XmlException {
      return const ParsedGpxTrack(status: GpxParseStatus.invalidXml);
    } on ArgumentError {
      return const ParsedGpxTrack(status: GpxParseStatus.invalidXml);
    }
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
