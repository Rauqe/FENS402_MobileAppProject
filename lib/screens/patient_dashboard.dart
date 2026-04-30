import 'package:flutter/material.dart';
import 'login_page.dart';
import '../core/app_session.dart';
import '../core/bridge_test_state.dart';
import '../core/constants/ble_constants.dart';
import '../models/medication_schedule.dart';
import '../services/ble_service.dart';
import '../services/api_service.dart';
import '../services/dispenser_service.dart';

class PatientDashboard extends StatefulWidget {
  const PatientDashboard({super.key});

  @override
  State<PatientDashboard> createState() => _PatientDashboardState();
}

class _PatientDashboardState extends State<PatientDashboard> {
  final _api = ApiService.instance;
  final _dispenser = DispenserService();
  BLEService? _ble;
  bool _bleConnected = false;
  List<MedicationSchedule> _schedules = [];
  bool _loading = true;
  String? _error;
  String? _dispensingScheduleId;

  String get _patientId => AppSession.instance.currentPatientId ?? '';

  @override
  void initState() {
    super.initState();
    _loadSchedules();
  }

  Future<void> _loadSchedules() async {
    if (_patientId.isEmpty) {
      setState(() {
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _schedules = await _api.getPatientSchedules(_patientId);
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        _schedules = [];
      } else {
        _error = e.message;
      }
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Medications'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded),
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
        onRefresh: _loadSchedules,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildStatusCard(colorScheme),
              const SizedBox(height: 14),
              _buildBridgeTestBanner(colorScheme),
              const SizedBox(height: 20),
              Text(
                'Today\'s Schedule',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              _buildScheduleSection(colorScheme),
              const SizedBox(height: 24),
              Text(
                'Quick Actions',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _buildActionCard(
                      colorScheme,
                      icon: Icons.history_rounded,
                      label: 'History',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildActionCard(
                      colorScheme,
                      icon: Icons.bluetooth_connected_rounded,
                      label: 'Device',
                      onTap: () => _runBridgeUnlockTest(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildActionCard(
                      colorScheme,
                      icon: Icons.notifications_outlined,
                      label: 'Alerts',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScheduleSection(ColorScheme colorScheme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_schedules.isEmpty && _patientId.isEmpty) {
      return Column(
        children: [
          _buildMedicationTile(colorScheme,
              time: '08:00', name: 'Aspirin 100mg', status: 'Taken', taken: true),
          const SizedBox(height: 10),
          _buildMedicationTile(colorScheme,
              time: '14:00', name: 'Metformin 500mg', status: 'Upcoming', taken: false),
          const SizedBox(height: 10),
          _buildMedicationTile(colorScheme,
              time: '21:00', name: 'Lisinopril 10mg', status: 'Upcoming', taken: false),
          const SizedBox(height: 8),
          Text(
            'Showing demo data — set patient ID for real schedules',
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: colorScheme.onSurface.withOpacity(0.4),
            ),
          ),
        ],
      );
    }

    if (_schedules.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No schedules for today.')),
      );
    }

    return Column(
      children: _schedules.map((s) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildMedicationTile(
            colorScheme,
            time: s.formattedTime,
            name: s.medicationsSummary,
            status: s.isActive ? 'Upcoming' : 'Inactive',
            taken: false,
            schedule: s,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildStatusCard(ColorScheme colorScheme) {
    final takenCount =
        _schedules.isEmpty && _patientId.isEmpty ? 1 : 0;
    final totalCount =
        _schedules.isEmpty && _patientId.isEmpty ? 3 : _schedules.length;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: colorScheme.primary,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              Icons.medication_rounded,
              color: colorScheme.onPrimary,
              size: 30,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppSession.instance.currentPatient?.fullName ?? 'My Medications',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$takenCount of $totalCount medications taken today',
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onPrimaryContainer.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMedicationTile(
    ColorScheme colorScheme, {
    required String time,
    required String name,
    required String status,
    required bool taken,
    MedicationSchedule? schedule,
  }) {
    final bool isDispensing = schedule != null &&
        _dispensingScheduleId == schedule.scheduleId;
    final bool canDispense = schedule != null &&
        schedule.isActive &&
        !taken &&
        _patientId.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: taken
            ? colorScheme.primaryContainer.withOpacity(0.4)
            : colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: taken
              ? colorScheme.primary.withOpacity(0.3)
              : colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                taken ? Icons.check_circle_rounded : Icons.access_time_rounded,
                color: taken ? colorScheme.primary : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      time,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: taken
                      ? colorScheme.primary.withOpacity(0.15)
                      : colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color:
                        taken ? colorScheme.primary : colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (canDispense) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isDispensing
                    ? null
                    : () => _triggerDispense(schedule),
                icon: isDispensing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.medication_liquid_rounded, size: 18),
                label: Text(isDispensing ? 'Dispensing...' : 'Take Medication'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Dispense logic ──────────────────────────────────────────────────────

  Future<void> _ensureBleConnected() async {
    if (_bleConnected && _ble != null) return;
    _ble = BLEService();
    try {
      await _ble!.startScanAndConnect();
      _bleConnected = true;
    } catch (e) {
      _ble = null;
      _bleConnected = false;
      rethrow;
    }
  }

  Future<void> _triggerDispense(MedicationSchedule schedule) async {
    if (_patientId.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _dispensingScheduleId = schedule.scheduleId);

    try {
      messenger.showSnackBar(
        const SnackBar(content: Text('Triggering dispense...')),
      );

      // Use REST API (Pi Flask server) as primary method
      final result = await _dispenser.triggerDispense(
        patientId: _patientId,
        scheduleId: schedule.scheduleId,
      );

      messenger.clearSnackBars();
      if (result.ok) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Dispense triggered — face the camera'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text(result.message)),
        );
      }
    } catch (e) {
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(content: Text('Dispense error: $e')),
      );
    } finally {
      if (mounted) setState(() => _dispensingScheduleId = null);
    }
  }

  @override
  void dispose() {
    // Singleton dispose edilmez — lifecycle observer yönetir
    _ble?.disconnect();
    _ble?.dispose();
    super.dispose();
  }

  Widget _buildActionCard(
    ColorScheme colorScheme, {
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final card = Container(
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
    );

    if (onTap == null) return card;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: card,
    );
  }

  Future<void> _runBridgeUnlockTest(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ble = BLEService();

    try {
      await ble.startScanAndConnect();
      await ble.sendCommand(BleCommand.unlock);

      if (BridgeTestState.verified.value) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Bridge test: Verified (0xA5)')),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              BridgeTestState.message.value.isNotEmpty
                  ? BridgeTestState.message.value
                  : 'Bridge test failed',
            ),
          ),
        );
      }
    } catch (e) {
      BridgeTestState.message.value = 'Bridge test error: $e';
      messenger.showSnackBar(
        SnackBar(content: Text(BridgeTestState.message.value)),
      );
    } finally {
      await ble.disconnect();
      ble.dispose();
    }
  }

  Widget _buildBridgeTestBanner(ColorScheme colorScheme) {
    return ValueListenableBuilder<bool>(
      valueListenable: BridgeTestState.verified,
      builder: (context, verified, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: verified
                ? colorScheme.primaryContainer.withOpacity(0.25)
                : colorScheme.surfaceContainerHighest.withOpacity(0.6),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: verified
                  ? colorScheme.primary.withOpacity(0.35)
                  : colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Icon(
                verified
                    ? Icons.check_circle_rounded
                    : Icons.sync_disabled,
                color: verified
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  verified
                      ? 'Bridge Test: Verified'
                      : 'Bridge Test: Not verified',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
