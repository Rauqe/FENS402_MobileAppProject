import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/firebase_payloads.dart';

/// Singleton SQLite wrapper — mirrors the LOCAL DATABASE tables from the
/// ER diagram: Local_Users, Local_Schedules, Sync_Queue.
///
/// Usage:
/// ```dart
/// final db = LocalDatabase.instance;
/// await db.init();
///
/// // Store a face embedding for offline auth
/// await db.upsertLocalUser(patientId, embedding);
///
/// // Read schedules for today
/// final schedules = await db.getTodaySchedules(patientId);
///
/// // Queue an event for later Firebase upload
/// await db.enqueue(payload);
/// ```
class LocalDatabase {
  LocalDatabase._();
  static final LocalDatabase instance = LocalDatabase._();

  Database? _db;

  // ── Init / open ──────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_db != null) return;

    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'smart_dispenser.db');

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Database get _database {
    assert(_db != null,
        'LocalDatabase not initialised. Call LocalDatabase.instance.init() first.');
    return _db!;
  }

  // ── Schema ───────────────────────────────────────────────────────────────────

  Future<void> _onCreate(Database db, int version) async {
    // ── Local_Users: stores face embeddings for offline Face-ID auth ───────────
    await db.execute('''
      CREATE TABLE local_users (
        patient_id   TEXT PRIMARY KEY,
        face_embedding TEXT NOT NULL
      )
    ''');

    // ── Local_Schedules: cached from Firebase for offline schedule display ─────
    await db.execute('''
      CREATE TABLE local_schedules (
        schedule_id      TEXT PRIMARY KEY,
        patient_id       TEXT NOT NULL,
        medication_id    TEXT NOT NULL,
        medication_name  TEXT NOT NULL,
        planned_time     TEXT NOT NULL,
        dosage_quantity  INTEGER NOT NULL DEFAULT 1,
        is_active        INTEGER NOT NULL DEFAULT 1,
        start_date       TEXT NOT NULL,
        end_date         TEXT
      )
    ''');

    // ── Sync_Queue: events recorded offline, waiting to be pushed to Firebase ──
    await db.execute('''
      CREATE TABLE sync_queue (
        log_id           TEXT PRIMARY KEY,
        schedule_id      TEXT NOT NULL,
        is_synced        INTEGER NOT NULL DEFAULT 0,
        status           TEXT NOT NULL,
        event_timestamp  TEXT NOT NULL,
        retry_count      INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Future migrations go here (ALTER TABLE, etc.)
  }

  // ── Local_Users operations ────────────────────────────────────────────────────

  /// Stores or replaces a face embedding (comma-separated floats) for a patient.
  Future<void> upsertLocalUser(
    String patientId,
    List<double> embedding,
  ) async {
    final embeddingStr = embedding.join(',');
    await _database.insert(
      'local_users',
      {'patient_id': patientId, 'face_embedding': embeddingStr},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns the stored face embedding for [patientId], or null if not found.
  Future<List<double>?> getFaceEmbedding(String patientId) async {
    final rows = await _database.query(
      'local_users',
      where: 'patient_id = ?',
      whereArgs: [patientId],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    final str = rows.first['face_embedding'] as String;
    return str.split(',').map(double.parse).toList();
  }

  // ── Local_Schedules operations ────────────────────────────────────────────────

  /// Bulk-replaces cached schedules for a patient (called after Firebase sync).
  Future<void> replaceSchedules(
    String patientId,
    List<MedicationSchedulePayload> schedules,
  ) async {
    final batch = _database.batch();
    batch.delete(
      'local_schedules',
      where: 'patient_id = ?',
      whereArgs: [patientId],
    );
    for (final s in schedules) {
      batch.insert('local_schedules', {
        'schedule_id': s.scheduleId,
        'patient_id': patientId,
        'medication_id': s.medicationId,
        'medication_name': '',   // populate from MedicationPayload if needed
        'planned_time': s.plannedTime,
        'dosage_quantity': s.dosageQuantity,
        'is_active': s.isActive ? 1 : 0,
        'start_date': s.startDate.toIso8601String(),
        'end_date': s.endDate?.toIso8601String(),
      });
    }
    await batch.commit(noResult: true);
  }

  /// Returns all active schedules for [patientId].
  Future<List<Map<String, dynamic>>> getActiveSchedules(
      String patientId) async {
    return _database.query(
      'local_schedules',
      where: 'patient_id = ? AND is_active = 1',
      whereArgs: [patientId],
      orderBy: 'planned_time ASC',
    );
  }

  // ── Sync_Queue operations ─────────────────────────────────────────────────────

  /// Enqueues a new event recorded while offline.
  Future<void> enqueue(SyncQueuePayload payload) async {
    await _database.insert(
      'sync_queue',
      payload.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Returns all events that have not been successfully synced yet.
  Future<List<SyncQueuePayload>> getPendingEvents() async {
    final rows = await _database.query(
      'sync_queue',
      where: 'is_synced = 0',
      orderBy: 'event_timestamp ASC',
    );
    return rows
        .map((r) => SyncQueuePayload.fromMap(Map<String, dynamic>.from(r)))
        .toList();
  }

  /// Marks a successfully uploaded event as synced.
  Future<void> markSynced(String logId) async {
    await _database.update(
      'sync_queue',
      {'is_synced': 1},
      where: 'log_id = ?',
      whereArgs: [logId],
    );
  }

  /// Increments the retry counter for a failed upload attempt.
  Future<void> incrementRetry(String logId) async {
    await _database.rawUpdate(
      'UPDATE sync_queue SET retry_count = retry_count + 1 WHERE log_id = ?',
      [logId],
    );
  }

  /// Removes events that have been synced (housekeeping — call periodically).
  Future<void> cleanSynced() async {
    await _database.delete('sync_queue', where: 'is_synced = 1');
  }

  // ── Teardown ─────────────────────────────────────────────────────────────────

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
