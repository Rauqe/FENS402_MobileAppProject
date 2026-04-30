import 'package:flutter/material.dart';
import 'login_page.dart';
import 'patient_management.dart';
import 'drug_management.dart';
import 'schedule_management.dart';
import 'dispenser_control.dart';
import 'face_registration.dart';
import '../models/patient.dart';
import '../services/api_service.dart';
import '../core/app_session.dart';

class CaregiverDashboard extends StatefulWidget {
  const CaregiverDashboard({super.key});

  @override
  State<CaregiverDashboard> createState() => _CaregiverDashboardState();
}

class _CaregiverDashboardState extends State<CaregiverDashboard> {
  final _api = ApiService.instance;
  List<Patient> _patients = [];
  bool _loading = true;
  String? _loadError;

  // Pi connectivity
  bool _piOnline = false;

  // Sync state
  bool _syncing = false;
  bool? _syncOk;
  String? _lastSyncAt;
  int _pendingLogs = 0;
  bool _cloudConfigured = false;

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadSyncStatus();
    _checkPiHealth();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      _patients = await _api.getAllPatients();
    } catch (e) {
      _loadError = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _checkPiHealth() async {
    final ok = await _api.healthCheck();
    if (mounted) setState(() => _piOnline = ok);
  }

  Future<void> _loadSyncStatus() async {
    try {
      final status = await _api.getSyncStatus();
      if (mounted) {
        setState(() {
          _cloudConfigured = status['configured'] == true;
          _pendingLogs = status['pending_logs'] as int? ?? 0;
          _lastSyncAt = status['last_sync_at'] as String?;
        });
      }
    } catch (_) {}
  }

  Future<void> _triggerSync() async {
    setState(() => _syncing = true);
    try {
      final result = await _api.triggerSync();
      final ok = result['ok'] == true;
      if (mounted) {
        setState(() {
          _syncOk = ok;
          _lastSyncAt = result['synced_at'] as String?;
          _pendingLogs = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok
                ? 'Sync completed successfully'
                : 'Sync completed with errors'),
            backgroundColor: ok ? Colors.green : Colors.orange,
          ),
        );
        _loadData();
        _loadSyncStatus();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _syncOk = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Sync failed: $e'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _formatSyncTime(String? iso) {
    if (iso == null) return 'Never';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Caregiver Panel'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () {
              _loadData();
              _checkPiHealth();
              _loadSyncStatus();
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: 'Logout',
            onPressed: () {
              AppSession.instance.logout();
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginPage()),
                (_) => false,
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildOverviewCards(colorScheme),
              const SizedBox(height: 16),
              _buildSyncCard(colorScheme),
              const SizedBox(height: 24),
              Text(
                'Patients',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Center(
                    child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ))
              else if (_loadError != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(Icons.cloud_off_rounded,
                              color: colorScheme.error, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Could not load patients: $_loadError',
                              style: TextStyle(
                                  color: colorScheme.error, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _loadData,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              else if (_patients.isEmpty)
                const Center(
                    child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No patients found. Add patients first.'),
                ))
              else
                ..._patients.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _buildPatientTile(colorScheme, patient: p),
                    )),
              const SizedBox(height: 24),
              Text(
                'Management',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildNavCard(
                      context,
                      colorScheme,
                      icon: Icons.people_rounded,
                      label: 'Patients',
                      destination: const PatientManagementScreen(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildNavCard(
                      context,
                      colorScheme,
                      icon: Icons.medication_rounded,
                      label: 'Drugs',
                      destination: const DrugManagementScreen(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildNavCard(
                      context,
                      colorScheme,
                      icon: Icons.schedule_rounded,
                      label: 'Schedules',
                      destination: const ScheduleManagementScreen(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildNavCard(
                      context,
                      colorScheme,
                      icon: Icons.precision_manufacturing_rounded,
                      label: 'Dispenser',
                      destination: const DispenserControlScreen(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildNavCard(
                      context,
                      colorScheme,
                      icon: Icons.face_rounded,
                      label: 'Faces',
                      destination: const FaceRegistrationScreen(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverviewCards(ColorScheme colorScheme) {
    return Row(
      children: [
        Expanded(
          child: _buildStatCard(
            colorScheme,
            title: 'Patients',
            value: _loading ? '—' : '${_patients.length}',
            icon: Icons.people_rounded,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildStatCard(
            colorScheme,
            title: 'Pi Status',
            value: _piOnline ? 'Online' : 'Offline',
            icon: _piOnline
                ? Icons.check_circle_rounded
                : Icons.cancel_rounded,
            valueColor: _piOnline ? Colors.green : Colors.red,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(
    ColorScheme colorScheme, {
    required String title,
    required String value,
    required IconData icon,
    Color? valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(icon,
              size: 26,
              color: valueColor ?? colorScheme.onPrimaryContainer),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: value.length > 7 ? 14 : 22,
              fontWeight: FontWeight.bold,
              color: valueColor ?? colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onPrimaryContainer.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPatientTile(ColorScheme colorScheme,
      {required Patient patient}) {
    final initials = '${patient.firstName.isNotEmpty ? patient.firstName[0] : ''}${patient.lastName.isNotEmpty ? patient.lastName[0] : ''}'.toUpperCase();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: colorScheme.primaryContainer,
            child: Text(
              initials,
              style: TextStyle(
                color: colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  patient.fullName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: colorScheme.onSurface,
                  ),
                ),
                if (patient.age != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${patient.age} years old',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _buildSyncCard(ColorScheme cs) {
    final Color dotColor;
    final String statusLabel;

    if (!_cloudConfigured) {
      dotColor = Colors.grey;
      statusLabel = 'Not configured';
    } else if (_syncOk == true) {
      dotColor = Colors.green;
      statusLabel = 'Synced';
    } else if (_syncOk == false) {
      dotColor = Colors.orange;
      statusLabel = 'Partial sync';
    } else {
      dotColor = Colors.blue;
      statusLabel = 'Ready';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_sync_rounded,
              color: _cloudConfigured ? cs.primary : Colors.grey, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: dotColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: cs.onSurface,
                      ),
                    ),
                    if (_pendingLogs > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$_pendingLogs pending',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.orange,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Last sync: ${_formatSyncTime(_lastSyncAt)}',
                  style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurface.withOpacity(0.55)),
                ),
              ],
            ),
          ),
          _syncing
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton.filledTonal(
                  tooltip: 'Sync now',
                  icon: const Icon(Icons.sync_rounded, size: 20),
                  onPressed: _cloudConfigured ? _triggerSync : null,
                ),
        ],
      ),
    );
  }

  Widget _buildNavCard(
    BuildContext context,
    ColorScheme colorScheme, {
    required IconData icon,
    required String label,
    required Widget destination,
  }) {
    return GestureDetector(
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => destination),
        );
        await _loadData();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            Icon(icon, size: 28, color: colorScheme.primary),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
