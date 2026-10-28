enum RideMediaKind { photo, video }

class RideMedia {
  const RideMedia({
    required this.id,
    required this.pointIndex,
    required this.kind,
    required this.localPath,
    required this.createdAt,
    this.caption = '',
  });
  final String id;
  final int pointIndex;
  final RideMediaKind kind;
  final String localPath;
  final DateTime createdAt;
  final String caption;
  Map<String, dynamic> toJson() => {
    'id': id,
    'point_index': pointIndex,
    'kind': kind.name,
    'local_path': localPath,
    'created_at': createdAt.toUtc().toIso8601String(),
    'caption': caption,
  };
  static RideMedia fromJson(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! String ||
        (raw['id'] as String).isEmpty ||
        (raw['id'] as String).length > 80 ||
        raw['point_index'] is! int ||
        (raw['point_index'] as int) < 0 ||
        (raw['point_index'] as int) > 1000000 ||
        raw['local_path'] is! String ||
        (raw['local_path'] as String).isEmpty ||
        (raw['local_path'] as String).length > 4096 ||
        raw['caption'] is! String ||
        (raw['caption'] as String).length > 280 ||
        raw['created_at'] is! String ||
        DateTime.tryParse(raw['created_at']) == null) {
      throw const FormatException('Повреждены материалы поездки');
    }
    final kind = RideMediaKind.values
        .where((value) => value.name == raw['kind'])
        .firstOrNull;
    if (kind == null) throw const FormatException('Неизвестный вид материала');
    return RideMedia(
      id: raw['id'],
      pointIndex: raw['point_index'],
      kind: kind,
      localPath: raw['local_path'],
      createdAt: DateTime.parse(raw['created_at']),
      caption: raw['caption'],
    );
  }

  RideMedia at(int index, String text) => RideMedia(
    id: id,
    pointIndex: index,
    kind: kind,
    localPath: localPath,
    createdAt: createdAt,
    caption: text.trim(),
  );
}

/// Shared snapshots contain only a private Storage reference and a visible-point index.
class SharedRideMedia {
  const SharedRideMedia({
    required this.id,
    required this.pointIndex,
    required this.kind,
    required this.reference,
    this.caption = '',
    this.posterReference,
  });
  final String id;
  final int pointIndex;
  final RideMediaKind kind;
  final String reference;
  final String caption;
  final String? posterReference;
  Map<String, dynamic> toJson() => {
    'id': id,
    'point_index': pointIndex,
    'kind': kind.name,
    'reference': reference,
    'caption': caption,
    if (posterReference != null) 'poster_reference': posterReference,
  };
  SharedRideMedia at(int index) => SharedRideMedia(
    id: id,
    pointIndex: index,
    kind: kind,
    reference: reference,
    caption: caption,
    posterReference: posterReference,
  );
  static SharedRideMedia? tryParse(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! String ||
        (raw['id'] as String).isEmpty ||
        (raw['id'] as String).length > 80 ||
        raw['point_index'] is! int ||
        (raw['point_index'] as int) < 0 ||
        raw['reference'] is! String ||
        raw['caption'] is! String ||
        (raw['caption'] as String).length > 280) {
      return null;
    }
    final match = RegExp(
      r'^ride:([a-zA-Z0-9-]{1,80})/([a-zA-Z0-9-]{1,80})\.(jpg|jpeg|png|webp|mp4|mov|m4v|webm)$',
    ).firstMatch(raw['reference']);
    final kind = RideMediaKind.values
        .where((k) => k.name == raw['kind'])
        .firstOrNull;
    if (match == null ||
        kind == null ||
        match.group(2) != raw['id'] ||
        (kind == RideMediaKind.video) !=
            ['mp4', 'mov', 'm4v', 'webm'].contains(match.group(3))) {
      return null;
    }
    final poster = raw['poster_reference'];
    if (poster != null &&
        (kind != RideMediaKind.video ||
            poster != 'ride:${match.group(1)}/${raw['id']}-preview.png')) {
      return null;
    }
    return SharedRideMedia(
      id: raw['id'],
      pointIndex: raw['point_index'],
      kind: kind,
      reference: raw['reference'],
      caption: raw['caption'],
      posterReference: poster as String?,
    );
  }
}
