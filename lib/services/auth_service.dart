import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const Duration _kAuthTimeout = Duration(seconds: 30);
const String kAwsApiBaseUrl =
    'https://s766ccq1c7.execute-api.eu-north-1.amazonaws.com/default';

class AuthResult {
  final bool ok;
  final String message;
  final String? email;
  final String? role; // "patient" or "caregiver"
  final String? patientId;
  final String? caregiverId;

  const AuthResult({
    required this.ok,
    required this.message,
    this.email,
    this.role,
    this.patientId,
    this.caregiverId,
  });

  bool get isCaregiver => role == 'caregiver';
  bool get isPatient => role == 'patient';

  factory AuthResult.fromCaregiverJson(Map<String, dynamic> json) {
    return AuthResult(
      ok: json['ok'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      email: json['email'] as String?,
      role: 'caregiver',
      caregiverId: json['caregiver_id']?.toString(),
    );
  }

  factory AuthResult.fromPatientJson(Map<String, dynamic> json) {
    return AuthResult(
      ok: json['ok'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      email: json['email'] as String?,
      role: 'patient',
      patientId: json['patient_id']?.toString(),
    );
  }

  factory AuthResult.error(String msg) {
    return AuthResult(ok: false, message: msg);
  }
}

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final _client = http.Client();

  // ── Caregiver Sign Up → AWS ──────────────────────────────────────────────

  Future<AuthResult> signUp({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    String? modelId,
  }) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$kAwsApiBaseUrl/auth/caregiver/signup'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'email': email.trim(),
              'password': password,
              'first_name': firstName.trim(),
              'last_name': lastName.trim(),
              if (modelId != null && modelId.isNotEmpty)
                'model_id': modelId.trim(),
            }),
          )
          .timeout(_kAuthTimeout);

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return AuthResult.fromCaregiverJson(data);
    } catch (e) {
      debugPrint('[AuthService] signUp error: $e');
      return AuthResult.error('Connection failed: $e');
    }
  }

  // ── Login → önce caregiver, sonra patient dener ──────────────────────────

  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    final body = jsonEncode({'email': email.trim(), 'password': password});
    const headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };

    // 1) Caregiver login dene
    try {
      final resp = await _client
          .post(
            Uri.parse('$kAwsApiBaseUrl/auth/caregiver/login'),
            headers: headers,
            body: body,
          )
          .timeout(_kAuthTimeout);

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (data['ok'] == true) {
          debugPrint('[AuthService] Caregiver login OK');
          return AuthResult.fromCaregiverJson(data);
        }
      }
    } catch (e) {
      debugPrint('[AuthService] caregiver login attempt failed: $e');
    }

    // 2) Patient login dene
    try {
      final resp = await _client
          .post(
            Uri.parse('$kAwsApiBaseUrl/auth/patient/login'),
            headers: headers,
            body: body,
          )
          .timeout(_kAuthTimeout);

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      debugPrint('[AuthService] Patient login result: ${data['ok']}');
      return AuthResult.fromPatientJson(data);
    } catch (e) {
      debugPrint('[AuthService] patient login error: $e');
      return AuthResult.error('Connection failed: $e');
    }
  }

  // ── Password validation ──────────────────────────────────────────────────

  static String? validatePassword(String password) {
    if (password.length < 8) return 'Must be at least 8 characters';
    if (!password.contains(RegExp(r'[A-Z]'))) {
      return 'Must contain at least one uppercase letter';
    }
    if (!password.contains(RegExp(r'[a-z]'))) {
      return 'Must contain at least one lowercase letter';
    }
    if (!password.contains(RegExp(r'[0-9]'))) {
      return 'Must contain at least one number';
    }
    return null;
  }
}