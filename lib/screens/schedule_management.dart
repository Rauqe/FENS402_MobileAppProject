import 'package:flutter/material.dart';
import '../models/medication.dart';
import '../models/medication_schedule.dart';
import '../models/patient.dart';
import '../models/slot_medication.dart';
import '../services/api_service.dart';
import '../services/dispenser_service.dart';
import '../widgets/barcode_scanner_sheet.dart';

// ── Weekday constants (0 = Monday … 6 = Sunday) ─────────────────────────────
const _kDayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class ScheduleManagementScreen extends StatefulWidget {
  const ScheduleManagementScreen({super.key});

  @override
  State<ScheduleManagementScreen> createState() =>
      _ScheduleManagementScreenState();
}

class _ScheduleManagementScreenState
    extends State<ScheduleManagementScreen> {
  final _api = ApiService.instance;
  final _dispenser = DispenserService();

  List<Patient> _patients = [];
  Patient? _selectedPatient;

  List<MedicationSchedule> _schedules = [];
  List<Medication> _medications = [];

  // slot occupancy map: slotId → {available, status, patient_id?}
  Map<int, Map<String, dynamic>> _slotOccupancy = {};

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPatients();
  }

  // ── Data loading ───────────────────────────────────────────────────────────

  Future<void> _loadPatients() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _patients = await _api.getAllPatients();
      if (_patients.isNotEmpty) {
        _selectedPatient = _patients.first;
        await _loadAll();
      }
    } on ApiException catch (e) {
      _error = 'API error ${e.statusCode}: ${e.message}';
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadAll() async {
    if (_selectedPatient == null) return;
    await Future.wait([
      _loadSchedules(),
      _loadMedications(),
      _loadSlotOccupancy(),
    ]);
  }

  Future<void> _loadSchedules() async {
    if (_selectedPatient == null) return;
    try {
      _schedules =
          await _api.getPatientSchedules(_selectedPatient!.patientId);
      _error = null;
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        _schedules = [];
      } else {
        _error = 'API error: ${e.message}';
      }
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadMedications() async {
    if (_selectedPatient == null) return;
    try {
      _medications =
          await _api.getPatientMedications(_selectedPatient!.patientId);
    } catch (_) {
      _medications = [];
    }
  }

  Future<void> _loadSlotOccupancy() async {
    try {
      final data = await _api.getAvailableSlots();
      final occupancy = <int, Map<String, dynamic>>{};
      for (final s in (data['available'] as List? ?? [])) {
        occupancy[(s['slot_id'] as int)] = Map<String, dynamic>.from(s);
      }
      for (final s in (data['occupied'] as List? ?? [])) {
        occupancy[(s['slot_id'] as int)] = Map<String, dynamic>.from(s);
      }
      _slotOccupancy = occupancy;
    } catch (_) {
      // Non-critical — slot picker will just not show status
    }
    if (mounted) setState(() {});
  }

  // ── Add / Edit dialog ──────────────────────────────────────────────────────

  Future<void> _showScheduleDialog({
    String? editScheduleId,
    MedicationSchedule? existing,
  }) async {
    await _loadMedications();
    if (!mounted) return;

    final isEdit = editScheduleId != null;

    // ── Dialog state ───────────────────────────────────────────────────────
    int? selectedSlotId = isEdit ? existing!.slotId : null;
    TimeOfDay selectedTime = isEdit
        ? existing!.plannedTime
        : const TimeOfDay(hour: 8, minute: 0);

    // Medications for this slot (mutable during dialog)
    final List<SlotMedication> slotMeds = isEdit
        ? List<SlotMedication>.from(existing!.medications)
        : [];

    String frequencyType =
        isEdit ? (existing?.frequencyType ?? 'daily') : 'daily';
    final Set<int> selectedWeekDays = isEdit
        ? Set<int>.from(existing?.weekDayList ?? [])
        : {0, 1, 2, 3, 4};

    DateTime startDate = isEdit && existing?.startDate != null
        ? existing!.startDate!
        : DateTime.now();
    DateTime? endDate = isEdit ? existing?.endDate : null;
    String durationKey = _deriveDurationKey(
        isEdit ? existing?.startDate : null,
        isEdit ? existing?.endDate : null);

    int windowSeconds =
        isEdit ? (existing?.windowSeconds ?? 300) : 300;

    // Build occupied slot set for picker
    final Set<int> occupiedSlots = _slotOccupancy.entries
        .where((e) => e.value['available'] != true)
        .map((e) => e.key)
        .toSet();
    // When editing, current slot is "available" for this form
    if (isEdit && existing != null) {
      occupiedSlots.remove(existing.slotId);
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          return AlertDialog(
            title: Text(isEdit ? 'Edit Schedule' : 'New Schedule'),
            contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Slot picker ───────────────────────────────────
                    _sectionLabel(ctx, 'Slot'),
                    const SizedBox(height: 8),
                    _buildSlotPicker(
                      ctx, setDlg,
                      selected: selectedSlotId,
                      occupied: occupiedSlots,
                      onSelected: (id) => setDlg(() => selectedSlotId = id),
                    ),
                    const SizedBox(height: 16),

                    // ── Planned time ──────────────────────────────────
                    _sectionLabel(ctx, 'Scheduled Time'),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.access_time_rounded,
                            size: 20),
                        label: Text(
                          _fmtTime(selectedTime),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: ctx,
                            initialTime: selectedTime,
                          );
                          if (picked != null) {
                            setDlg(() => selectedTime = picked);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Medications ───────────────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child:
                              _sectionLabel(ctx, 'Medications for this slot'),
                        ),
                        TextButton.icon(
                          onPressed: _medications.isEmpty
                              ? null
                              : () => _showAddMedicationDialog(
                                    ctx, setDlg, slotMeds),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add'),
                          style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact),
                        ),
                      ],
                    ),
                    if (slotMeds.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No medications added yet. Tap Add to include medications.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(ctx)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      ...slotMeds.asMap().entries.map((e) {
                        final i = e.key;
                        final m = e.value;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 6),
                          elevation: 0,
                          color: Theme.of(ctx)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 16,
                              child: Text('${i + 1}',
                                  style: const TextStyle(fontSize: 12)),
                            ),
                            title: Text(m.medicationName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text('${m.targetCount} pill(s)'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Decrease count
                                IconButton(
                                  icon: const Icon(
                                      Icons.remove_circle_outline,
                                      size: 18),
                                  onPressed: m.targetCount > 1
                                      ? () => setDlg(() {
                                            slotMeds[i] = m.copyWith(
                                                targetCount:
                                                    m.targetCount - 1);
                                          })
                                      : null,
                                  visualDensity: VisualDensity.compact,
                                ),
                                Text('${m.targetCount}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold)),
                                // Increase count
                                IconButton(
                                  icon: const Icon(
                                      Icons.add_circle_outline,
                                      size: 18),
                                  onPressed: () => setDlg(() {
                                    slotMeds[i] = m.copyWith(
                                        targetCount: m.targetCount + 1);
                                  }),
                                  visualDensity: VisualDensity.compact,
                                ),
                                // Remove medication
                                IconButton(
                                  icon: const Icon(Icons.close,
                                      size: 18, color: Colors.redAccent),
                                  onPressed: () => setDlg(
                                      () => slotMeds.removeAt(i)),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    const Divider(height: 24),

                    // ── Frequency type ────────────────────────────────
                    _sectionLabel(ctx, 'Frequency'),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: 'daily',
                          label: Text('Daily'),
                          icon: Icon(Icons.today_rounded, size: 16),
                        ),
                        ButtonSegment(
                          value: 'weekly',
                          label: Text('Weekly'),
                          icon: Icon(Icons.date_range_rounded, size: 16),
                        ),
                        ButtonSegment(
                          value: 'alternate',
                          label: Text('Every 2d'),
                          icon:
                              Icon(Icons.repeat_one_rounded, size: 16),
                        ),
                      ],
                      selected: {frequencyType},
                      onSelectionChanged: (s) =>
                          setDlg(() => frequencyType = s.first),
                    ),

                    // ── Weekday picker ────────────────────────────────
                    if (frequencyType == 'weekly') ...[
                      const SizedBox(height: 12),
                      _sectionLabel(ctx, 'Days of the week'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        children: List.generate(7, (i) {
                          final selected = selectedWeekDays.contains(i);
                          return FilterChip(
                            label: Text(_kDayLabels[i]),
                            selected: selected,
                            onSelected: (v) => setDlg(() {
                              if (v) {
                                selectedWeekDays.add(i);
                              } else {
                                selectedWeekDays.remove(i);
                              }
                            }),
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          );
                        }),
                      ),
                    ],
                    const Divider(height: 24),

                    // ── Auth window ───────────────────────────────────
                    Row(
                      children: [
                        const Icon(Icons.timer_outlined, size: 20),
                        const SizedBox(width: 8),
                        const Text('Auth Window'),
                        const Spacer(),
                        Text(
                          _fmtWindow(windowSeconds),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15),
                        ),
                      ],
                    ),
                    Slider(
                      value: windowSeconds.toDouble(),
                      min: 30,
                      max: 3600,
                      divisions: (3600 - 30) ~/ 5,
                      onChanged: (v) => setDlg(
                        () => windowSeconds =
                            ((v / 5).round() * 5).clamp(30, 3600),
                      ),
                    ),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('30 sec',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500)),
                          Text('1 hour',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500)),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _winBtn('-1m', -60, windowSeconds, setDlg,
                            (v) => windowSeconds = v),
                        _winBtn('-5s', -5, windowSeconds, setDlg,
                            (v) => windowSeconds = v),
                        const SizedBox(width: 8),
                        _winBtn('+5s', 5, windowSeconds, setDlg,
                            (v) => windowSeconds = v),
                        _winBtn('+1m', 60, windowSeconds, setDlg,
                            (v) => windowSeconds = v),
                      ],
                    ),
                    const Divider(height: 24),

                    // ── Start date ────────────────────────────────────
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.calendar_today_rounded),
                      title: const Text('Start Date'),
                      subtitle: Text(_fmtDate(startDate)),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: startDate,
                          firstDate: DateTime.now()
                              .subtract(const Duration(days: 1)),
                          lastDate: DateTime.now()
                              .add(const Duration(days: 3650)),
                        );
                        if (picked != null) {
                          setDlg(() {
                            startDate = picked;
                            endDate =
                                _computeEndDate(startDate, durationKey);
                          });
                        }
                      },
                    ),

                    // ── Duration presets ──────────────────────────────
                    _sectionLabel(ctx, 'Duration'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: _kDurationOptions.keys
                          .map((key) => ChoiceChip(
                                label: Text(key),
                                selected: durationKey == key,
                                onSelected: (_) async {
                                  if (key == 'Custom') {
                                    final picked = await showDatePicker(
                                      context: ctx,
                                      initialDate: endDate ??
                                          startDate.add(
                                              const Duration(days: 30)),
                                      firstDate: startDate,
                                      lastDate: DateTime.now().add(
                                          const Duration(days: 3650)),
                                    );
                                    if (picked != null) {
                                      setDlg(() {
                                        durationKey = 'Custom';
                                        endDate = picked;
                                      });
                                    }
                                  } else {
                                    setDlg(() {
                                      durationKey = key;
                                      endDate =
                                          _computeEndDate(startDate, key);
                                    });
                                  }
                                },
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(ctx)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.event_rounded,
                              size: 16,
                              color: Theme.of(ctx)
                                  .colorScheme
                                  .onSurfaceVariant),
                          const SizedBox(width: 8),
                          Text(
                            endDate != null
                                ? 'Ends: ${_fmtDate(endDate!)}'
                                : 'No end date (ongoing)',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(ctx)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: selectedSlotId == null
                    ? null
                    : () async {
                        if (frequencyType == 'weekly' &&
                            selectedWeekDays.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Select at least one day of the week.')),
                          );
                          return;
                        }
                        Navigator.pop(ctx);

                        final sortedDays = selectedWeekDays.toList()
                          ..sort();
                        // Daily / alternate: backend must not get Mon–Fri default
                        // (0–4) as week_days — some APIs treat that as "weekdays only".
                        final weekDaysForApi = frequencyType == 'weekly'
                            ? sortedDays.join(',')
                            : '';
                        final startStr = startDate
                            .toIso8601String()
                            .split('T')
                            .first;
                        final endStr = endDate
                            ?.toIso8601String()
                            .split('T')
                            .first;

                        if (isEdit) {
                          await _updateSchedule(
                            scheduleId: editScheduleId!,
                            plannedTime: _fmtTime(selectedTime),
                            frequencyType: frequencyType,
                            weekDays: weekDaysForApi,
                            startDate: startStr,
                            endDate: endStr,
                            windowSeconds: windowSeconds,
                            medications: slotMeds,
                          );
                        } else {
                          await _createSchedule(
                            slotId: selectedSlotId!,
                            plannedTime: _fmtTime(selectedTime),
                            frequencyType: frequencyType,
                            weekDays: weekDaysForApi,
                            startDate: startStr,
                            endDate: endStr,
                            windowSeconds: windowSeconds,
                            medications: slotMeds,
                          );
                        }
                      },
                child: Text(isEdit ? 'Update' : 'Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Add medication to slot dialog ──────────────────────────────────────────

  void _showAddMedicationDialog(
    BuildContext parentCtx,
    StateSetter setDlg,
    List<SlotMedication> slotMeds,
  ) {
    Medication? pickedMed =
        _medications.isNotEmpty ? _medications.first : null;
    int targetCount = 1;

    // Filter out medications already added
    final alreadyAdded = slotMeds.map((m) => m.medicationId).toSet();
    final available =
        _medications.where((m) => !alreadyAdded.contains(m.medicationId)).toList();
    if (available.isNotEmpty) pickedMed = available.first;

    if (available.isEmpty) {
      ScaffoldMessenger.of(parentCtx).showSnackBar(
        const SnackBar(
            content: Text('All medications are already in this slot.')),
      );
      return;
    }

    showDialog(
      context: parentCtx,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Add Medication'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<Medication>(
                value: pickedMed,
                decoration: const InputDecoration(
                  labelText: 'Medication',
                  prefixIcon: Icon(Icons.medication_rounded),
                ),
                items: available
                    .map((m) => DropdownMenuItem(
                          value: m,
                          child: Text(m.medicationName),
                        ))
                    .toList(),
                onChanged: (m) => setInner(() => pickedMed = m),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Pills per dose:'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: targetCount > 1
                        ? () => setInner(() => targetCount--)
                        : null,
                  ),
                  Text('$targetCount',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => setInner(() => targetCount++),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: pickedMed == null
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      setDlg(() {
                        slotMeds.add(SlotMedication(
                          medicationId: pickedMed!.medicationId,
                          medicationName: pickedMed!.medicationName,
                          barcode: pickedMed!.pillBarcode,
                          targetCount: targetCount,
                        ));
                      });
                    },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Slot picker widget ─────────────────────────────────────────────────────

  Widget _buildSlotPicker(
    BuildContext ctx,
    StateSetter setDlg, {
    required int? selected,
    required Set<int> occupied,
    required ValueChanged<int> onSelected,
  }) {
    return GridView.count(
      crossAxisCount: 7,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: List.generate(14, (i) {
        final isOccupied = occupied.contains(i);
        final isSelected = selected == i;
        final cs = Theme.of(ctx).colorScheme;

        Color bgColor;
        Color fgColor;
        if (isSelected) {
          bgColor = cs.primary;
          fgColor = cs.onPrimary;
        } else if (isOccupied) {
          bgColor = cs.errorContainer.withOpacity(0.4);
          fgColor = cs.onErrorContainer.withOpacity(0.5);
        } else {
          bgColor = cs.surfaceContainerHighest;
          fgColor = cs.onSurfaceVariant;
        }

        return GestureDetector(
          onTap: isOccupied ? null : () => onSelected(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: isSelected
                  ? Border.all(color: cs.primary, width: 2)
                  : null,
            ),
            alignment: Alignment.center,
            child: Text(
              '$i',
              style: TextStyle(
                fontSize: 14,
                fontWeight:
                    isSelected ? FontWeight.bold : FontWeight.normal,
                color: fgColor,
              ),
            ),
          ),
        );
      }),
    );
  }

  // ── API actions ────────────────────────────────────────────────────────────

  Future<void> _createSchedule({
    required int slotId,
    required String plannedTime,
    required String frequencyType,
    required String weekDays,
    required String startDate,
    String? endDate,
    int windowSeconds = 300,
    List<SlotMedication> medications = const [],
  }) async {
    try {
      await _api.createSchedule(
        slotId: slotId,
        patientId: _selectedPatient!.patientId,
        plannedTime: plannedTime,
        frequencyType: frequencyType,
        weekDays: weekDays,
        startDate: startDate,
        endDate: endDate,
        windowSeconds: windowSeconds,
        medications: medications,
      );
      await _loadAll();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Schedule saved for Slot $slotId')),
      );

      // Offer to load the slot immediately
      final newSched = _schedules
          .where((s) => s.slotId == slotId && s.slotStatus == 'empty')
          .firstOrNull;
      if (newSched != null && mounted) {
        final load = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Load Slot Now?'),
            content: Text(
              'Schedule saved for Slot $slotId.\nDo you want to load the pills into the dispenser now?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Later'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.move_to_inbox_rounded),
                label: const Text('Load Now'),
              ),
            ],
          ),
        );
        if (load == true && mounted) {
          await _showLoadSlotFlow(newSched);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _updateSchedule({
    required String scheduleId,
    required String plannedTime,
    required String frequencyType,
    required String weekDays,
    required String startDate,
    String? endDate,
    int windowSeconds = 300,
    List<SlotMedication>? medications,
  }) async {
    try {
      await _api.updateSchedule(
        scheduleId: scheduleId,
        plannedTime: plannedTime,
        frequencyType: frequencyType,
        weekDays: weekDays,
        startDate: startDate,
        endDate: endDate,
        windowSeconds: windowSeconds,
        medications: medications,
      );
      await _loadAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Schedule updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _toggleSchedule(String scheduleId) async {
    try {
      await _api.toggleSchedule(scheduleId);
      await _loadSchedules();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  // ── Load Slot Flow ─────────────────────────────────────────────────────────

  Future<void> _showLoadSlotFlow(MedicationSchedule sched) async {
    if (_selectedPatient == null) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('Rotating to Slot ${sched.slotId}…')),
    );
    try {
      await _dispenser.bindSlot(
        patientId: _selectedPatient!.patientId,
        slotId: sched.slotId,
        patientName: _selectedPatient!.fullName,
      );
      messenger.clearSnackBars();
    } catch (e) {
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(content: Text('Slot bind failed: $e')));
      return;
    }
    if (!mounted) return;

    final List<SlotMedication> expectedMeds =
        List<SlotMedication>.from(sched.medications);
    final Map<String, int> loadedCounts = {
      for (final m in expectedMeds) m.medicationId: 0,
    };

    bool loading = false;
    String? scanError;
    String? lastScannedName;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${sched.slotId}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(ctx).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Load Slot ${sched.slotId}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${sched.formattedTime} · ${sched.frequencyLabel}',
                          style: TextStyle(
                            color: Theme.of(ctx)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Expected medications
              const Text(
                'Expected medications:',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ...expectedMeds.map((m) {
                final loaded = loadedCounts[m.medicationId] ?? 0;
                final isDone = loaded >= m.targetCount;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(
                        isDone
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: isDone
                            ? Colors.green
                            : Theme.of(ctx).colorScheme.outline,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.medicationName,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w500)),
                            if (m.barcode != null)
                              Text(
                                'Barcode: ${m.barcode}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isDone
                              ? Colors.green.withOpacity(0.12)
                              : Theme.of(ctx)
                                  .colorScheme
                                  .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$loaded / ${m.targetCount}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isDone
                                ? Colors.green
                                : Theme.of(ctx)
                                    .colorScheme
                                    .onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),

              if (expectedMeds.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No medications defined. Barcodes will be accepted freely.',
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),

              // Scan feedback
              if (lastScannedName != null || scanError != null) ...[
                const SizedBox(height: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: scanError != null
                        ? Colors.red.shade50
                        : Colors.green.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: scanError != null
                          ? Colors.red.shade300
                          : Colors.green.shade300,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        scanError != null
                            ? Icons.error_outline_rounded
                            : Icons.check_rounded,
                        size: 18,
                        color: scanError != null ? Colors.red : Colors.green,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          scanError ?? lastScannedName!,
                          style: TextStyle(
                            fontSize: 13,
                            color: scanError != null
                                ? Colors.red.shade700
                                : Colors.green.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),

              // Barcode scanner widget
              BarcodeScannerSheet(
                scannedCount:
                    loadedCounts.values.fold(0, (sum, v) => sum + v),
                loading: loading,
                onScanned: (barcode) async {
                  setSheet(() {
                    loading = true;
                    scanError = null;
                    lastScannedName = null;
                  });
                  try {
                    final result = await _dispenser.scanBarcode(barcode);
                    setSheet(() {
                      loading = false;
                      if (result.ok) {
                        final medId =
                            result.raw['medication_id'] as String?;
                        final newLoaded =
                            result.raw['loaded_count'] as int? ?? 1;
                        final medName =
                            result.raw['medication_name'] as String?;
                        if (medId != null) {
                          loadedCounts[medId] = newLoaded;
                        }
                        lastScannedName =
                            '${medName ?? barcode}: $newLoaded loaded';
                        scanError = null;
                      } else {
                        scanError = result.message.isNotEmpty
                            ? result.message
                            : 'Barcode not expected for this slot';
                      }
                    });
                  } catch (e) {
                    setSheet(() {
                      loading = false;
                      scanError = 'Error: $e';
                    });
                  }
                },
              ),
              const SizedBox(height: 16),

              // Commit button
              FilledButton.icon(
                onPressed: loading
                    ? null
                    : () async {
                        setSheet(() => loading = true);
                        try {
                          final result = await _dispenser.commitSlot();
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(result.message)),
                            );
                            await _loadAll();
                            if (mounted) setState(() {});
                          }
                        } catch (e) {
                          setSheet(() => loading = false);
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('Error: $e')),
                            );
                          }
                        }
                      },
                icon: const Icon(Icons.check_circle_rounded),
                label: const Text('Commit — Mark as Loaded'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: loading ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeleteSchedule(MedicationSchedule s) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Schedule'),
        content: Text(
          'Remove schedule for Slot ${s.slotId} (${s.formattedTime})?',
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
                await _api.deleteSchedule(s.scheduleId);
                await _loadAll();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Schedule deleted')),
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
            style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Schedule Management'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () async {
              setState(() => _loading = true);
              await _loadAll();
              if (mounted) setState(() => _loading = false);
            },
            tooltip: 'Refresh',
          ),
        ],
      ),
      floatingActionButton: _selectedPatient != null
          ? FloatingActionButton.extended(
              onPressed: () => _showScheduleDialog(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New Schedule'),
            )
          : null,
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _patients.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadPatients,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Patient selector
        if (_patients.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: DropdownButtonFormField<Patient>(
              value: _selectedPatient,
              decoration: const InputDecoration(
                labelText: 'Select Patient',
                prefixIcon: Icon(Icons.person_rounded),
              ),
              items: _patients
                  .map((p) => DropdownMenuItem(
                        value: p,
                        child: Text(p.fullName),
                      ))
                  .toList(),
              onChanged: (p) async {
                setState(() {
                  _selectedPatient = p;
                  _schedules = [];
                  _medications = [];
                });
                await _loadAll();
                if (mounted) setState(() {});
              },
            ),
          ),
        Expanded(
          child: _schedules.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.calendar_month_rounded,
                          size: 48,
                          color: colorScheme.onSurface.withOpacity(0.3)),
                      const SizedBox(height: 12),
                      const Text('No schedules yet.'),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap + to add a schedule.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async {
                    await _loadAll();
                    setState(() {});
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                    itemCount: _schedules.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 12),
                    itemBuilder: (_, i) =>
                        _buildScheduleCard(_schedules[i], colorScheme),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildScheduleCard(
      MedicationSchedule s, ColorScheme colorScheme) {
    final isActive = s.isActive;

    // Slot status badge color
    Color slotStatusColor;
    IconData slotStatusIcon;
    switch (s.slotStatus) {
      case 'loaded':
        slotStatusColor = Colors.green;
        slotStatusIcon = Icons.check_circle_rounded;
        break;
      case 'dispensed':
        slotStatusColor = Colors.orange;
        slotStatusIcon = Icons.done_all_rounded;
        break;
      default: // empty
        slotStatusColor = colorScheme.outline;
        slotStatusIcon = Icons.radio_button_unchecked;
    }

    // Frequency badge color
    Color freqColor;
    switch (s.frequencyType) {
      case 'weekly':
        freqColor = colorScheme.tertiary;
        break;
      case 'alternate':
        freqColor = colorScheme.secondary;
        break;
      default:
        freqColor = colorScheme.primary;
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isActive
              ? colorScheme.outlineVariant
              : colorScheme.outlineVariant.withOpacity(0.5),
        ),
      ),
      color: isActive ? null : colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row ────────────────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Slot number
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: isActive
                        ? colorScheme.primaryContainer
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'S',
                        style: TextStyle(
                          fontSize: 11,
                          color: isActive
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${s.slotId}',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: isActive
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurfaceVariant
                                  .withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Time
                      Text(
                        s.formattedTime,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: isActive
                              ? colorScheme.onSurface
                              : colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                      const SizedBox(height: 4),
                      // Badges row
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          // Frequency badge
                          _badge(
                            s.frequencyLabel,
                            freqColor,
                            icon: s.frequencyType == 'weekly'
                                ? Icons.date_range_rounded
                                : s.frequencyType == 'alternate'
                                    ? Icons.repeat_one_rounded
                                    : Icons.today_rounded,
                          ),
                          // Slot status badge
                          _badge(
                            s.slotStatus,
                            slotStatusColor,
                            icon: slotStatusIcon,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Active toggle
                Switch(
                  value: isActive,
                  onChanged: (_) => _toggleSchedule(s.scheduleId),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),

            // ── Weekly days chips ─────────────────────────────────────
            if (s.frequencyType == 'weekly' &&
                s.weekDayList.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 4,
                children: s.weekDayList
                    .map((d) => Chip(
                          label: Text(_kDayLabels[d]),
                          labelStyle: const TextStyle(fontSize: 11),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
            ],

            // ── Medications list ──────────────────────────────────────
            if (s.medications.isNotEmpty) ...[
              const SizedBox(height: 10),
              ...s.medications.map((m) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(Icons.medication_rounded,
                            size: 14,
                            color: isActive
                                ? colorScheme.primary
                                : colorScheme.outline),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            m.medicationName,
                            style: TextStyle(
                              fontSize: 13,
                              color: isActive
                                  ? colorScheme.onSurface
                                  : colorScheme.onSurface.withOpacity(0.5),
                            ),
                          ),
                        ),
                        Text(
                          '×${m.targetCount}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isActive
                                ? colorScheme.onSurfaceVariant
                                : colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  )),
            ] else ...[
              const SizedBox(height: 6),
              Text(
                'No medications defined',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant.withOpacity(0.6),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],

            const SizedBox(height: 10),

            // ── Footer row: date range + auth window + actions ────────
            Row(
              children: [
                Icon(Icons.date_range_rounded,
                    size: 14, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _formatDateRange(s.startDate, s.endDate),
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.timer_outlined,
                    size: 13, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 2),
                Text(
                  _fmtWindow(s.windowSeconds),
                  style: TextStyle(
                      fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
                if (s.slotStatus == 'empty')
                  IconButton(
                    onPressed: () => _showLoadSlotFlow(s),
                    icon: Icon(Icons.move_to_inbox_rounded,
                        size: 18, color: colorScheme.tertiary),
                    tooltip: 'Load Slot',
                    visualDensity: VisualDensity.compact,
                  ),
                IconButton(
                  onPressed: () => _showScheduleDialog(
                    editScheduleId: s.scheduleId,
                    existing: s,
                  ),
                  icon: Icon(Icons.edit_outlined,
                      size: 18, color: colorScheme.primary),
                  tooltip: 'Edit',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: () => _confirmDeleteSchedule(s),
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 18, color: Colors.redAccent),
                  tooltip: 'Delete',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Widget _sectionLabel(BuildContext ctx, String text) => Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
          letterSpacing: 0.5,
        ),
      );

  Widget _badge(String label, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  static Widget _winBtn(
    String label,
    int delta,
    int current,
    StateSetter setDlg,
    void Function(int) assign,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: () {
          final next = (current + delta).clamp(30, 3600);
          setDlg(() => assign(next));
        },
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  static String _fmtWindow(int seconds) {
    if (seconds < 60) return '$seconds sec';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    final minPart = '$m min';
    return s == 0 ? minPart : '$minPart $s sec';
  }

  static String _formatDateRange(DateTime? start, DateTime? end) {
    if (start == null) return 'Ongoing';
    final startStr =
        '${start.day.toString().padLeft(2, '0')}/${start.month.toString().padLeft(2, '0')}/${start.year}';
    if (end == null) return 'From $startStr · Ongoing';
    final diff = end.difference(start).inDays;
    String dur;
    if (diff == 7)
      dur = '7 Days';
    else if (diff == 14)
      dur = '14 Days';
    else if (diff == 30)
      dur = '1 Month';
    else if (diff == 90)
      dur = '3 Months';
    else {
      final endStr =
          '${end.day.toString().padLeft(2, '0')}/${end.month.toString().padLeft(2, '0')}/${end.year}';
      return '$startStr → $endStr';
    }
    return 'From $startStr · $dur';
  }

  String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _fmtDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  static const _kDurationOptions = <String, int?>{
    '7 Days': 7,
    '14 Days': 14,
    '1 Month': 30,
    '3 Months': 90,
    'Ongoing': null,
    'Custom': null,
  };

  static DateTime? _computeEndDate(DateTime start, String key) {
    final days = _kDurationOptions[key];
    if (key == 'Ongoing' || key == 'Custom' || days == null) return null;
    return start.add(Duration(days: days));
  }

  static String _deriveDurationKey(DateTime? start, DateTime? end) {
    if (end == null) return 'Ongoing';
    if (start == null) return 'Custom';
    final diff = end.difference(start).inDays;
    if (diff == 7) return '7 Days';
    if (diff == 14) return '14 Days';
    if (diff == 30) return '1 Month';
    if (diff == 90) return '3 Months';
    return 'Custom';
  }
}
