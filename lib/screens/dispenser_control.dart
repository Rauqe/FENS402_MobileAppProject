import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/dispenser_service.dart';
import 'live_kvs_viewer.dart';

class DispenserControlScreen extends StatefulWidget {
  const DispenserControlScreen({super.key});

  @override
  State<DispenserControlScreen> createState() => _DispenserControlScreenState();
}

class _DispenserControlScreenState extends State<DispenserControlScreen> {
  final _dispenser = DispenserService();
  final _api       = ApiService.instance;

  List<Map<String, dynamic>> _slots    = [];
  List<Map<String, dynamic>> _authLogs = [];
  Map<String, String>        _patientNames = {};
  bool _loadingSlots = false;

  @override
  void initState() {
    super.initState();
    _dispenser.addListener(_onStateChange);
    _dispenser.startPolling();
    _loadAll();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadSlots(), _loadAuthLogs()]);
  }

  Future<void> _loadSlots() async {
    setState(() => _loadingSlots = true);
    try {
      final patients = await _api.getAllPatients();
      final names = <String, String>{};
      for (final p in patients) {
        names[p.patientId] = p.fullName;
      }
      final slots = await _dispenser.getSlots();
      if (mounted) {
        setState(() {
          _patientNames = names;
          _slots        = slots;
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingSlots = false);
  }

  Future<void> _loadAuthLogs() async {
    try {
      _authLogs = await _dispenser.getFaceAuthLogs(limit: 10);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _deleteSlot(int slotId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Slot Binding?'),
        content: Text('Slot $slotId binding will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await _dispenser.deleteSlot(slotId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
      if (result.ok) _loadSlots();
    }
  }

  Future<void> _clearAuthLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Logs?'),
        content: const Text('All face auth log entries will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await _dispenser.clearFaceAuthLogs();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
      if (result.ok) _loadAuthLogs();
    }
  }

  Future<void> _reset() async {
    final result = await _dispenser.reset();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.message)));
      _loadSlots();
    }
  }

  /// **Open Camera** — caregiver watches the live Pi feed via AWS Kinesis Video
  /// (HLS from `/stream/live`). Does not call the Pi BLE/API camera endpoint.
  Future<void> _openCamera() async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
    try {
      final hlsUrl = await _api.getLiveStreamHlsUrl();
      if (mounted) Navigator.of(context).pop();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => LiveKvsViewerScreen(hlsUrl: hlsUrl),
        ),
      );
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open live stream: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _dispenser.removeListener(_onStateChange);
    // Singleton dispose edilmez — lifecycle observer yönetir
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final snap  = _dispenser.snapshot;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dispenser Control'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadAll,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Connection + state card ─────────────────────────────
              _buildConnectionCard(cs, snap),
              const SizedBox(height: 16),

              // ── Action buttons ──────────────────────────────────────
              _buildActionButtons(cs, snap),
              const SizedBox(height: 24),

              // ── Slot bindings ───────────────────────────────────────
              _buildSectionHeader(
                theme,
                icon: Icons.inventory_2_rounded,
                title: 'Slot Bindings',
                trailing: _loadingSlots
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
              const SizedBox(height: 10),

              // Stats row (only if slots exist)
              if (_slots.isNotEmpty) ...[
                _buildSlotStats(cs),
                const SizedBox(height: 12),
              ],

              if (_loadingSlots)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_slots.isEmpty)
                _buildEmptyCard(cs, Icons.inbox_outlined, 'No slots assigned yet')
              else
                ..._slots.map((s) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _buildSlotCard(cs, theme, s),
                    )),

              const SizedBox(height: 24),

              // ── Face auth logs ──────────────────────────────────────
              _buildSectionHeader(
                theme,
                icon: Icons.face_rounded,
                title: 'Face Auth Logs',
                trailing: _authLogs.isNotEmpty
                    ? TextButton.icon(
                        onPressed: _clearAuthLogs,
                        icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                        label: const Text('Clear'),
                        style: TextButton.styleFrom(
                          foregroundColor: cs.error,
                          visualDensity: VisualDensity.compact,
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 10),

              if (_authLogs.isEmpty)
                _buildEmptyCard(cs, Icons.history_toggle_off_rounded, 'No auth attempts yet')
              else
                ..._authLogs.map((log) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildAuthLogTile(cs, log),
                    )),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ── Section header ─────────────────────────────────────────────────────────

  Widget _buildSectionHeader(ThemeData theme,
      {required IconData icon,
      required String title,
      Widget? trailing}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const Spacer(),
        if (trailing != null) trailing,
      ],
    );
  }

  // ── Connection card ────────────────────────────────────────────────────────

  Widget _buildConnectionCard(ColorScheme cs, DispenserSnapshot snap) {
    final connected  = _dispenser.connected;
    final stateLabel = _stateDisplayName(snap.state);
    final stateColor = _stateColor(snap.state);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: connected
              ? [cs.primaryContainer, cs.primaryContainer.withOpacity(0.6)]
              : [cs.errorContainer, cs.errorContainer.withOpacity(0.6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          // Icon
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (connected ? cs.primary : cs.error).withOpacity(0.15),
            ),
            child: Icon(
              connected ? Icons.link_rounded : Icons.link_off_rounded,
              color: connected ? cs.primary : cs.error,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? 'Pi Connected' : 'Pi Disconnected',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: connected ? cs.onPrimaryContainer : cs.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  kPiBaseUrl,
                  style: TextStyle(
                    fontSize: 11,
                    color: (connected ? cs.onPrimaryContainer : cs.onErrorContainer)
                        .withOpacity(0.65),
                  ),
                ),
              ],
            ),
          ),
          // State badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: stateColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: stateColor.withOpacity(0.4), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: stateColor,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  stateLabel,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: stateColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Action buttons ─────────────────────────────────────────────────────────

  Widget _buildActionButtons(ColorScheme cs, DispenserSnapshot snap) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: snap.state == DispenserState.idle ? null : _reset,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Reset'),
            style: FilledButton.styleFrom(
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
              disabledBackgroundColor: cs.error.withOpacity(0.3),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: _openCamera,
            icon: const Icon(Icons.camera_alt_rounded, size: 18),
            label: const Text('Open Camera'),
          ),
        ),
      ],
    );
  }

  // ── Slot stats bar ─────────────────────────────────────────────────────────

  Widget _buildSlotStats(ColorScheme cs) {
    final total      = _slots.length;
    final loaded     = _slots.where((s) => s['slot_status'] == 'loaded').length;
    final dispensed  = _slots.where((s) => s['slot_status'] == 'dispensed').length;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _statItem(cs, '$total', 'Slots', Icons.grid_view_rounded),
          _statDivider(cs),
          _statItem(cs, '$loaded', 'Loaded', Icons.check_circle_rounded,
              color: loaded > 0 ? Colors.green : null),
          _statDivider(cs),
          _statItem(cs, '$dispensed', 'Dispensed', Icons.outbox_rounded,
              color: dispensed > 0 ? Colors.blue : null),
        ],
      ),
    );
  }

  Widget _statItem(ColorScheme cs, String value, String label, IconData icon,
      {Color? color}) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 16, color: color ?? cs.onSurfaceVariant),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: color ?? cs.onSurface,
            ),
          ),
          Text(label,
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _statDivider(ColorScheme cs) {
    return Container(width: 1, height: 36, color: cs.outlineVariant);
  }

  // ── Slot card ──────────────────────────────────────────────────────────────

  Widget _buildSlotCard(
      ColorScheme cs, ThemeData theme, Map<String, dynamic> slot) {
    final slotStatus  = slot['slot_status'] as String? ?? 'empty';
    final patientId   = slot['patient_id'] as String? ?? '';
    final patientName = _patientNames[patientId] ?? _truncateId(patientId);
    final slotId      = slot['slot_id'] as int;
    final updatedAt   = slot['updated_at'] as String? ?? '';
    final plannedTime = slot['planned_time'] as String? ?? '';
    final meds        = (slot['medications'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>() ??
        <Map<String, dynamic>>[];

    final statusColor = _slotStatusColor(slotStatus);
    final statusLabel = _slotStatusLabel(slotStatus);

    return GestureDetector(
      onTap: () => _showSlotDetail(slot),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: slotStatus == 'loaded'
                ? Colors.green.withOpacity(0.35)
                : cs.outlineVariant,
            width: slotStatus == 'loaded' ? 1.5 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Slot number circle
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: statusColor.withOpacity(0.12),
                border: Border.all(
                  color: statusColor.withOpacity(0.5),
                  width: 1.5,
                ),
              ),
              child: Center(
                child: Text(
                  '$slotId',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                    color: statusColor.withOpacity(0.85),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),

            // Main info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Patient name + status badge
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          patientName,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: statusColor.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),

                  // Medications row
                  if (meds.isEmpty)
                    Row(
                      children: [
                        Icon(Icons.medication_outlined,
                            size: 13, color: cs.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Text(
                          'No medications defined',
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant),
                        ),
                      ],
                    )
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: meds.map((m) {
                        final name   = m['medication_name'] as String? ?? '?';
                        final target = m['target_count'] as int? ?? 1;
                        final loaded = m['loaded_count'] as int? ?? 0;
                        final full   = loaded >= target;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: full
                                ? Colors.green.withOpacity(0.1)
                                : cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: full
                                  ? Colors.green.withOpacity(0.3)
                                  : cs.outlineVariant,
                            ),
                          ),
                          child: Text(
                            '$name ×$target',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: full
                                  ? Colors.green.shade700
                                  : cs.onSurface,
                            ),
                          ),
                        );
                      }).toList(),
                    ),

                  const SizedBox(height: 5),

                  // Time + updated_at row
                  Row(
                    children: [
                      if (plannedTime.isNotEmpty) ...[
                        Icon(Icons.schedule_rounded,
                            size: 12, color: cs.primary),
                        const SizedBox(width: 3),
                        Text(
                          plannedTime,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      const Spacer(),
                      if (updatedAt.isNotEmpty)
                        Text(
                          _formatTime(updatedAt),
                          style: TextStyle(
                              fontSize: 10,
                              color: cs.onSurfaceVariant.withOpacity(0.6)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded,
                color: cs.onSurface.withOpacity(0.25), size: 20),
          ],
        ),
      ),
    );
  }

  // ── Slot detail bottom sheet ───────────────────────────────────────────────

  void _showSlotDetail(Map<String, dynamic> slot) {
    final snap        = _dispenser.snapshot;
    final patientId   = slot['patient_id'] as String? ?? '';
    final patientName = _patientNames[patientId] ?? _truncateId(patientId);
    final slotId      = slot['slot_id'] as int;
    final slotStatus  = slot['slot_status'] as String? ?? 'empty';
    final updatedAt   = slot['updated_at'] as String? ?? '';
    final plannedTime = slot['planned_time'] as String? ?? '';
    final scheduleId  = slot['schedule_id'] as String? ?? '';
    final meds        = (slot['medications'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>() ??
        <Map<String, dynamic>>[];

    final isActiveSlot = snap.selectedSlot == slotId;
    final cameraStatus = isActiveSlot
        ? (snap.cameraActive ? 'Active' : 'Off')
        : '—';

    final cs           = Theme.of(context).colorScheme;
    final statusColor  = _slotStatusColor(slotStatus);
    final statusLabel  = _slotStatusLabel(slotStatus);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),

            // Header
            Row(
              children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor.withOpacity(0.12),
                    border: Border.all(color: statusColor.withOpacity(0.4)),
                  ),
                  child: Center(
                    child: Text(
                      '$slotId',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: statusColor.withOpacity(0.85),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Slot $slotId',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 12),

            // Detail rows
            _detailRow(cs, Icons.person_rounded, 'Patient', patientName),
            if (plannedTime.isNotEmpty)
              _detailRow(cs, Icons.schedule_rounded, 'Planned Time',
                  plannedTime, valueColor: cs.primary),
            _detailRow(cs, Icons.camera_alt_rounded, 'Camera', cameraStatus,
                valueColor: cameraStatus == 'Active' ? Colors.green : null),
            if (updatedAt.isNotEmpty)
              _detailRow(cs, Icons.update_rounded, 'Last Updated',
                  _formatTime(updatedAt)),
            if (scheduleId.isNotEmpty)
              _detailRow(cs, Icons.tag_rounded, 'Schedule ID',
                  _truncateId(scheduleId)),

            // Medications section
            if (meds.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.medication_rounded,
                      size: 15, color: cs.onSurface.withOpacity(0.45)),
                  const SizedBox(width: 8),
                  Text(
                    'Medications',
                    style: TextStyle(
                        fontSize: 13, color: cs.onSurface.withOpacity(0.6)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...meds.map((m) {
                final name   = m['medication_name'] as String? ?? '?';
                final target = m['target_count'] as int? ?? 1;
                final loaded = m['loaded_count'] as int? ?? 0;
                final full   = loaded >= target;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        full
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 16,
                        color: full ? Colors.green : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: full
                              ? Colors.green.withOpacity(0.1)
                              : cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: full
                                ? Colors.green.withOpacity(0.3)
                                : cs.outlineVariant,
                          ),
                        ),
                        child: Text(
                          '$loaded / $target',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: full ? Colors.green.shade700 : cs.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ] else ...[
              const SizedBox(height: 4),
              _detailRow(cs, Icons.medication_outlined, 'Medications',
                  'None defined'),
            ],

            const SizedBox(height: 20),

            // Remove button
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _deleteSlot(slotId);
                },
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Remove Slot Binding'),
                style: FilledButton.styleFrom(
                  backgroundColor: cs.error,
                  foregroundColor: cs.onError,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(ColorScheme cs, IconData icon, String label, String value,
      {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurface.withOpacity(0.45)),
          const SizedBox(width: 12),
          Text(label,
              style: TextStyle(
                  fontSize: 14, color: cs.onSurface.withOpacity(0.6))),
          const Spacer(),
          Text(value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: valueColor ?? cs.onSurface,
              )),
        ],
      ),
    );
  }

  // ── Auth log tile ──────────────────────────────────────────────────────────

  Widget _buildAuthLogTile(ColorScheme cs, Map<String, dynamic> log) {
    final status    = log['status'] as String? ?? 'unknown';
    final score     = log['score'] as num?;
    final isSuccess = status == 'success' || status == 'dispensed';
    final isMissed  = status == 'timeout_missed';
    final patientId = log['patient_id'] as String? ?? '';
    final name      = _patientNames[patientId] ?? _truncateId(patientId);

    Color accentColor;
    IconData iconData;
    String statusLabel;

    if (isSuccess) {
      accentColor = Colors.green;
      iconData    = Icons.check_circle_rounded;
      statusLabel = 'Dispensed';
    } else if (isMissed) {
      accentColor = Colors.orange;
      iconData    = Icons.alarm_off_rounded;
      statusLabel = 'Missed';
    } else {
      accentColor = cs.error;
      iconData    = Icons.cancel_rounded;
      statusLabel = _statusLabel(status);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: accentColor.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Icon(iconData, color: accentColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isNotEmpty ? name : 'Unknown',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                        ),
                      ),
                    ),
                    if (score != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        'score ${score.toStringAsFixed(2)}',
                        style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withOpacity(0.5)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Text(
            _formatTime(log['created_at'] as String? ?? ''),
            style: TextStyle(
                fontSize: 11, color: cs.onSurface.withOpacity(0.45)),
          ),
        ],
      ),
    );
  }

  // ── Empty state card ───────────────────────────────────────────────────────

  Widget _buildEmptyCard(ColorScheme cs, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.3),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 32, color: cs.onSurface.withOpacity(0.2)),
          const SizedBox(height: 8),
          Text(text,
              style: TextStyle(
                  color: cs.onSurface.withOpacity(0.45), fontSize: 13)),
        ],
      ),
    );
  }

  // ── Slot status helpers ────────────────────────────────────────────────────

  Color _slotStatusColor(String status) {
    switch (status) {
      case 'loaded':    return Colors.green;
      case 'dispensed': return Colors.blue;
      default:          return Colors.orange; // 'empty'
    }
  }

  String _slotStatusLabel(String status) {
    switch (status) {
      case 'loaded':    return 'Loaded';
      case 'dispensed': return 'Dispensed';
      default:          return 'Empty';
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _truncateId(String id) {
    if (id.isEmpty) return '—';
    return id.length <= 8 ? id : '${id.substring(0, 8)}…';
  }

  String _formatTime(String iso) {
    if (iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final h  = dt.hour.toString().padLeft(2, '0');
      final m  = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } catch (_) {
      return iso.length > 5 ? iso.substring(11, 16) : iso;
    }
  }

  String _statusLabel(String raw) {
    switch (raw) {
      case 'timeout_missed':  return 'Missed';
      case 'liveness_failed': return 'Liveness Fail';
      case 'low_score':       return 'Low Score';
      case 'wrong_patient':   return 'Wrong Patient';
      case 'dispense_failed': return 'Dispense Fail';
      default:                return raw.replaceAll('_', ' ');
    }
  }

  String _stateDisplayName(DispenserState state) {
    switch (state) {
      case DispenserState.idle:              return 'IDLE';
      case DispenserState.rotating:          return 'ROTATING';
      case DispenserState.loadingMode:       return 'LOADING';
      case DispenserState.slotReady:         return 'READY';
      case DispenserState.waitingForPatient: return 'WAITING';
      case DispenserState.faceMatched:       return 'MATCHED';
      case DispenserState.dispensing:        return 'DISPENSING';
      case DispenserState.error:             return 'ERROR';
    }
  }

  Color _stateColor(DispenserState state) {
    switch (state) {
      case DispenserState.idle:              return Colors.grey;
      case DispenserState.rotating:
      case DispenserState.loadingMode:       return Colors.orange;
      case DispenserState.slotReady:         return Colors.blue;
      case DispenserState.waitingForPatient: return Colors.amber.shade700;
      case DispenserState.faceMatched:       return Colors.green;
      case DispenserState.dispensing:        return Colors.teal;
      case DispenserState.error:             return Colors.red;
    }
  }
}
