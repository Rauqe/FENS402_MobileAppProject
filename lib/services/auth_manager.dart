import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Size;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'ble_service.dart';
import '../core/constants/ble_constants.dart';

// ── Auth result types ─────────────────────────────────────────────────────────

enum AuthStatus {
  idle,
  cameraReady,
  detectingFace,
  livenessCheck,
  matchingFace,
  success,
  failedNoFace,
  failedLiveness,
  failedNoMatch,
  error,
}

class AuthResult {
  final AuthStatus status;
  final String? message;

  /// Similarity score 0.0–1.0 (1.0 = perfect match).
  /// Only meaningful when [status] == [AuthStatus.success].
  final double? similarity;

  const AuthResult._({required this.status, this.message, this.similarity});

  factory AuthResult.success(double similarity) =>
      AuthResult._(status: AuthStatus.success, similarity: similarity);

  factory AuthResult.failedNoFace() => AuthResult._(
      status: AuthStatus.failedNoFace,
      message: 'No face detected. Look directly at the camera.');

  factory AuthResult.failedLiveness() => AuthResult._(
      status: AuthStatus.failedLiveness,
      message:
          'Liveness check failed. Please blink and slightly turn your head.');

  factory AuthResult.failedNoMatch() => AuthResult._(
      status: AuthStatus.failedNoMatch,
      message: 'Face does not match the registered patient.');

  factory AuthResult.error(String msg) =>
      AuthResult._(status: AuthStatus.error, message: msg);

  bool get isSuccess => status == AuthStatus.success;
}

// ── AuthManager ───────────────────────────────────────────────────────────────

/// Orchestrates the full authentication pipeline before issuing a BLE UNLOCK
/// command to the Raspberry Pi:
///
///  Camera stream
///      │
///      ▼
///  ML Kit FaceDetector  ──► Liveness check (blink + head-pose)
///      │
///      ▼
///  Face embedding extraction  (TFLite — see NOTE below)
///      │
///      ▼
///  Embedding comparison vs. Local_Users table embedding
///      │
///      ▼
///  BLEService.sendCommand(BleCommand.unlock)  →  Raspberry Pi
///
/// ─────────────────────────────────────────────────────────────────────────────
/// NOTE on face matching:
///   ML Kit FaceDetector returns landmark positions and contours, NOT embeddings.
///   Full face recognition requires a TFLite model (e.g. MobileFaceNet).
///   The [_extractEmbedding] method is a PLACEHOLDER — replace it with:
///     1. Run the camera image through a TFLite interpreter.
///     2. Retrieve the 128-d float output vector.
///   See: https://pub.dev/packages/tflite_flutter
/// ─────────────────────────────────────────────────────────────────────────────
class AuthManager {
  final BLEService _bleService;

  AuthManager({required BLEService bleService}) : _bleService = bleService;

  // ── Auth-status stream ───────────────────────────────────────────────────────

  final _statusController = StreamController<AuthStatus>.broadcast();

  /// Emits [AuthStatus] updates so the UI can show progress (e.g. a spinner,
  /// or "Blink to confirm liveness").
  Stream<AuthStatus> get statusStream => _statusController.stream;

  // ── Camera & detector ────────────────────────────────────────────────────────

  CameraController? _cameraController;
  final _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableLandmarks: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.3,
    ),
  );

  bool _isBusy = false;

  // ── Liveness state ───────────────────────────────────────────────────────────

  bool _blinkDetected = false;
  bool _headMovementDetected = false;

  static const double _eyeClosedProbabilityThreshold = 0.4;
  static const double _headPoseThresholdDeg = 12.0;
  static const double _matchThreshold = 0.75;

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Initialises the front camera and returns the [CameraController] so the
  /// caller can embed a [CameraPreview] widget in the UI.
  Future<CameraController> initCamera() async {
    final cameras = await availableCameras();
    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      front,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    await _cameraController!.initialize();
    return _cameraController!;
  }

  /// Main entry-point: runs the full pipeline.
  ///
  /// [storedEmbedding] is loaded from the Local_Users SQLite table before
  /// this method is called (see LocalDatabase.getFaceEmbedding).
  ///
  /// Returns an [AuthResult]. On success, automatically sends
  /// [BleCommand.unlock] to the Raspberry Pi via [BLEService].
  Future<AuthResult> authenticateAndUnlock({
    required List<double> storedEmbedding,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return AuthResult.error(
          'Camera not initialised. Call initCamera() first.');
    }

    _resetLivenessState();
    _emitStatus(AuthStatus.detectingFace);

    try {
      final result = await _runAuthPipeline(storedEmbedding).timeout(timeout,
          onTimeout: () =>
              AuthResult.error('Authentication timed out. Please try again.'));

      if (result.isSuccess) {
        await _bleService.sendCommand(BleCommand.unlock);
      }

      return result;
    } catch (e) {
      return AuthResult.error('Authentication error: $e');
    } finally {
      _emitStatus(AuthStatus.idle);
    }
  }

  /// Releases resources. Call from the parent widget's dispose().
  Future<void> dispose() async {
    await _cameraController?.stopImageStream();
    await _cameraController?.dispose();
    await _faceDetector.close();
    await _statusController.close();
  }

  // ── Pipeline ─────────────────────────────────────────────────────────────────

  Future<AuthResult> _runAuthPipeline(List<double> storedEmbedding) async {
    final livenessCompleter = Completer<bool>();
    List<double>? liveEmbedding;

    _cameraController!.startImageStream((CameraImage image) async {
      if (_isBusy || livenessCompleter.isCompleted) return;
      _isBusy = true;

      try {
        final inputImage = _convertCameraImage(image);
        if (inputImage == null) return;

        final faces = await _faceDetector.processImage(inputImage);
        if (faces.isEmpty) return;

        final face = faces.first;

        _checkBlink(face);
        _checkHeadMovement(face);

        if (!_blinkDetected) {
          _emitStatus(AuthStatus.livenessCheck);
          return;
        }

        if (!_headMovementDetected) {
          _emitStatus(AuthStatus.livenessCheck);
          return;
        }

        _emitStatus(AuthStatus.matchingFace);
        liveEmbedding = await _extractEmbedding(image, face);

        if (!livenessCompleter.isCompleted) {
          livenessCompleter.complete(true);
        }
      } catch (e) {
        debugPrint('[AuthManager] Frame processing error: $e');
      } finally {
        _isBusy = false;
      }
    });

    final livenessOk = await livenessCompleter.future;
    await _cameraController!.stopImageStream();

    if (!livenessOk) return AuthResult.failedLiveness();
    if (liveEmbedding == null) return AuthResult.failedNoFace();

    final similarity = _cosineSimilarity(liveEmbedding!, storedEmbedding);
    debugPrint('[AuthManager] Face similarity score: $similarity');

    if (similarity >= _matchThreshold) {
      return AuthResult.success(similarity);
    } else {
      return AuthResult.failedNoMatch();
    }
  }

  // ── Liveness helpers ──────────────────────────────────────────────────────────

  void _checkBlink(Face face) {
    final leftEye = face.leftEyeOpenProbability ?? 1.0;
    final rightEye = face.rightEyeOpenProbability ?? 1.0;

    if (leftEye < _eyeClosedProbabilityThreshold &&
        rightEye < _eyeClosedProbabilityThreshold) {
      _blinkDetected = true;
    }
  }

  void _checkHeadMovement(Face face) {
    final yaw = face.headEulerAngleY ?? 0.0;
    final pitch = face.headEulerAngleX ?? 0.0;

    if (yaw.abs() > _headPoseThresholdDeg ||
        pitch.abs() > _headPoseThresholdDeg) {
      _headMovementDetected = true;
    }
  }

  void _resetLivenessState() {
    _blinkDetected = false;
    _headMovementDetected = false;
    _isBusy = false;
  }

  // ── Embedding extraction (PLACEHOLDER) ────────────────────────────────────────

  /// PLACEHOLDER: ML Kit does NOT produce face embeddings.
  ///
  /// Replace this method with a TFLite interpreter call:
  /// ```dart
  /// final interpreter = await Interpreter.fromAsset('mobilefacenet.tflite');
  /// // ... preprocess image, run interpreter, return output vector
  /// ```
  /// The output should be a normalised 128-d (or 512-d) float vector.
  Future<List<double>> _extractEmbedding(CameraImage image, Face face) async {
    // TODO: Replace with actual TFLite model inference.
    debugPrint('[AuthManager] WARNING: Using placeholder embedding — '
        'replace _extractEmbedding() with TFLite inference.');
    final rng = math.Random(face.boundingBox.hashCode);
    return List.generate(128, (_) => rng.nextDouble());
  }

  // ── Cosine similarity ─────────────────────────────────────────────────────────

  double _cosineSimilarity(List<double> a, List<double> b) {
    assert(a.length == b.length, 'Embedding lengths must match');

    double dot = 0, normA = 0, normB = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  // ── Camera image conversion ───────────────────────────────────────────────────

  InputImage? _convertCameraImage(CameraImage image) {
    final camera = _cameraController!.description;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: _rotationFromCamera(camera.sensorOrientation),
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  InputImageRotation _rotationFromCamera(int sensorOrientation) {
    switch (sensorOrientation) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  void _emitStatus(AuthStatus status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }
}
