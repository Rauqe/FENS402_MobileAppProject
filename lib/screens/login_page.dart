import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../models/patient.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../core/app_session.dart';
import 'patient_dashboard.dart';
import 'caregiver_dashboard.dart';
import 'signup_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl    = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _obscurePassword = true;
  bool _isLoading       = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _onLoginPressed() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final email    = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    try {
      final result = await AuthService.instance.login(
        email: email,
        password: password,
      );

      if (!mounted) return;

      if (!result.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }

      // Register FCM token with email for both caregiver and patient
      try {
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null) {
          await ApiService.registerFcmToken(token, email: email);
          debugPrint('[FCM] Token registered for $email');
        }
      } catch (e) {
        debugPrint('[FCM] Token registration failed: $e');
      }

      if (result.isCaregiver) {
        AppSession.instance.loginAsCaregiver();
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const CaregiverDashboard()),
          (_) => false,
        );
      } else {
        // Fetch full patient object linked to this account
        final patients = await ApiService.instance.getAllPatients();
        if (!mounted) return;

        Patient? patient;
        if (result.patientId != null && result.patientId!.isNotEmpty) {
          try {
            patient = patients.firstWhere(
              (p) => p.patientId == result.patientId,
            );
          } catch (_) {}
        }

        // Fallback: let user pick if ID not found
        if (patient == null) {
          if (patients.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('No patients found. Ask caregiver to add you.'),
              ),
            );
            return;
          }
          patient = await _showPatientPickerDialog(patients);
          if (!mounted || patient == null) return;
        }

        AppSession.instance.loginAsPatient(patient);
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const PatientDashboard()),
          (_) => false,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Login error: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<Patient?> _showPatientPickerDialog(List<Patient> patients) {
    return showDialog<Patient>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Your Profile'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: patients.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = patients[i];
              return ListTile(
                leading: CircleAvatar(
                  child: Text(
                    p.firstName.isNotEmpty ? p.firstName[0].toUpperCase() : '?',
                  ),
                ),
                title: Text(p.fullName),
                subtitle: Text(
                  p.patientId,
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () => Navigator.of(ctx).pop(p),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(cs),
                  const SizedBox(height: 36),
                  _buildLoginForm(theme, cs),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    return Column(
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(
            Icons.medication_rounded,
            size: 44,
            color: cs.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'MediDispense',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Sign in to your smart medication system',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: cs.onSurface.withOpacity(0.6),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginForm(ThemeData theme, ColorScheme cs) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email',
              hintText: 'example@mail.com',
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
          const SizedBox(height: 16),

          TextFormField(
            controller: _passwordCtrl,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onFieldSubmitted: (_) => _onLoginPressed(),
            decoration: InputDecoration(
              labelText: 'Password',
              hintText: '••••••••',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Password required';
              return null;
            },
          ),
          const SizedBox(height: 28),

          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _isLoading ? null : _onLoginPressed,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text('Sign in', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 28),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Don\'t have an account?',
                style: TextStyle(color: cs.onSurface.withOpacity(0.7)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SignUpPage()),
                ),
                child: const Text('Sign up'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}