enum RideMomentKind {
  goodSection('Хороший участок'),
  climb('Подъём'),
  technical('Сложный участок'),
  rest('Место отдыха');

  const RideMomentKind(this.label);
  final String label;
}

/// Private route memories. SharedRoute and GPX deliberately export no memories.
class RideMoment {
  const RideMoment({
    required this.id,
    required this.kind,
    required this.pointIndex,
    required this.distanceMeters,
    this.note = '',
  });

  final String id;
  final RideMomentKind kind;
  final int pointIndex;
  final double distanceMeters;
  final String note;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'point_index': pointIndex,
    'meters': distanceMeters,
    'note': note,
  };

  static RideMoment? tryParse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'],
        index = value['point_index'],
        meters = value['meters'];
    final kind = RideMomentKind.values
        .where((k) => k.name == value['kind'])
        .firstOrNull;
    final note = value['note'] ?? '';
    if (id is! String ||
        id.isEmpty ||
        id.length > 80 ||
        index is! int ||
        index < 0 ||
        index > 1000000 ||
        meters is! num ||
        !meters.isFinite ||
        meters < 0 ||
        meters > 100000000 ||
        kind == null ||
        note is! String ||
        note.length > 280)
      return null;
    return RideMoment(
      id: id,
      kind: kind,
      pointIndex: index,
      distanceMeters: meters.toDouble(),
      note: note,
    );
  }
}
