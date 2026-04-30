import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/patient.dart';
import '../services/api_service.dart';
import '../services/dispenser_service.dart' show kPiBaseUrl;

class PatientManagementScreen extends StatefulWidget {
  const PatientManagementScreen({super.key});

  @override
  State<PatientManagementScreen> createState() =>
      _PatientManagementScreenState();
}

class _PatientManagementScreenState extends State<PatientManagementScreen> {
  final _api = ApiService.instance;
  final _http = http.Client();

  List<Patient> _patients = [];
  List<Map<String, dynamic>> _faceUsers = []; // registered faces
  List<Map<String, dynamic>> _patientAccounts = []; // login credentials
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _patients = await _api.getAllPatients();
      await Future.wait([_loadFaceUsers(), _loadPatientAccounts()]);
    } on ApiException catch (e) {
      _error = 'API error ${e.statusCode}: ${e.message}';
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadFaceUsers() async {
    try {
      final uri = Uri.parse('$kPiBaseUrl/api/face/users');
      final resp = await _http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      _faceUsers =
          (data['users'] as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {
      _faceUsers = [];
    }
  }

  Future<void> _loadPatientAccounts() async {
    try {
      _patientAccounts = await _api.getPatientAccounts();
    } catch (_) {
      _patientAccounts = [];
    }
  }

  bool _hasFace(String patientId) =>
      _faceUsers.any((u) => u['patient_id'] == patientId);

  int _sampleCount(String patientId) {
    final u = _faceUsers.where((u) => u['patient_id'] == patientId);
    if (u.isEmpty) return 0;
    return u.first['sample_count'] as int? ?? 0;
  }

  String? _accountEmail(String patientId) {
    final matches = _patientAccounts.where((a) => a['patient_id'] == patientId);
    if (matches.isEmpty) return null;
    return matches.first['email'] as String?;
  }

  // ── Create Login Dialog ───────────────────────────────────────────────────

  void _showCreateLoginDialog(Patient patient) {
    final emailCtrl    = TextEditingController();
    final passCtrl     = TextEditingController();
    final confirmCtrl  = TextEditingController();
    final formKey      = GlobalKey<FormState>();
    bool obscurePass   = true;
    bool obscureConf   = true;
    bool saving        = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.key_rounded),
              const SizedBox(width: 8),
              Expanded(child: Text('Login for ${patient.firstName}')),
            ],
          ),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Email *',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                    validator: (v) {
                      final e = v?.trim() ?? '';
                      if (e.isEmpty) return 'Email required';
                      if (!e.contains('@') || e.startsWith('@')) {
                        return 'Enter a valid email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: passCtrl,
                    obscureText: obscurePass,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Password *',
                      prefixIcon: const Icon(Icons.lock_outline),
                      helperText: 'Min 8 chars, upper, lower, number',
                      suffixIcon: IconButton(
                        icon: Icon(obscurePass
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () =>
                            setDlg(() => obscurePass = !obscurePass),
                      ),
                    ),
                    validator: (v) {
                      final p = v ?? '';
                      if (p.length < 8) return 'Min 8 characters';
                      if (!p.contains(RegExp(r'[A-Z]'))) return 'Need uppercase';
                      if (!p.contains(RegExp(r'[a-z]'))) return 'Need lowercase';
                      if (!p.contains(RegExp(r'[0-9]'))) return 'Need a number';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: confirmCtrl,
                    obscureText: obscureConf,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Confirm Password *',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(obscureConf
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () =>
                            setDlg(() => obscureConf = !obscureConf),
                      ),
                    ),
                    validator: (v) {
                      if (v != passCtrl.text) return 'Passwords do not match';
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      setDlg(() => saving = true);
                      try {
                        final result = await _api.createPatientAccount(
                          patientId: patient.patientId,
                          email: emailCtrl.text.trim(),
                          password: passCtrl.text,
                        );
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        await _loadPatientAccounts();
                        if (mounted) setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(result['ok'] == true
                                ? 'Login created for ${patient.firstName}'
                                : result['message'] as String? ??
                                    'Failed to create login'),
                            backgroundColor: result['ok'] == true
                                ? Colors.green
                                : Colors.red,
                          ),
                        );
                      } catch (e) {
                        setDlg(() => saving = false);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Error: $e')),
                          );
                        }
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create Login'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Add Patient ────────────────────────────────────────────────────────────

  void _showAddEditDialog({Patient? existing}) {
    final firstCtrl = TextEditingController(text: existing?.firstName ?? '');
    final lastCtrl  = TextEditingController(text: existing?.lastName ?? '');
    DateTime? dob   = existing?.dateOfBirth;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(existing == null ? 'Add Patient' : 'Edit Patient'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: firstCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'First Name *'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: lastCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Last Name *'),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Date of Birth'),
                  subtitle: Text(
                    dob != null
                        ? '${dob!.day}/${dob!.month}/${dob!.year}'
                        : 'Not set',
                  ),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: dob ?? DateTime(1980),
                      firstDate: DateTime(1920),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setDlg(() => dob = picked);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final first = firstCtrl.text.trim();
                final last  = lastCtrl.text.trim();
                if (first.isEmpty || last.isEmpty) return;
                Navigator.pop(ctx);

                final dobStr = dob?.toIso8601String().split('T').first;

                try {
                  if (existing == null) {
                    // CREATE → then face registration
                    final newPatient = await _api.createPatient(
                      firstName: first,
                      lastName: last,
                      dateOfBirth: dobStr,
                    );
                    await _loadAll();
                    if (mounted) _startFaceRegistration(newPatient);
                  } else {
                    await _api.updatePatient(
                      patientId: existing.patientId,
                      firstName: first,
                      lastName: last,
                      dateOfBirth: dobStr,
                    );
                    _loadAll();
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: $e')),
                    );
                  }
                }
              },
              child: Text(existing == null ? 'Add & Register Face' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Face Registration ──────────────────────────────────────────────────────

  Future<void> _startFaceRegistration(Patient patient) async {
    bool registering = true;
    String status = 'Position ${patient.fullName} in front of the Pi camera…';

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          if (registering) {
            // Auto-trigger registration
            _doFaceRegister(patient).then((msg) {
              if (ctx.mounted) {
                setDlg(() {
                  registering = false;
                  status = msg;
                });
              }
            });
            registering = false; // only call once
            status = 'Capturing face samples… (stay still)';
          }

          final isDone = !status.startsWith('Capturing');
          final isDuplicate = status.startsWith('duplicate:');

          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  isDone && status.contains('success')
                      ? Icons.check_circle_rounded
                      : isDuplicate
                          ? Icons.block_rounded
                          : isDone
                              ? Icons.error_rounded
                              : Icons.face_rounded,
                  color: isDone && status.contains('success')
                      ? Colors.green
                      : isDuplicate
                          ? Colors.orange
                          : isDone
                              ? Colors.red
                              : Theme.of(ctx).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                const Expanded(child: Text('Face Registration')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isDone)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: LinearProgressIndicator(),
                  ),
                Text(status, style: const TextStyle(fontSize: 14)),
              ],
            ),
            actions: [
              if (isDone) ...[
                if (!status.contains('success'))
                  TextButton(
                    onPressed: () {
                      setDlg(() {
                        registering = true;
                        status = 'Retrying…';
                      });
                    },
                    child: const Text('Retry'),
                  ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _loadAll();
                  },
                  child: const Text('Done'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<String> _doFaceRegister(Patient patient) async {
    try {
      final uri = Uri.parse('$kPiBaseUrl/api/face/register');
      final resp = await _http
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
            }),
          )
          .timeout(const Duration(seconds: 60));

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final ok  = data['ok'] as bool? ?? false;
      final msg = data['message'] as String? ?? 'Unknown';

      // Duplicate face detected — another patient already has this face
      if (data['duplicate_found'] == true) {
        final existing = data['existing_name'] as String? ?? 'another patient';
        return 'duplicate: This face is already registered to $existing. Re-registration blocked.';
      }

      return ok ? 'success: $msg' : 'Failed: $msg';
    } catch (e) {
      return 'Error: $e';
    }
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

  void _deletePatient(Patient patient) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Patient'),
        content: Text(
          'Remove ${patient.fullName} and all their data (medications, face)?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await _api.deletePatient(patient.patientId);
                await _loadAll(); // await so list refreshes before snackbar
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '${patient.fullName} and all their data deleted',
                      ),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Delete failed: $e')),
                  );
                }
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Patient Management'),
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddEditDialog(),
        child: const Icon(Icons.person_add_rounded),
      ),
      body: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadAll,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_patients.isEmpty) {
      return const Center(child: Text('No patients yet. Tap + to add one.'));
    }

    return RefreshIndicator(
      onRefresh: _loadAll,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _patients.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _buildPatientCard(_patients[i], cs),
      ),
    );
  }

  Widget _buildPatientCard(Patient patient, ColorScheme cs) {
    final hasFace    = _hasFace(patient.patientId);
    final samples    = _sampleCount(patient.patientId);
    final loginEmail = _accountEmail(patient.patientId);
    final hasLogin   = loginEmail != null;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name + face status
            Row(
              children: [
                CircleAvatar(
                  backgroundColor:
                      hasFace ? Colors.green.withOpacity(0.15) : cs.primaryContainer,
                  child: Icon(
                    hasFace ? Icons.face_rounded : Icons.person_rounded,
                    color: hasFace ? Colors.green : cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        patient.fullName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (patient.age != null) ...[
                            Text(
                              'Age: ${patient.age}',
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface.withOpacity(0.6),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Icon(
                            hasFace ? Icons.verified_rounded : Icons.no_accounts_rounded,
                            size: 13,
                            color: hasFace ? Colors.green : Colors.orange,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            hasFace ? '$samples samples' : 'No face',
                            style: TextStyle(
                              fontSize: 12,
                              color: hasFace ? Colors.green : Colors.orange,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Login status row
                      Row(
                        children: [
                          Icon(
                            hasLogin ? Icons.login_rounded : Icons.no_encryption_gmailerrorred_rounded,
                            size: 13,
                            color: hasLogin ? cs.primary : cs.onSurface.withOpacity(0.45),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              hasLogin ? loginEmail : 'No login yet',
                              style: TextStyle(
                                fontSize: 12,
                                color: hasLogin
                                    ? cs.primary
                                    : cs.onSurface.withOpacity(0.45),
                                overflow: TextOverflow.ellipsis,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Action buttons row
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                // Scan Face only if not yet registered
                if (!hasFace)
                  OutlinedButton.icon(
                    onPressed: () => _startFaceRegistration(patient),
                    icon: const Icon(Icons.face_rounded, size: 16),
                    label: const Text('Scan Face'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                  ),
                // Create Login only if no account yet
                if (!hasLogin)
                  FilledButton.tonalIcon(
                    onPressed: () => _showCreateLoginDialog(patient),
                    icon: const Icon(Icons.key_rounded, size: 16),
                    label: const Text('Create Login'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                  ),
                // Edit
                IconButton(
                  onPressed: () => _showAddEditDialog(existing: patient),
                  icon: const Icon(Icons.edit_rounded, size: 20),
                  tooltip: 'Edit',
                ),
                // Delete
                IconButton(
                  onPressed: () => _deletePatient(patient),
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 20, color: Colors.redAccent),
                  tooltip: 'Delete',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}
