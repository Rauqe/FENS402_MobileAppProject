import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Pi Flask API base URL.
const String kPiBaseUrl = 'http://192.168.0.16:5000';
const Duration _kPollInterval = Duration(seconds: 2);
const Duration _kTimeout = Duration(seconds: 3);

/// Mirrors DispenserState enum from pi_backend/state_machine.py
enum DispenserState {
  idle,
  rotating,
  loadingMode,
  slotReady,
  waitingForPatient,
  faceMatched,
  dispensing,
  error;

  static DispenserState fromString(String value) {
    switch (value) {
      case 'idle':
        return DispenserState.idle;
      case 'rotating':
        return DispenserState.rotating;
      case 'loading_mode':
        return DispenserState.loadingMode;
      case 'slot_ready':
        return DispenserState.slotReady;
      case 'waiting_for_patient':
        return DispenserState.waitingForPatient;
      case 'face_matched':
        return DispenserState.faceMatched;
      case 'dispensing':
        return DispenserState.dispensing;
      case 'error':
        return DispenserState.error;
      default:
        return DispenserState.idle;
    }
  }
}

/// Snapshot of the Pi dispenser state.
class DispenserSnapshot {
  final DispenserState state;
  final String? currentPatientId;
  final String? currentPatientName;
  final int? selectedSlot;
  final int barcodeCount;
  final List<String> scannedBarcodes;
  final bool motorBusy;
  final bool servoOpen;
  final bool cameraActive;
  final String? lastError;
  final int? windowRemainingSec;
  final int authAttempts;
  final double? lastAuthScore;
  final String? stateChangedAt;

  const DispenserSnapshot({
    this.state = DispenserState.idle,
    this.currentPatientId,
    this.currentPatientName,
    this.selectedSlot,
    this.barcodeCount = 0,
    this.scannedBarcodes = const [],
    this.motorBusy = false,
    this.servoOpen = false,
    this.cameraActive = false,
    this.lastError,
    this.windowRemainingSec,
    this.authAttempts = 0,
    this.lastAuthScore,
    this.stateChangedAt,
  });

  factory DispenserSnapshot.fromJson(Map<String, dynamic> json) {
    return DispenserSnapshot(
      state: DispenserState.fromString(json['state'] as String? ?? 'idle'),
      currentPatientId: json['current_patient_id'] as String?,
      currentPatientName: json['current_patient_name'] as String?,
      selectedSlot: json['selected_slot'] as int?,
      barcodeCount: json['barcode_count'] as int? ?? 0,
      scannedBarcodes: (json['scanned_barcodes'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      motorBusy: json['motor_busy'] as bool? ?? false,
      servoOpen: json['servo_open'] as bool? ?? false,
      cameraActive: json['camera_active'] as bool? ?? false,
      lastError: json['last_error'] as String?,
      windowRemainingSec: json['window_remaining_sec'] as int?,
      authAttempts: json['auth_attempts'] as int? ?? 0,
      lastAuthScore: (json['last_auth_score'] as num?)?.toDouble(),
      stateChangedAt: json['state_changed_at'] as String?,
    );
  }

  bool get isActive => state != DispenserState.idle && state != DispenserState.error;
}

/// Result of a command sent to the Pi.
class DispenserResult {
  final bool ok;
  final String message;
  final Map<String, dynamic> raw;

  const DispenserResult({
    required this.ok,
    required this.message,
    this.raw = const {},
  });

  factory DispenserResult.fromJson(Map<String, dynamic> json) {
    return DispenserResult(
      ok: json['ok'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      raw: json,
    );
  }

  factory DispenserResult.error(String msg) {
    return DispenserResult(ok: false, message: msg);
  }
}

/// Service that polls the Pi's Flask API and exposes commands.
/// Singleton — tüm ekranlar aynı instance'ı paylaşır, tek bir poll döngüsü çalışır.
class DispenserService extends ChangeNotifier {
  DispenserService._({String? baseUrl}) : _baseUrl = baseUrl ?? kPiBaseUrl;

  static final DispenserService instance = DispenserService._();

  /// Geriye dönük uyumluluk için factory constructor.
  factory DispenserService({String? baseUrl}) => instance;

  final String _baseUrl;
  final http.Client _client = http.Client();

  Timer? _pollTimer;
  bool _connected = false;
  DispenserSnapshot _snapshot = const DispenserSnapshot();

  DispenserSnapshot get snapshot => _snapshot;
  bool get connected => _connected;
  DispenserState get state => _snapshot.state;

  // -- Polling --

  void startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_kPollInterval, (_) => _poll());
    _poll();
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    try {
      final data = await _get('/api/state');
      _snapshot = DispenserSnapshot.fromJson(data);
      _connected = true;
    } catch (e) {
      _connected = false;
      debugPrint('[DispenserService] Poll failed: $e');
    }
    notifyListeners();
  }

  // -- Commands --

  Future<DispenserResult> bindSlot({
    required String patientId,
    required int slotId,
    String patientName = '',
  }) {
    return _post('/api/bind-slot', {
      'patient_id': patientId,
      'slot_id': slotId,
      'patient_name': patientName,
    });
  }

  Future<DispenserResult> scanBarcode(String barcode) {
    return _post('/api/barcode', {'barcode': barcode});
  }

  Future<DispenserResult> commitSlot() {
    return _post('/api/commit-slot', {});
  }

  Future<DispenserResult> triggerDispense({
    String? patientId,
    String? scheduleId,
    int? windowSeconds,
  }) {
    return _post('/api/trigger-dispense', {
      if (patientId != null) 'patient_id': patientId,
      if (scheduleId != null) 'schedule_id': scheduleId,
      if (windowSeconds != null) 'window_seconds': windowSeconds,
    });
  }

  /// Opens the camera / starts face-auth window.
  /// Uses a fresh HTTP client to avoid stale keep-alive connection errors.
  Future<DispenserResult> openCamera({String? patientId}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('$_baseUrl/api/camera/open');
      final response = await client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(
                patientId != null ? {'patient_id': patientId} : {}),
          )
          .timeout(const Duration(seconds: 10));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return DispenserResult.fromJson(data);
    } on TimeoutException {
      return DispenserResult.error('Request timed out');
    } catch (e) {
      return DispenserResult.error('Request failed: $e');
    } finally {
      client.close();
    }
  }

  /// Force an immediate state poll (useful after triggering commands).
  Future<void> poll() => _poll();

  Future<DispenserResult> reset() {
    return _post('/api/reset', {});
  }

  // -- Query endpoints --

  Future<List<Map<String, dynamic>>> getSlots() async {
    final data = await _get('/api/slots');
    return (data['slots'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getSlotMedications(int slotId) async {
    final data = await _get('/api/slots/$slotId/medications');
    return (data['medications'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<List<Map<String, dynamic>>> getFaceAuthLogs({int limit = 20}) async {
    final data = await _get('/api/face-auth-logs?limit=$limit');
    return (data['logs'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<DispenserResult> deleteSlot(int slotId) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/slots/$slotId');
      final response = await _client
          .delete(uri, headers: {'Accept': 'application/json'})
          .timeout(_kTimeout);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return DispenserResult.fromJson(data);
    } on TimeoutException {
      return DispenserResult.error('Request timed out');
    } catch (e) {
      return DispenserResult.error('Request failed: $e');
    }
  }

  Future<DispenserResult> clearFaceAuthLogs() async {
    try {
      final uri = Uri.parse('$_baseUrl/api/face-auth-logs');
      final response = await _client
          .delete(uri, headers: {'Accept': 'application/json'})
          .timeout(_kTimeout);
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return DispenserResult.fromJson(data);
    } on TimeoutException {
      return DispenserResult.error('Request timed out');
    } catch (e) {
      return DispenserResult.error('Request failed: $e');
    }
  }

  // -- HTTP helpers --

  Future<Map<String, dynamic>> _get(String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    final response = await _client
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(_kTimeout);
    if (response.statusCode >= 500) {
      throw Exception('Server error ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<DispenserResult> _post(String path, Map<String, dynamic> body) async {
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_kTimeout);

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return DispenserResult.fromJson(data);
    } on TimeoutException {
      return DispenserResult.error('Request timed out');
    } catch (e) {
      return DispenserResult.error('Request failed: $e');
    }
  }

  @override
  void dispose() {
    stopPolling();
    _client.close();
    super.dispose();
  }
}
