import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/medication.dart';
import '../models/patient.dart';
import '../services/api_service.dart';

class DrugManagementScreen extends StatefulWidget {
  const DrugManagementScreen({super.key});

  @override
  State<DrugManagementScreen> createState() => _DrugManagementScreenState();
}

class _DrugManagementScreenState extends State<DrugManagementScreen> {
  final _api = ApiService.instance;

  List<Patient> _patients = [];
  Patient? _selectedPatient;
  List<Medication> _medications = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPatients();
  }

  @override
  void dispose() {
    super.dispose();
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
    await _loadMedications();
  }

  Future<void> _loadMedications() async {
    if (_selectedPatient == null) return;
    try {
      _medications =
          await _api.getPatientMedications(_selectedPatient!.patientId);
      _error = null;
      debugPrint('[DrugMgmt] Loaded ${_medications.length} medications '
          'for patient ${_selectedPatient!.patientId}');
    } on ApiException catch (e) {
      debugPrint('[DrugMgmt] API error ${e.statusCode}: ${e.message}');
      if (e.statusCode == 404) {
        _medications = [];
        _error = 'Medications endpoint not found (404). Pi restarted?';
      } else {
        _medications = [];
        _error = 'API error ${e.statusCode}: ${e.message}';
      }
    } catch (e) {
      debugPrint('[DrugMgmt] Load error: $e');
      _medications = [];
      _error = e.toString();
    }
    if (mounted) setState(() {});
  }

  // ── Add Medication Dialog ──────────────────────────────────────────────────

  void _showAddDialog() {
    final nameCtrl       = TextEditingController();
    final colorShapeCtrl = TextEditingController();
    final barcodeCtrl    = TextEditingController();
    DateTime expiryDate  = DateTime.now().add(const Duration(days: 365));
    String? barcodeError;
    bool autoFilled = false;
    bool lookingUp  = false;

    Future<void> onBarcodeResolved(
        String barcode, StateSetter setDialogState) async {
      if (barcode.trim().isEmpty) return;
      setDialogState(() {
        lookingUp = true;
        barcodeError = null;
      });
      try {
        final existing = await _api.getMedicationByBarcode(barcode.trim());
        if (existing != null) {
          setDialogState(() {
            nameCtrl.text       = existing.medicationName;
            colorShapeCtrl.text = existing.pillColorShape ?? '';
            if (existing.expiryDate != null) expiryDate = existing.expiryDate!;
            autoFilled = true;
          });
        } else {
          setDialogState(() => autoFilled = false);
        }
      } catch (_) {
        setDialogState(() => autoFilled = false);
      } finally {
        setDialogState(() => lookingUp = false);
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Medication'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: barcodeCtrl,
                        decoration: InputDecoration(
                          labelText: 'Barcode *',
                          errorText: barcodeError,
                          suffixIcon: lookingUp
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                )
                              : null,
                        ),
                        onChanged: (v) {
                          if (barcodeError != null) {
                            setDialogState(() => barcodeError = null);
                          }
                        },
                        onSubmitted: (v) =>
                            onBarcodeResolved(v, setDialogState),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Scan barcode',
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      onPressed: () async {
                        final scanned = await _scanSingleBarcode(ctx);
                        if (scanned != null) {
                          setDialogState(() {
                            barcodeCtrl.text = scanned;
                            barcodeError = null;
                          });
                          await onBarcodeResolved(scanned, setDialogState);
                        }
                      },
                    ),
                  ],
                ),
                if (autoFilled) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade300),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline_rounded,
                            size: 16, color: Colors.green.shade700),
                        const SizedBox(width: 6),
                        Text(
                          'Found in system — fields auto-filled',
                          style: TextStyle(
                              fontSize: 12, color: Colors.green.shade700),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration:
                      const InputDecoration(labelText: 'Medication Name *'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: colorShapeCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Color / Shape',
                    hintText: 'e.g. White / Round',
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Expiry Date'),
                  subtitle: Text(
                    '${expiryDate.day}/${expiryDate.month}/${expiryDate.year}',
                  ),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: expiryDate,
                      firstDate: DateTime.now(),
                      lastDate:
                          DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) {
                      setDialogState(() => expiryDate = picked);
                    }
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
              onPressed: lookingUp
                  ? null
                  : () async {
                      if (nameCtrl.text.trim().isEmpty ||
                          _selectedPatient == null) return;
                      if (barcodeCtrl.text.trim().isEmpty) {
                        setDialogState(
                            () => barcodeError = 'Barcode is required');
                        return;
                      }
                      Navigator.pop(ctx);
                      try {
                        await _api.createMedication(
                          patientId: _selectedPatient!.patientId,
                          medicationName: nameCtrl.text.trim(),
                          pillColorShape: colorShapeCtrl.text.trim().isNotEmpty
                              ? colorShapeCtrl.text.trim()
                              : null,
                          pillBarcode: barcodeCtrl.text.trim(),
                          expiryDate: expiryDate
                              .toIso8601String()
                              .split('T')
                              .first,
                        );
                        await _loadMedications();
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Error: $e')),
                          );
                        }
                      }
                    },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Edit Medication Dialog ─────────────────────────────────────────────────

  void _showEditDialog(Medication med) {
    final nameCtrl       = TextEditingController(text: med.medicationName);
    final colorShapeCtrl = TextEditingController(text: med.pillColorShape ?? '');
    final barcodeCtrl    = TextEditingController(text: med.pillBarcode ?? '');
    DateTime expiryDate  = med.expiryDate ?? DateTime.now().add(const Duration(days: 365));

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit Medication'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: barcodeCtrl,
                  decoration: const InputDecoration(labelText: 'Barcode'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration:
                      const InputDecoration(labelText: 'Medication Name *'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: colorShapeCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Color / Shape',
                    hintText: 'e.g. White / Round',
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Expiry Date'),
                  subtitle: Text(
                    '${expiryDate.day}/${expiryDate.month}/${expiryDate.year}',
                  ),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: expiryDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) {
                      setDialogState(() => expiryDate = picked);
                    }
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
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx);
                try {
                  await _api.updateMedication(
                    med.medicationId,
                    medicationName: nameCtrl.text.trim(),
                    pillBarcode: barcodeCtrl.text.trim().isNotEmpty
                        ? barcodeCtrl.text.trim()
                        : null,
                    pillColorShape: colorShapeCtrl.text.trim().isNotEmpty
                        ? colorShapeCtrl.text.trim()
                        : null,
                    expiryDate: expiryDate.toIso8601String().split('T').first,
                  );
                  _loadMedications();
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: $e')),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Delete Medication ──────────────────────────────────────────────────────

  Future<void> _deleteMedication(Medication med) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Medication'),
        content: Text(
          'Delete "${med.medicationName}"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.deleteMedication(med.medicationId);
      _loadMedications();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  // ── Single barcode scanner helper ──────────────────────────────────────────

  Future<String?> _scanSingleBarcode(BuildContext parentCtx) {
    return showModalBottomSheet<String>(
      context: parentCtx,
      builder: (ctx) {
        final controller = MobileScannerController(
          detectionSpeed: DetectionSpeed.normal,
          facing: CameraFacing.back,
        );
        bool popped = false;
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Point camera at medication barcode',
                style:
                    TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 220,
                  child: MobileScanner(
                    controller: controller,
                    onDetect: (capture) {
                      final code =
                          capture.barcodes.firstOrNull?.rawValue;
                      if (code != null && !popped) {
                        popped = true;
                        controller.dispose();
                        Navigator.of(ctx).pop(code);
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  controller.dispose();
                  Navigator.of(ctx).pop(null);
                },
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Drug Management'),
        centerTitle: true,
      ),
      floatingActionButton: _selectedPatient != null
          ? FloatingActionButton(
              onPressed: _showAddDialog,
              child: const Icon(Icons.add_rounded),
              tooltip: 'Add Medication',
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _patients.isEmpty
              ? _buildError()
              : Column(
                  children: [
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
                              _medications = [];
                            });
                            await _loadAll();
                          },
                        ),
                      ),
                    Expanded(child: _buildMedicationsTab(colorScheme)),
                  ],
                ),
    );
  }

  // ── Medications tab ────────────────────────────────────────────────────────

  Widget _buildMedicationsTab(ColorScheme colorScheme) {
    if (_medications.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _error != null ? Icons.cloud_off_rounded : Icons.medication_outlined,
              size: 48,
              color: _error != null
                  ? colorScheme.error.withOpacity(0.6)
                  : colorScheme.onSurface.withOpacity(0.3),
            ),
            const SizedBox(height: 12),
            Text(
              _error ?? 'No medications for this patient.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _error != null ? colorScheme.error : null,
              ),
            ),
            const SizedBox(height: 8),
            if (_error != null)
              FilledButton.icon(
                onPressed: _loadMedications,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              )
            else
              const Text('Tap + to add a medication.',
                  style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadMedications,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        itemCount: _medications.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) =>
            _buildMedicationCard(_medications[i], colorScheme),
      ),
    );
  }

  Widget _buildMedicationCard(Medication med, ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.medication_rounded,
                  color: colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    med.medicationName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  if (med.pillColorShape != null &&
                      med.pillColorShape!.isNotEmpty)
                    Text(
                      med.pillColorShape!,
                      style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurface.withOpacity(0.6)),
                    ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (med.pillBarcode != null) ...[
                        Icon(Icons.qr_code,
                            size: 13, color: colorScheme.onSurfaceVariant),
                        const SizedBox(width: 3),
                        Text(
                          med.pillBarcode!,
                          style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(width: 12),
                      ],
                      if (med.expiryDate != null) ...[
                        Icon(Icons.event_outlined,
                            size: 13, color: colorScheme.onSurfaceVariant),
                        const SizedBox(width: 3),
                        Text(
                          'Exp: ${med.expiryDate!.month}/${med.expiryDate!.year}',
                          style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // Edit & Delete action buttons
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.edit_outlined,
                      size: 20, color: colorScheme.primary),
                  tooltip: 'Edit',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _showEditDialog(med),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 20, color: colorScheme.error),
                  tooltip: 'Delete',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _deleteMedication(med),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Error widget ───────────────────────────────────────────────────────────

  Widget _buildError() {
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
}
