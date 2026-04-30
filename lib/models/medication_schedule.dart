import 'package:flutter/material.dart';
import 'slot_medication.dart';

/// A schedule row from the Pi backend.
///
/// New architecture (slot-centric):
///   - One schedule = one slot + one planned_time + frequency settings
///   - Medications are stored per-slot in slot_medications (see [medications])
///   - slotId is always present
///   - No medication_id / dosage_quantity at the schedule level
class MedicationSchedule {
  final String scheduleId;
  final String patientId;
  final int slotId;
  final TimeOfDay plannedTime;
  final bool isActive;
  final DateTime? startDate;
  final DateTime? endDate;

  /// "daily" | "weekly" | "alternate"
  final String frequencyType;

  /// Comma-separated weekday integers "0,2,4" (Mon=0 … Sun=6).
  /// Only meaningful when frequencyType == "weekly".
  final String weekDays;

  /// Optional group ID for linking related schedules in the UI.
  final String? groupId;

  /// Face-auth window duration in seconds (caregiver-configurable, default 300).
  final int windowSeconds;

  /// Medications loaded/defined for this slot.
  final List<SlotMedication> medications;

  /// Current slot status: 'empty' | 'loaded' | 'dispensed'
  final String slotStatus;

  const MedicationSchedule({
    required this.scheduleId,
    required this.patientId,
    required this.slotId,
    required this.plannedTime,
    this.isActive = true,
    this.startDate,
    this.endDate,
    this.frequencyType = 'daily',
    this.weekDays = '',
    this.groupId,
    this.windowSeconds = 300,
    this.medications = const [],
    this.slotStatus = 'empty',
  });

  // ── Derived helpers ───────────────────────────────────────────────────────

  String get formattedTime {
    final h = plannedTime.hour.toString().padLeft(2, '0');
    final m = plannedTime.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Human-readable frequency label.
  String get frequencyLabel {
    switch (frequencyType) {
      case 'weekly':
        return 'Weekly';
      case 'alternate':
        return 'Every 2 Days';
      default:
        return 'Daily';
    }
  }

  /// Parsed weekday indices from weekDays string.
  List<int> get weekDayList {
    if (weekDays.isEmpty) return [];
    return weekDays
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toList();
  }

  /// Short display string for all medications (e.g. "Aspirin, Metformin").
  String get medicationsSummary {
    if (medications.isEmpty) return 'No medications';
    return medications.map((m) => m.medicationName).join(', ');
  }

  /// True if all medications in this slot are fully loaded.
  bool get isFullyLoaded =>
      medications.isNotEmpty && medications.every((m) => m.isFullyLoaded);

  // ── Serialisation ─────────────────────────────────────────────────────────

  factory MedicationSchedule.fromJson(Map<String, dynamic> json) {
    final timeStr = json['planned_time']?.toString() ?? '08:00';
    final parts = timeStr.split(':');
    final hour = int.tryParse(parts[0]) ?? 8;
    final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;

    final medsRaw = json['medications'];
    final meds = (medsRaw is List)
        ? medsRaw
            .map((m) => SlotMedication.fromJson(m as Map<String, dynamic>))
            .toList()
        : <SlotMedication>[];

    return MedicationSchedule(
      scheduleId: json['schedule_id']?.toString() ?? '',
      patientId: json['patient_id']?.toString() ?? '',
      slotId: (json['slot_id'] as int?) ?? 0,
      plannedTime: TimeOfDay(hour: hour, minute: minute),
      isActive: json['is_active'] == true || json['is_active'] == 1,
      startDate: json['start_date'] != null
          ? DateTime.tryParse(json['start_date'].toString())
          : null,
      endDate: json['end_date'] != null
          ? DateTime.tryParse(json['end_date'].toString())
          : null,
      frequencyType: json['frequency_type'] as String? ?? 'daily',
      weekDays: json['week_days'] as String? ?? '',
      groupId: json['group_id'] as String?,
      windowSeconds: (json['window_seconds'] as int?) ?? 300,
      medications: meds,
      slotStatus: json['slot_status'] as String? ?? 'empty',
    );
  }

  Map<String, dynamic> toJson() => {
        'schedule_id': scheduleId,
        'patient_id': patientId,
        'slot_id': slotId,
        'planned_time': formattedTime,
        'is_active': isActive,
        'start_date': startDate?.toIso8601String().split('T').first,
        'end_date': endDate?.toIso8601String().split('T').first,
        'frequency_type': frequencyType,
        'week_days': weekDays,
        'group_id': groupId,
        'window_seconds': windowSeconds,
        'medications': medications.map((m) => m.toJson()).toList(),
      };

  MedicationSchedule copyWith({
    String? scheduleId,
    String? patientId,
    int? slotId,
    TimeOfDay? plannedTime,
    bool? isActive,
    DateTime? startDate,
    DateTime? endDate,
    String? frequencyType,
    String? weekDays,
    String? groupId,
    int? windowSeconds,
    List<SlotMedication>? medications,
    String? slotStatus,
  }) {
    return MedicationSchedule(
      scheduleId: scheduleId ?? this.scheduleId,
      patientId: patientId ?? this.patientId,
      slotId: slotId ?? this.slotId,
      plannedTime: plannedTime ?? this.plannedTime,
      isActive: isActive ?? this.isActive,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      frequencyType: frequencyType ?? this.frequencyType,
      weekDays: weekDays ?? this.weekDays,
      groupId: groupId ?? this.groupId,
      windowSeconds: windowSeconds ?? this.windowSeconds,
      medications: medications ?? this.medications,
      slotStatus: slotStatus ?? this.slotStatus,
    );
  }
}
