/// Represents one medication entry within a slot.
///
/// A slot can hold multiple medications (e.g. Slot 1 → Aspirin x1 + Metformin x2).
/// This maps to the `slot_medications` table on the Pi backend.
class SlotMedication {
  final String medicationId;
  final String medicationName;
  final String? barcode;

  /// How many pills of this medication should be loaded into the slot.
  final int targetCount;

  /// How many have been scanned / physically loaded so far.
  final int loadedCount;

  const SlotMedication({
    required this.medicationId,
    required this.medicationName,
    this.barcode,
    this.targetCount = 1,
    this.loadedCount = 0,
  });

  bool get isFullyLoaded => loadedCount >= targetCount;

  /// Short label shown in list tiles: "Aspirin (2/2)"
  String get loadLabel => '$medicationName ($loadedCount/$targetCount)';

  factory SlotMedication.fromJson(Map<String, dynamic> json) {
    return SlotMedication(
      medicationId: json['medication_id']?.toString() ?? '',
      medicationName: json['medication_name']?.toString() ?? 'Unknown',
      barcode: json['barcode']?.toString(),
      targetCount: (json['target_count'] as int?) ?? 1,
      loadedCount: (json['loaded_count'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'medication_id': medicationId,
        'medication_name': medicationName,
        if (barcode != null) 'barcode': barcode,
        'target_count': targetCount,
        'loaded_count': loadedCount,
      };

  SlotMedication copyWith({
    String? medicationId,
    String? medicationName,
    String? barcode,
    int? targetCount,
    int? loadedCount,
  }) {
    return SlotMedication(
      medicationId: medicationId ?? this.medicationId,
      medicationName: medicationName ?? this.medicationName,
      barcode: barcode ?? this.barcode,
      targetCount: targetCount ?? this.targetCount,
      loadedCount: loadedCount ?? this.loadedCount,
    );
  }

  @override
  String toString() =>
      'SlotMedication($medicationName, $loadedCount/$targetCount)';
}
