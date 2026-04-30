import 'dart:async';
import 'dart:math' as math;
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import '../models/firebase_payloads.dart';

/// Firebase Realtime Database path constants.
///
/// Structure mirrors the ER diagram cloud tables:
///   /patients/{patientId}
///   /medications/{medicationId}
///   /medication_schedules/{scheduleId}
///   /dispensing_logs/{logId}
///   /patient_caregivers/{mappingId}
abstract class _Paths {
  static const String patients = 'patients';
  static const String medications = 'medications';
  static const String schedules = 'medication_schedules';
  static const String logs = 'dispensing_logs';
  static const String caregivers = 'patient_caregivers';
}

/// Thin, testable wrapper around Firebase Realtime Database.
///
/// All methods are async and throw on Firebase errors — callers should
/// catch [FirebaseException] as needed.
///
/// Usage (after `await Firebase.initializeApp()`):
/// ```dart
/// final fb = FirebaseService();
///
/// // Watch a patient's schedules in real time
/// fb.watchSchedules('patient-123').listen((schedules) { ... });
///
/// // Push a dispensing log
/// await fb.pushDispensingLog(log);
/// ```
class FirebaseService {
  final FirebaseDatabase _db;

  FirebaseService({FirebaseDatabase? database})
      : _db = database ?? FirebaseDatabase.instance;

  // ── Patients ─────────────────────────────────────────────────────────────────

  /// Fetches a single patient record.  Returns null if not found.
  Future<PatientPayload?> getPatient(String patientId) async {
    final snapshot =
        await _db.ref('${_Paths.patients}/$patientId').get();
    if (!snapshot.exists || snapshot.value == null) return null;

    return PatientPayload.fromJson(
        Map<dynamic, dynamic>.from(snapshot.value as Map));
  }

  /// Writes (or overwrites) a patient record.
  Future<void> savePatient(PatientPayload patient) async {
    await _db
        .ref('${_Paths.patients}/${patient.patientId}')
        .set(patient.toJson());
  }

  /// Updates the device online status + last-seen timestamp for a patient.
  /// Called by the app when it receives a BLE [BleEvent.statusResponse].
  Future<void> updatePatientStatus(
    String patientId, {
    required bool isOnline,
    required int batteryLevel,
  }) async {
    await _db.ref('${_Paths.patients}/$patientId').update({
      'is_online': isOnline,
      'battery_level': batteryLevel,
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  // ── Medications ───────────────────────────────────────────────────────────────

  /// Returns all medications for a patient as a list.
  Future<List<MedicationPayload>> getMedications(String patientId) async {
    final snapshot = await _db
        .ref(_Paths.medications)
        .orderByChild('patient_id')
        .equalTo(patientId)
        .get();

    if (!snapshot.exists || snapshot.value == null) return [];

    final map = Map<dynamic, dynamic>.from(snapshot.value as Map);
    return map.values
        .map((v) => MedicationPayload.fromJson(
            Map<dynamic, dynamic>.from(v as Map)))
        .toList();
  }

  /// Writes a medication record.
  Future<void> saveMedication(MedicationPayload medication) async {
    await _db
        .ref('${_Paths.medications}/${medication.medicationId}')
        .set(medication.toJson());
  }

  /// Decrements remaining pill count by [consumed] (called after pill_taken).
  Future<void> decrementPillCount(
      String medicationId, int consumed) async {
    final ref = _db.ref('${_Paths.medications}/$medicationId/remaining_count');
    await ref.runTransaction((currentData) {
      final current = (currentData as int?) ?? 0;
      return Transaction.success(math.max(0, current - consumed));
    });
  }

  // ── Medication Schedules ──────────────────────────────────────────────────────

  /// Fetches all schedules for a patient once.
  Future<List<MedicationSchedulePayload>> getSchedules(
      String patientId) async {
    final snapshot = await _db
        .ref(_Paths.schedules)
        .orderByChild('medication_id')
        .get();

    if (!snapshot.exists || snapshot.value == null) return [];

    final map = Map<dynamic, dynamic>.from(snapshot.value as Map);
    return map.values
        .map((v) => MedicationSchedulePayload.fromJson(
            Map<dynamic, dynamic>.from(v as Map)))
        .toList();
  }

  /// **Real-time stream** of schedule changes for a patient.
  ///
  /// The UI subscribes to this to instantly reflect any caregiver updates
  /// (e.g. a new medication was added) without polling.
  Stream<List<MedicationSchedulePayload>> watchSchedules(
      String patientId) {
    final ref = _db.ref(_Paths.schedules);

    return ref.onValue.map((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) return [];

      final map =
          Map<dynamic, dynamic>.from(event.snapshot.value as Map);
      return map.values
          .map((v) => MedicationSchedulePayload.fromJson(
              Map<dynamic, dynamic>.from(v as Map)))
          .where((s) => s.isActive)
          .toList();
    });
  }

  /// Writes (or overwrites) a schedule.
  Future<void> saveSchedule(MedicationSchedulePayload schedule) async {
    await _db
        .ref('${_Paths.schedules}/${schedule.scheduleId}')
        .set(schedule.toJson());
  }

  /// Deactivates a schedule without deleting it (soft-delete for audit trail).
  Future<void> deactivateSchedule(String scheduleId) async {
    await _db
        .ref('${_Paths.schedules}/$scheduleId')
        .update({'is_active': false});
  }

  // ── Dispensing Logs ───────────────────────────────────────────────────────────

  /// Pushes a single dispensing event log to Firebase.
  /// Called by [SyncQueueManager] when uploading queued events.
  Future<void> pushDispensingLog(DispensingLogPayload log) async {
    await _db
        .ref('${_Paths.logs}/${log.logId}')
        .set(log.toJson());
    debugPrint('[FirebaseService] Log pushed: ${log.logId} (${log.status.name})');
  }

  /// Fetches dispensing history for a patient, ordered by timestamp descending.
  Future<List<DispensingLogPayload>> getLogsForPatient(
    String patientId, {
    int limit = 30,
  }) async {
    final snapshot = await _db
        .ref(_Paths.logs)
        .orderByChild('patient_id')
        .equalTo(patientId)
        .limitToLast(limit)
        .get();

    if (!snapshot.exists || snapshot.value == null) return [];

    final map = Map<dynamic, dynamic>.from(snapshot.value as Map);
    final logs = map.values
        .map((v) => DispensingLogPayload.fromJson(
            Map<dynamic, dynamic>.from(v as Map)))
        .toList();

    // Sort newest first (Firebase limitToLast returns ascending order).
    logs.sort((a, b) => b.deviceTimestamp.compareTo(a.deviceTimestamp));
    return logs;
  }

  /// **Real-time stream** of the latest dispensing log for a patient.
  /// Used by the Patient Dashboard to show "last pill taken" status.
  Stream<DispensingLogPayload?> watchLatestLog(String patientId) {
    return _db
        .ref(_Paths.logs)
        .orderByChild('patient_id')
        .equalTo(patientId)
        .limitToLast(1)
        .onValue
        .map((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) return null;

      final map = Map<dynamic, dynamic>.from(event.snapshot.value as Map);
      if (map.isEmpty) return null;

      return DispensingLogPayload.fromJson(
          Map<dynamic, dynamic>.from(map.values.first as Map));
    });
  }
}

