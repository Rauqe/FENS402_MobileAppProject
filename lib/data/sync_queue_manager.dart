import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'local_database.dart';
import '../models/firebase_payloads.dart';
import '../services/firebase_service.dart';

/// Maximum number of upload retries before an event is considered stuck.
const int kMaxSyncRetries = 5;

/// Manages the offline-first event buffer defined in the ER Sync_Queue table.
///
/// Responsibilities:
///   1. Record events locally the moment they happen (online or offline).
///   2. Watch connectivity; when back online, flush the pending queue to Firebase.
///   3. Retry failed uploads up to [kMaxSyncRetries] times.
///
/// Usage:
/// ```dart
/// final manager = SyncQueueManager(firebaseService: myFirebaseService);
/// await manager.init();
///
/// // Record a pill-taken event (works offline too)
/// await manager.recordEvent(
///   scheduleId: 'sch-001',
///   status: 'pill_taken',
/// );
///
/// manager.dispose();
/// ```
class SyncQueueManager {
  final FirebaseService _firebaseService;
  final LocalDatabase _db = LocalDatabase.instance;
  final _uuid = const Uuid();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  SyncQueueManager({required FirebaseService firebaseService})
      : _firebaseService = firebaseService;

  // ── Init ─────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    await _db.init();

    // Listen for connectivity changes and trigger a flush whenever we go online.
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen((results) async {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (isOnline) {
        debugPrint('[SyncQueueManager] Back online — flushing pending events.');
        await flushQueue();
      }
    });

    // Also attempt a flush immediately at startup.
    final result = await Connectivity().checkConnectivity();
    if (result != ConnectivityResult.none) {
      await flushQueue();
    }
  }

  // ── Record ────────────────────────────────────────────────────────────────────

  /// Creates a [SyncQueuePayload], writes it to SQLite, then immediately
  /// tries to upload it to Firebase if online.
  ///
  /// [status] should be one of: 'pill_taken', 'missed_dose',
  ///                             'unlock_command', 'error'.
  Future<void> recordEvent({
    required String scheduleId,
    required String status,
    String? patientId,
  }) async {
    final payload = SyncQueuePayload(
      logId: _uuid.v4(),
      scheduleId: scheduleId,
      status: status,
      eventTimestamp: DateTime.now(),
    );

    await _db.enqueue(payload);
    debugPrint('[SyncQueueManager] Event enqueued: ${payload.logId} ($status)');

    // Try immediate upload; silently fail if offline.
    try {
      await _uploadSingle(payload, patientId: patientId);
    } catch (_) {
      // Will be retried by flushQueue when connectivity returns.
    }
  }

  // ── Flush ─────────────────────────────────────────────────────────────────────

  /// Uploads all pending events from SQLite to Firebase.
  /// Marks each one synced on success; increments retry count on failure.
  Future<void> flushQueue() async {
    final pending = await _db.getPendingEvents();
    if (pending.isEmpty) return;

    debugPrint('[SyncQueueManager] Flushing ${pending.length} pending events.');

    for (final payload in pending) {
      if (payload.retryCount >= kMaxSyncRetries) {
        debugPrint('[SyncQueueManager] Max retries reached for ${payload.logId}. '
            'Manual intervention required.');
        continue;
      }

      try {
        await _uploadSingle(payload);
        await _db.markSynced(payload.logId);
        debugPrint('[SyncQueueManager] Synced: ${payload.logId}');
      } catch (e) {
        await _db.incrementRetry(payload.logId);
        debugPrint('[SyncQueueManager] Retry #${payload.retryCount + 1} '
            'failed for ${payload.logId}: $e');
      }
    }

    // Housekeeping: remove already-synced rows.
    await _db.cleanSynced();
  }

  // ── Teardown ──────────────────────────────────────────────────────────────────

  void dispose() {
    _connectivitySub?.cancel();
  }

  // ── Private ───────────────────────────────────────────────────────────────────

  Future<void> _uploadSingle(
    SyncQueuePayload payload, {
    String? patientId,
  }) async {
    // Build a DispensingLogPayload from the queue entry, then push to Firebase.
    final log = DispensingLogPayload(
      logId: payload.logId,
      patientId: patientId ?? 'unknown',
      scheduleId: payload.scheduleId,
      status: _parseStatus(payload.status),
      deviceTimestamp: payload.eventTimestamp,
    );

    await _firebaseService.pushDispensingLog(log);
  }

  DispensingStatus _parseStatus(String raw) {
    return DispensingStatus.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => DispensingStatus.error,
    );
  }
}
