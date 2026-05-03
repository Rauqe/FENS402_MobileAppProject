import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/patient.dart';
import '../models/medication.dart';
import '../models/medication_schedule.dart';
import '../models/slot_medication.dart';
import 'dispenser_service.dart' show kPiBaseUrl;
import 'auth_service.dart' show kAwsApiBaseUrl;

const Duration kApiTimeout = Duration(seconds: 10);
const Duration kAuthTimeout = Duration(seconds: 15);

class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);

  String get displayMessage {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map && decoded['message'] != null) {
        return '${decoded['message']} ($statusCode)';
      }
    } catch (_) {}
    return '$statusCode: $message';
  }

  @override
  String toString() => displayMessage;
}

class ApiService {
  ApiService._();
  static final ApiService instance = ApiService._();

  final _client = http.Client();

  // AWS: /patients, /medications, /schedules, /slots, /dispensing-logs, /auth, /kvs-live/...
  Uri _awsUri(String path) => Uri.parse('$kAwsApiBaseUrl$path');

  // Pi: /api/sync, /api/state, /api/face, /api/health
  Uri _piUri(String path) => Uri.parse('$kPiBaseUrl/api$path');

  // ── HTTP helpers ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _get(String path, {bool pi = false}) async {
    final uri = pi ? _piUri(path) : _awsUri(path);
    debugPrint('[API] GET $uri');
    final response = await _client
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(kApiTimeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body, {bool pi = false}) async {
    final uri = pi ? _piUri(path) : _awsUri(path);
    debugPrint('[API] POST $uri');
    final response = await _client
        .post(uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body))
        .timeout(kApiTimeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> _put(
      String path, Map<String, dynamic> body, {bool pi = false}) async {
    final uri = pi ? _piUri(path) : _awsUri(path);
    debugPrint('[API] PUT $uri');
    final response = await _client
        .put(uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body))
        .timeout(kApiTimeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> _delete(String path, {bool pi = false}) async {
    final uri = pi ? _piUri(path) : _awsUri(path);
    debugPrint('[API] DELETE $uri');
    final response = await _client
        .delete(uri, headers: {'Accept': 'application/json'})
        .timeout(kApiTimeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  // ── Health ────────────────────────────────────────────────────────────────

  Future<bool> healthCheck() async {
    try {
      final data = await _get('/health', pi: true);
      return data['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  // ── Patients → AWS ────────────────────────────────────────────────────────

  Future<List<Patient>> getAllPatients() async {
    final data = await _get('/patients');
    final list = data['patients'] as List<dynamic>;
    return list
        .map((json) => Patient.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<Patient> getPatient(String patientId) async {
    final data = await _get('/patients/$patientId');
    return Patient.fromJson(data);
  }

  Future<Patient> createPatient({
    required String firstName,
    required String lastName,
    String? dateOfBirth,
    String? email,
    String? password,
  }) async {
    final data = await _post('/patients', {
      'first_name': firstName,
      'last_name': lastName,
      if (dateOfBirth != null) 'date_of_birth': dateOfBirth,
      if (email != null) 'email': email,
      if (password != null) 'password': password,
    });
    return Patient(
      patientId: data['patient_id'] as String,
      firstName: data['first_name'] as String,
      lastName: data['last_name'] as String,
    );
  }

  Future<Map<String, dynamic>> createPatientWithAccount({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    required String caregiverId,
    String? dateOfBirth,
  }) async {
    return _post('/auth/patient/create', {
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'password': password,
      'caregiver_id': caregiverId,
      if (dateOfBirth != null) 'date_of_birth': dateOfBirth,
    });
  }

  Future<Patient> updatePatient({
    required String patientId,
    required String firstName,
    required String lastName,
    String? dateOfBirth,
  }) async {
    final data = await _put('/patients/$patientId', {
      'first_name': firstName,
      'last_name': lastName,
      if (dateOfBirth != null) 'date_of_birth': dateOfBirth,
    });
    return Patient(
      patientId: data['patient_id'] as String,
      firstName: data['first_name'] as String,
      lastName: data['last_name'] as String,
    );
  }

  Future<void> deletePatient(String patientId) async {
    await _delete('/patients/$patientId');
  }

  // ── Medications → AWS ─────────────────────────────────────────────────────

  Future<Medication?> getMedicationByBarcode(String barcode) async {
    try {
      final data =
          await _get('/medications/barcode/${Uri.encodeComponent(barcode)}');
      final m = data['medication'] as Map<String, dynamic>;
      return Medication.fromJson(m);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<List<Medication>> getPatientMedications(String patientId) async {
    final data = await _get('/medications/$patientId');
    final list = data['medications'] as List<dynamic>;
    return list
        .map((json) => Medication.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> createMedication({
    required String patientId,
    required String medicationName,
    String? pillBarcode,
    String? pillColorShape,
    int remainingCount = 0,
    int lowStockThreshold = 5,
    String? expiryDate,
  }) async {
    return _post('/medications', {
      'patient_id': patientId,
      'medication_name': medicationName,
      if (pillBarcode != null) 'pill_barcode': pillBarcode,
      if (pillColorShape != null) 'pill_color_shape': pillColorShape,
      'remaining_count': remainingCount,
      'low_stock_threshold': lowStockThreshold,
      if (expiryDate != null) 'expiry_date': expiryDate,
    });
  }

  Future<Map<String, dynamic>> updateMedication(
    String medicationId, {
    String? medicationName,
    String? pillBarcode,
    String? pillColorShape,
    int? remainingCount,
    int? lowStockThreshold,
    String? expiryDate,
  }) async {
    return _put('/medications/$medicationId', {
      if (medicationName != null) 'medication_name': medicationName,
      'pill_barcode': pillBarcode,
      'pill_color_shape': pillColorShape,
      if (remainingCount != null) 'remaining_count': remainingCount,
      if (lowStockThreshold != null) 'low_stock_threshold': lowStockThreshold,
      if (expiryDate != null) 'expiry_date': expiryDate,
    });
  }

  Future<void> deleteMedication(String medicationId) async {
    await _delete('/medications/$medicationId');
  }

  // ── Slots → AWS ───────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getAllSlots() async {
    final data = await _get('/slots');
    final list = data['slots'] as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> getAvailableSlots() async {
    return _get('/slots/available');
  }

  Future<List<SlotMedication>> getSlotMedications(int slotId) async {
    final data = await _get('/slots/$slotId/medications');
    final list = data['medications'] as List<dynamic>;
    return list
        .map((m) => SlotMedication.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> setSlotMedications(
      int slotId, List<SlotMedication> medications) async {
    return _post('/slots/$slotId/medications',
        {'medications': medications.map((m) => m.toJson()).toList()});
  }

  // ── Schedules → AWS ───────────────────────────────────────────────────────

  Future<List<MedicationSchedule>> getPatientSchedules(
      String patientId) async {
    final data = await _get('/schedules/$patientId');
    final list = data['schedules'] as List<dynamic>;
    return list
        .map((json) =>
            MedicationSchedule.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> createSchedule({
    required int slotId,
    required String patientId,
    required String plannedTime,
    String frequencyType = 'daily',
    String weekDays = '',
    required String startDate,
    String? endDate,
    int windowSeconds = 300,
    String? groupId,
    List<SlotMedication> medications = const [],
  }) async {
    return _post('/schedules', {
      'patient_id': patientId,
      'slot_id': slotId,
      'planned_time': plannedTime,
      'frequency_type': frequencyType,
      'week_days': weekDays,
      'start_date': startDate,
      if (endDate != null) 'end_date': endDate,
      'window_seconds': windowSeconds,
      if (groupId != null) 'group_id': groupId,
      'medications': medications.map((m) => m.toJson()).toList(),
    });
  }

  Future<Map<String, dynamic>> updateSchedule({
    required String scheduleId,
    String? plannedTime,
    String? frequencyType,
    String? weekDays,
    String? startDate,
    String? endDate,
    int? windowSeconds,
    List<SlotMedication>? medications,
  }) async {
    return _put('/schedules/$scheduleId', {
      if (plannedTime != null) 'planned_time': plannedTime,
      if (frequencyType != null) 'frequency_type': frequencyType,
      if (weekDays != null) 'week_days': weekDays,
      if (startDate != null) 'start_date': startDate,
      if (endDate != null) 'end_date': endDate,
      if (windowSeconds != null) 'window_seconds': windowSeconds,
      if (medications != null)
        'medications': medications.map((m) => m.toJson()).toList(),
    });
  }

  Future<Map<String, dynamic>> updateScheduleGroup({
    required String groupId,
    String? plannedTime,
    String? frequencyType,
    String? weekDays,
    String? startDate,
    String? endDate,
    int? windowSeconds,
    List<SlotMedication>? medications,
  }) async {
    return _put('/schedules/group/$groupId', {
      if (plannedTime != null) 'planned_time': plannedTime,
      if (frequencyType != null) 'frequency_type': frequencyType,
      if (weekDays != null) 'week_days': weekDays,
      if (startDate != null) 'start_date': startDate,
      if (endDate != null) 'end_date': endDate,
      if (windowSeconds != null) 'window_seconds': windowSeconds,
      if (medications != null)
        'medications': medications.map((m) => m.toJson()).toList(),
    });
  }

  Future<Map<String, dynamic>> toggleScheduleGroup(String groupId) async {
    debugPrint('[API] PATCH /schedules/group/$groupId/active');
    final response = await _client
        .patch(
          _awsUri('/schedules/group/$groupId/active'),
          headers: {'Accept': 'application/json'},
        )
        .timeout(kApiTimeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> toggleSchedule(String scheduleId) async {
    debugPrint('[API] PATCH /schedules/$scheduleId/active');
    final response = await _client
        .patch(
          _awsUri('/schedules/$scheduleId/active'),
          headers: {'Accept': 'application/json'},
        )
        .timeout(kApiTimeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<void> deleteScheduleGroup(String groupId) async {
    await _delete('/schedules/group/$groupId');
  }

  Future<void> deleteSchedule(String scheduleId) async {
    await _delete('/schedules/$scheduleId');
  }

  // ── Cloud Sync → Pi ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getSyncStatus() async {
    return _get('/sync/status', pi: true);
  }

  Future<Map<String, dynamic>> triggerSync() async {
    final response = await _client
        .post(_piUri('/sync'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: '{}')
        .timeout(const Duration(seconds: 30));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> syncPush() async {
    final response = await _client
        .post(_piUri('/sync/push'),
            headers: {'Accept': 'application/json'}, body: '{}')
        .timeout(const Duration(seconds: 30));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  Future<Map<String, dynamic>> syncPull() async {
    final response = await _client
        .post(_piUri('/sync/pull'),
            headers: {'Accept': 'application/json'}, body: '{}')
        .timeout(const Duration(seconds: 30));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  // ── Dispensing Logs → AWS ─────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getDispensingLogs(
      String patientId) async {
    final data = await _get('/dispensing-logs/$patientId');
    final list = data['logs'] as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> getPatientAnalytics({
    required String patientId,
    required String startDate,
    required String endDate,
  }) async {
    return _get(
        '/dispensing-logs/$patientId/analytics?start_date=$startDate&end_date=$endDate');
  }

  Future<Map<String, dynamic>> createDispensingLog({
    required String patientId,
    String? scheduleId,
    required String status,
    double? faceAuthScore,
    String? deviceTimestamp,
    String? errorDetails,
  }) async {
    return _post('/dispensing-logs', {
      'patient_id': patientId,
      if (scheduleId != null) 'schedule_id': scheduleId,
      'status': status,
      if (faceAuthScore != null) 'face_auth_score': faceAuthScore,
      if (deviceTimestamp != null) 'device_timestamp': deviceTimestamp,
      if (errorDetails != null) 'error_details': errorDetails,
    });
  }

  // ── Kinesis Video (HLS) → AWS ─────────────────────────────────────────────

  /// Returns a short-lived HLS session URL for the dispenser live KVS stream.
  Future<String> getLiveStreamHlsUrl() async {
    final data = await _get('/kvs-live/stream/live');
    final url = data['hls_url'] as String?;
    if (url == null || url.isEmpty) {
      throw ApiException(500, 'Missing hls_url in response');
    }
    return url;
  }

  // ── Patient Accounts → AWS ────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getPatientAccounts() async {
    final data = await _get('/auth/patient-accounts');
    final list = data['accounts'] as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createPatientAccount({
    required String patientId,
    required String email,
    required String password,
  }) async {
    debugPrint('[API] POST /auth/patient-account → AWS');
    final response = await _client
        .post(
          _awsUri('/auth/patient-account'),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode({
            'patient_id': patientId,
            'email': email,
            'password': password,
          }),
        )
        .timeout(kAuthTimeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw ApiException(response.statusCode, response.body);
  }

  // ── Notifications → AWS ───────────────────────────────────────────────────

  static Future<void> registerFcmToken(
    String token, {
    String? email,
    String? role, // "caregiver" or "patient"
  }) async {
    debugPrint('[API] Registering FCM token with AWS backend');
    final response = await http.post(
      Uri.parse('$kAwsApiBaseUrl/notifications/register-token'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'fcm_token': token,
        if (email != null) 'email': email,
        if (role != null) 'role': role,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
    debugPrint('[API] FCM token registered successfully');
  }
}