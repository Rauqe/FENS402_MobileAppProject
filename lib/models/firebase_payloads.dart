/// Strictly-typed Firebase Realtime Database payload models.
///
/// Each class maps 1-to-1 with a table in the ER diagram.
/// All classes implement [toJson] / [fromJson] so they can be written to
/// Firebase with `ref.set(payload.toJson())` and read back with
/// `MyPayload.fromJson(snapshot.value as Map)`.
///
/// Firebase path conventions used by [FirebaseService]:
///   /patients/{patientId}
///   /medications/{medicationId}
///   /medication_schedules/{scheduleId}
///   /dispensing_logs/{logId}
///   /patient_caregivers/{mappingId}
library firebase_payloads;

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Converts a [DateTime] to an ISO-8601 string for Firebase storage.
String _dateToJson(DateTime dt) => dt.toUtc().toIso8601String();

/// Parses an ISO-8601 string from Firebase back to a [DateTime].
DateTime _dateFromJson(String s) => DateTime.parse(s).toLocal();

DateTime? _nullableDateFromJson(dynamic s) =>
    s == null ? null : _dateFromJson(s as String);

String? _nullableDateToJson(DateTime? dt) =>
    dt == null ? null : _dateToJson(dt);

// ═════════════════════════════════════════════════════════════════════════════
// PatientPayload  →  ER: Patients
// ═════════════════════════════════════════════════════════════════════════════

class PatientPayload {
  final String patientId;
  final String fullName;
  final DateTime dateOfBirth;
  final String timezone;
  final String? deviceSerialNumber;
  final int batteryLevel;
  final bool isOnline;
  final DateTime? lastSeenAt;

  const PatientPayload({
    required this.patientId,
    required this.fullName,
    required this.dateOfBirth,
    this.timezone = 'Europe/Istanbul',
    this.deviceSerialNumber,
    this.batteryLevel = 0,
    this.isOnline = false,
    this.lastSeenAt,
  });

  factory PatientPayload.fromJson(Map<dynamic, dynamic> json) {
    return PatientPayload(
      patientId: json['patient_id'] as String,
      fullName: json['full_name'] as String,
      dateOfBirth: _dateFromJson(json['date_of_birth'] as String),
      timezone: (json['timezone'] as String?) ?? 'Europe/Istanbul',
      deviceSerialNumber: json['device_serial_number'] as String?,
      batteryLevel: (json['battery_level'] as int?) ?? 0,
      isOnline: (json['is_online'] as bool?) ?? false,
      lastSeenAt: _nullableDateFromJson(json['last_seen_at']),
    );
  }

  Map<String, dynamic> toJson() => {
        'patient_id': patientId,
        'full_name': fullName,
        'date_of_birth': _dateToJson(dateOfBirth),
        'timezone': timezone,
        'device_serial_number': deviceSerialNumber,
        'battery_level': batteryLevel,
        'is_online': isOnline,
        'last_seen_at': _nullableDateToJson(lastSeenAt),
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// MedicationPayload  →  ER: Medications
// ═════════════════════════════════════════════════════════════════════════════

class MedicationPayload {
  final String medicationId;
  final String patientId;
  final String medicationName;
  final String? pillImageUrl;
  final String? pillBoxImage;
  final String? pillBarcode;
  final String? pillColorShape;
  final int remainingCount;
  final int lowStockThreshold;
  final DateTime? expiryDate;

  const MedicationPayload({
    required this.medicationId,
    required this.patientId,
    required this.medicationName,
    this.pillImageUrl,
    this.pillBoxImage,
    this.pillBarcode,
    this.pillColorShape,
    this.remainingCount = 0,
    this.lowStockThreshold = 5,
    this.expiryDate,
  });

  factory MedicationPayload.fromJson(Map<dynamic, dynamic> json) {
    return MedicationPayload(
      medicationId: json['medication_id'] as String,
      patientId: json['patient_id'] as String,
      medicationName: json['medication_name'] as String,
      pillImageUrl: json['pill_image_url'] as String?,
      pillBoxImage: json['pill_box_image'] as String?,
      pillBarcode: json['pill_barcode'] as String?,
      pillColorShape: json['pill_color_shape'] as String?,
      remainingCount: (json['remaining_count'] as int?) ?? 0,
      lowStockThreshold: (json['low_stock_threshold'] as int?) ?? 5,
      expiryDate: _nullableDateFromJson(json['expiry_date']),
    );
  }

  Map<String, dynamic> toJson() => {
        'medication_id': medicationId,
        'patient_id': patientId,
        'medication_name': medicationName,
        'pill_image_url': pillImageUrl,
        'pill_box_image': pillBoxImage,
        'pill_barcode': pillBarcode,
        'pill_color_shape': pillColorShape,
        'remaining_count': remainingCount,
        'low_stock_threshold': lowStockThreshold,
        'expiry_date': _nullableDateToJson(expiryDate),
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// MedicationSchedulePayload  →  ER: Medication_Schedules
// ═════════════════════════════════════════════════════════════════════════════

class MedicationSchedulePayload {
  final String scheduleId;
  final String medicationId;

  /// Stored as "HH:mm" (24-hour) — e.g. "08:00", "21:30".
  final String plannedTime;

  final int dosageQuantity;
  final bool isActive;
  final DateTime startDate;
  final DateTime? endDate;

  const MedicationSchedulePayload({
    required this.scheduleId,
    required this.medicationId,
    required this.plannedTime,
    this.dosageQuantity = 1,
    this.isActive = true,
    required this.startDate,
    this.endDate,
  });

  factory MedicationSchedulePayload.fromJson(Map<dynamic, dynamic> json) {
    return MedicationSchedulePayload(
      scheduleId: json['schedule_id'] as String,
      medicationId: json['medication_id'] as String,
      plannedTime: json['planned_time'] as String,
      dosageQuantity: (json['dosage_quantity'] as int?) ?? 1,
      isActive: (json['is_active'] as bool?) ?? true,
      startDate: _dateFromJson(json['start_date'] as String),
      endDate: _nullableDateFromJson(json['end_date']),
    );
  }

  Map<String, dynamic> toJson() => {
        'schedule_id': scheduleId,
        'medication_id': medicationId,
        'planned_time': plannedTime,
        'dosage_quantity': dosageQuantity,
        'is_active': isActive,
        'start_date': _dateToJson(startDate),
        'end_date': _nullableDateToJson(endDate),
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// DispensingLogPayload  →  ER: Dispensing_Logs
// ═════════════════════════════════════════════════════════════════════════════

/// The status of a single dispensing event, as confirmed by the ESP32 sensors.
enum DispensingStatus {
  taken,    // IR + load-cell confirmed pill removal
  missed,   // Compartment opened but pill not removed in time window
  skipped,  // Scheduled dose was not attempted
  error,    // Hardware error during dispensing
}

class DispensingLogPayload {
  final String logId;
  final String patientId;
  final String scheduleId;

  /// Confirmed by the hardware sensors.
  final DispensingStatus status;

  /// Anti-spoofing score from Face-ID (0.0–1.0). Null if auth skipped.
  final double? faceAuthScore;

  /// Device-side UTC timestamp when the event was recorded.
  final DateTime deviceTimestamp;

  /// Extra error info when [status] == [DispensingStatus.error].
  final String? errorDetails;

  const DispensingLogPayload({
    required this.logId,
    required this.patientId,
    required this.scheduleId,
    required this.status,
    this.faceAuthScore,
    required this.deviceTimestamp,
    this.errorDetails,
  });

  factory DispensingLogPayload.fromJson(Map<dynamic, dynamic> json) {
    return DispensingLogPayload(
      logId: json['log_id'] as String,
      patientId: json['patient_id'] as String,
      scheduleId: json['schedule_id'] as String,
      status: DispensingStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => DispensingStatus.error,
      ),
      faceAuthScore: (json['face_auth_score'] as num?)?.toDouble(),
      deviceTimestamp: _dateFromJson(json['device_timestamp'] as String),
      errorDetails: json['error_details'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'log_id': logId,
        'patient_id': patientId,
        'schedule_id': scheduleId,
        'status': status.name,
        'face_auth_score': faceAuthScore,
        'device_timestamp': _dateToJson(deviceTimestamp),
        'error_details': errorDetails,
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// SyncQueuePayload  →  ER: Sync_Queue (local SQLite → Firebase upload queue)
// ═════════════════════════════════════════════════════════════════════════════

/// Mirrors the Sync_Queue table from the ER diagram.
/// Stored locally in SQLite while offline; synced to Firebase when back online.
class SyncQueuePayload {
  final String logId;
  final String scheduleId;
  final bool isSynced;

  /// One of: 'pill_taken' | 'missed_dose' | 'unlock_command' | 'error'
  final String status;

  final DateTime eventTimestamp;
  final int retryCount;

  const SyncQueuePayload({
    required this.logId,
    required this.scheduleId,
    this.isSynced = false,
    required this.status,
    required this.eventTimestamp,
    this.retryCount = 0,
  });

  factory SyncQueuePayload.fromMap(Map<String, dynamic> map) {
    return SyncQueuePayload(
      logId: map['log_id'] as String,
      scheduleId: map['schedule_id'] as String,
      isSynced: (map['is_synced'] as int) == 1,
      status: map['status'] as String,
      eventTimestamp: _dateFromJson(map['event_timestamp'] as String),
      retryCount: (map['retry_count'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'log_id': logId,
        'schedule_id': scheduleId,
        'is_synced': isSynced ? 1 : 0,
        'status': status,
        'event_timestamp': _dateToJson(eventTimestamp),
        'retry_count': retryCount,
      };
}

// ═════════════════════════════════════════════════════════════════════════════
// PatientCaregiverPayload  →  ER: Patient_Caregivers
// ═════════════════════════════════════════════════════════════════════════════

class PatientCaregiverPayload {
  final String mappingId;
  final String patientId;
  final String roleId;

  /// e.g. 'family', 'doctor', 'nurse'
  final String relationshipType;
  final Map<String, dynamic> notificationSettings;

  const PatientCaregiverPayload({
    required this.mappingId,
    required this.patientId,
    required this.roleId,
    required this.relationshipType,
    this.notificationSettings = const {},
  });

  factory PatientCaregiverPayload.fromJson(Map<dynamic, dynamic> json) {
    return PatientCaregiverPayload(
      mappingId: json['mapping_id'] as String,
      patientId: json['patient_id'] as String,
      roleId: json['role_id'] as String,
      relationshipType: json['relationship_type'] as String,
      notificationSettings: Map<String, dynamic>.from(
          json['notification_settings'] as Map? ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'mapping_id': mappingId,
        'patient_id': patientId,
        'role_id': roleId,
        'relationship_type': relationshipType,
        'notification_settings': notificationSettings,
      };
}
