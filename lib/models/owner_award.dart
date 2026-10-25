class OwnerAward {
  const OwnerAward({
    required this.id,
    required this.kind,
    required this.key,
    required this.label,
    required this.icon,
    required this.equipped,
    required this.grantedAt,
  });

  final String id;
  final String kind;
  final String key;
  final String label;
  final String icon;
  final bool equipped;
  final DateTime? grantedAt;

  factory OwnerAward.fromJson(Map<String, dynamic> row) => OwnerAward(
    id: row['id'] as String,
    kind: row['kind'] as String,
    key: row['award_key'] as String,
    label: row['label'] as String,
    icon: row['icon'] as String,
    equipped: row['equipped'] as bool? ?? false,
    grantedAt: DateTime.tryParse(row['granted_at'] as String? ?? ''),
  );
}
