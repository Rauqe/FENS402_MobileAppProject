import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/dispenser_service.dart';
import '../services/api_service.dart';
import '../models/patient.dart';

class FaceRegistrationScreen extends StatefulWidget {
  const FaceRegistrationScreen({super.key});

  @override
  State<FaceRegistrationScreen> createState() => _FaceRegistrationScreenState();
}

class _FaceRegistrationScreenState extends State<FaceRegistrationScreen> {
  final _api = ApiService.instance;
  final _client = http.Client();

  List<Patient> _patients = [];
  List<Map<String, dynamic>> _registeredUsers = [];
  bool _loading = true;
  bool _registering = false;
  String? _registerStatus;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      _patients = await _api.getAllPatients();
      await _loadRegisteredUsers();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadRegisteredUsers() async {
    try {
      final uri = Uri.parse('$kPiBaseUrl/api/face/users');
      final resp = await _client
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      _registeredUsers =
          (data['users'] as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {
      _registeredUsers = [];
    }
  }

  Future<void> _registerFace(Patient patient) async {
    setState(() {
      _registering = true;
      _registerStatus = 'Starting Pi camera for ${patient.fullName}...';
    });

    try {
      final uri = Uri.parse('$kPiBaseUrl/api/face/register');
      final resp = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'patient_id': patient.patientId,
              'first_name': patient.firstName,
              'last_name': patient.lastName,
              'samples': 5,
              'allow_duplicate': false,
            }),
          )
          .timeout(const Duration(seconds: 60));

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final ok = data['ok'] as bool? ?? false;
      final msg = data['message'] as String? ?? 'Unknown result';
      final duplicateFound = data['duplicate_found'] as bool? ?? false;

      if (mounted) {
        setState(() => _registerStatus = duplicateFound ? 'Blocked: duplicate face' : msg);

        if (duplicateFound) {
          final existingName = data['existing_name'] as String? ?? 'Unknown';
          final distance = (data['similarity_distance'] as num?)?.toDouble() ?? 0.0;
          _showDuplicateDialog(context, existingName, distance);
          return;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: ok ? Colors.green : Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        if (ok) await _loadRegisteredUsers();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _registerStatus = 'Error: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Registration failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  void _showDuplicateDialog(
    BuildContext context,
    String existingName,
    double distance,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.block_rounded, color: Colors.orange.shade700),
            const SizedBox(width: 10),
            const Expanded(child: Text('Registration Blocked')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This face is already registered to another patient:'),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.07),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    existingName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Match score: ${((1 - distance) * 100).toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Re-registration is not allowed when the face belongs to a different patient.',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  int _getSampleCount(String patientId) {
    final user = _registeredUsers.where((u) => u['patient_id'] == patientId);
    if (user.isEmpty) return 0;
    return user.first['sample_count'] as int? ?? 0;
  }

  bool _isRegistered(String patientId) {
    return _registeredUsers.any((u) => u['patient_id'] == patientId);
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Face Registration'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadData,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Info card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded,
                            color: cs.onPrimaryContainer),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Select a patient below to register their face using the Pi camera. '
                            'The patient must stand in front of the dispenser camera.',
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Registration status
                  if (_registerStatus != null) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _registering
                            ? Colors.amber.withOpacity(0.1)
                            : cs.surfaceContainerHighest.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          if (_registering)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Icon(Icons.camera_alt_rounded,
                                size: 18, color: cs.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(_registerStatus!,
                                style: const TextStyle(fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Registered count
                  Text(
                    'Registered: ${_registeredUsers.length} face(s)',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),

                  // Patient list
                  if (_patients.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No patients found. Add patients first.',
                          style:
                              TextStyle(color: cs.onSurface.withOpacity(0.5)),
                        ),
                      ),
                    )
                  else
                    ..._patients.map((p) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _buildPatientCard(cs, p),
                        )),
                ],
              ),
            ),
    );
  }

  Widget _buildPatientCard(ColorScheme cs, Patient patient) {
    final registered = _isRegistered(patient.patientId);
    final samples = _getSampleCount(patient.patientId);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: registered
            ? Colors.green.withOpacity(0.05)
            : cs.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: registered
              ? Colors.green.withOpacity(0.3)
              : cs.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor:
                registered ? Colors.green.withOpacity(0.15) : cs.primaryContainer,
            child: Icon(
              registered ? Icons.face_rounded : Icons.person_rounded,
              color: registered ? Colors.green : cs.primary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(patient.fullName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  registered
                      ? '$samples sample(s) registered'
                      : 'Not registered',
                  style: TextStyle(
                    fontSize: 12,
                    color: registered
                        ? Colors.green
                        : cs.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
          if (!registered)
            FilledButton.tonalIcon(
              onPressed: _registering ? null : () => _registerFace(patient),
              icon: const Icon(Icons.camera_alt_rounded),
              label: const Text('Register'),
            )
          else
            Icon(Icons.check_circle_rounded,
                color: Colors.green.shade600, size: 28),
        ],
      ),
    );
  }
}
