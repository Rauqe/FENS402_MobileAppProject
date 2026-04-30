import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dispenser_service.dart' show kPiBaseUrl;

const Duration _kAuthTimeout = Duration(seconds: 30);

class AuthResult {
  final bool ok;
  final String message;
  final String? email;
  final String? role;       // "patient" or "caregiver"
  final String? patientId;

  const AuthResult({
    required this.ok,
    required this.message,
    this.email,
    this.role,
    this.patientId,
  });

  bool get isCaregiver => role == 'caregiver';
  bool get isPatient => role == 'patient';

  factory AuthResult.fromJson(Map<String, dynamic> json) {
    return AuthResult(
      ok: json['ok'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      email: json['email'] as String?,
      role: json['role'] as String?,
      patientId: json['patient_id'] as String?,
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

  // ── Sign up ──────────────────────────────────────────────────────────────

  Future<AuthResult> signUp({
    required String email,
    required String password,
    String? modelId,
    String? patientId,
  }) async {
    try {
      final body = <String, dynamic>{
        'email': email.trim(),
        'password': password,
        if (modelId != null && modelId.isNotEmpty) 'model_id': modelId.trim(),
        if (patientId != null) 'patient_id': patientId,
      };

      final resp = await _client
          .post(
            Uri.parse('$kPiBaseUrl/api/auth/signup'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_kAuthTimeout);

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return AuthResult.fromJson(data);
    } catch (e) {
      debugPrint('[AuthService] signUp error: $e');
      return AuthResult.error('Connection failed: $e');
    }
  }

  // ── Login ────────────────────────────────────────────────────────────────

  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$kPiBaseUrl/api/auth/login'),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'email': email.trim(), 'password': password}),
          )
          .timeout(_kAuthTimeout);

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return AuthResult.fromJson(data);
    } catch (e) {
      debugPrint('[AuthService] login error: $e');
      return AuthResult.error('Connection failed: $e');
    }
  }

  // ── Password validation ──────────────────────────────────────────────────

  /// Returns error message if invalid, null if valid.
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
