class Medication {
  final String medicationId;
  final String? patientId;
  final String medicationName;
  final String? pillImageUrl;
  final String? pillColorShape;
  final String? pillBarcode;
  final int remainingCount;
  final int lowStockThreshold;
  final DateTime? expiryDate;

  Medication({
    required this.medicationId,
    this.patientId,
    required this.medicationName,
    this.pillImageUrl,
    this.pillColorShape,
    this.pillBarcode,
    this.remainingCount = 0,
    this.lowStockThreshold = 5,
    this.expiryDate,
  });

  bool get isLowStock => remainingCount <= lowStockThreshold;

  bool get isExpired =>
      expiryDate != null && expiryDate!.isBefore(DateTime.now());

  factory Medication.fromJson(Map<String, dynamic> json) {
    return Medication(
      medicationId: json['medication_id'].toString(),
      patientId: json['patient_id']?.toString(),
      medicationName: json['medication_name'] as String? ?? '',
      pillImageUrl: json['pill_image_url'] as String?,
      pillColorShape: json['pill_color_shape'] as String?,
      pillBarcode: json['pill_barcode'] as String?,
      remainingCount: (json['remaining_count'] as int?) ?? 0,
      lowStockThreshold: (json['low_stock_threshold'] as int?) ?? 5,
      expiryDate: json['expiry_date'] != null
          ? DateTime.tryParse(json['expiry_date'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'medication_id': medicationId,
        'patient_id': patientId,
        'medication_name': medicationName,
        'pill_image_url': pillImageUrl,
        'pill_color_shape': pillColorShape,
        'pill_barcode': pillBarcode,
        'remaining_count': remainingCount,
        'low_stock_threshold': lowStockThreshold,
        'expiry_date': expiryDate?.toIso8601String().split('T').first,
      };

  Medication copyWith({
    String? medicationName,
    String? pillImageUrl,
    String? pillColorShape,
    String? pillBarcode,
    int? remainingCount,
    int? lowStockThreshold,
    DateTime? expiryDate,
  }) {
    return Medication(
      medicationId: medicationId,
      patientId: patientId,
      medicationName: medicationName ?? this.medicationName,
      pillImageUrl: pillImageUrl ?? this.pillImageUrl,
      pillColorShape: pillColorShape ?? this.pillColorShape,
      pillBarcode: pillBarcode ?? this.pillBarcode,
      remainingCount: remainingCount ?? this.remainingCount,
      lowStockThreshold: lowStockThreshold ?? this.lowStockThreshold,
      expiryDate: expiryDate ?? this.expiryDate,
    );
  }
}
