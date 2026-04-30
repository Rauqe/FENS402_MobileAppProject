"""Flask REST API for the Smart Drug Dispenser Pi backend."""

from __future__ import annotations

import os
import uuid
import sqlite3
import threading
import time
from datetime import datetime, timezone
from flask import Flask, request, jsonify
from state_machine import (
    DispenserStateMachine, DispenserState, LOCAL_DB,
    _db_define_slot_medications,
)

app = Flask(__name__)

# Singleton state machine — initialized in main()
sm: DispenserStateMachine | None = None


def _ok(data: dict, status: int = 200):
    return jsonify(data), status


def _err(msg: str, status: int = 400):
    return jsonify({"ok": False, "message": msg}), status


# ── State ───────────────────────────────────────────────────────────────

@app.route("/api/state", methods=["GET"])
def get_state():
    if not sm:
        return _err("State machine not initialized", 503)
    data = sm.get_state_dict()
    data["ok"] = True
    return _ok(data)


# ── Slot binding ────────────────────────────────────────────────────────

@app.route("/api/bind-slot", methods=["POST"])
def bind_slot():
    if not sm:
        return _err("State machine not initialized", 503)
    body = request.get_json(silent=True) or {}
    patient_id = body.get("patient_id")
    slot_id = body.get("slot_id")
    patient_name = body.get("patient_name", "")

    if not patient_id or slot_id is None:
        return _err("patient_id and slot_id are required")

    try:
        slot_id = int(slot_id)
    except (ValueError, TypeError):
        return _err("slot_id must be an integer")

    result = sm.bind_slot(patient_id, slot_id, patient_name)
    status = 200 if result["ok"] else 409
    return _ok(result, status)


# ── Barcode scan ────────────────────────────────────────────────────────

@app.route("/api/barcode", methods=["POST"])
def barcode_scan():
    if not sm:
        return _err("State machine not initialized", 503)
    body = request.get_json(silent=True) or {}
    barcode = body.get("barcode", "")
    result = sm.increment_barcode(barcode)
    status = 200 if result["ok"] else 409
    return _ok(result, status)


# ── Commit slot ─────────────────────────────────────────────────────────

@app.route("/api/commit-slot", methods=["POST"])
def commit_slot():
    if not sm:
        return _err("State machine not initialized", 503)
    result = sm.commit_slot()
    status = 200 if result["ok"] else 409
    return _ok(result, status)


# ── Trigger dispense ────────────────────────────────────────────────────

@app.route("/api/trigger-dispense", methods=["POST"])
def trigger_dispense():
    if not sm:
        return _err("State machine not initialized", 503)
    body = request.get_json(silent=True) or {}
    patient_id = body.get("patient_id")
    schedule_id = body.get("schedule_id")
    window_sec = body.get("window_seconds")

    result = sm.trigger_dispense(
        patient_id=patient_id,
        schedule_id=schedule_id,
        window_seconds=int(window_sec) if window_sec and str(window_sec).strip() else None,
    )
    status = 200 if result["ok"] else 409
    return _ok(result, status)


# ── Manual camera override ──────────────────────────────────────────────

@app.route("/api/camera/open", methods=["POST"])
def camera_open():
    if not sm:
        return _err("State machine not initialized", 503)
    data = request.get_json(silent=True) or {}
    patient_id = data.get("patient_id") or None
    result = sm.open_camera_manual(patient_id=patient_id)
    status = 200 if result["ok"] else 409
    return _ok(result, status)


# ── Reset ───────────────────────────────────────────────────────────────

@app.route("/api/reset", methods=["POST"])
def reset():
    if not sm:
        return _err("State machine not initialized", 503)
    result = sm.reset()
    return _ok(result)


# ── Query endpoints ─────────────────────────────────────────────────────

@app.route("/api/slots", methods=["GET"])
def list_slots():
    slots = DispenserStateMachine.get_all_slots()
    return _ok({"ok": True, "slots": slots})


@app.route("/api/slots/available", methods=["GET"])
def list_available_slots():
    """Return slot IDs that have no active schedule assigned.

    A slot is 'occupied' if:
      - It has status != 'empty' in slot_bindings, OR
      - It has an active schedule row in local_schedules.
    Returns slots 0-13 that are free.
    """
    conn = sqlite3.connect(LOCAL_DB)
    conn.row_factory = sqlite3.Row
    try:
        # Slots with active schedules
        occupied_rows = conn.execute("""
            SELECT DISTINCT slot_id FROM local_schedules
            WHERE is_active = 1 AND slot_id IS NOT NULL
        """).fetchall()
        occupied_by_schedule = {r["slot_id"] for r in occupied_rows}

        # Slots loaded / dispensed (not empty)
        busy_rows = conn.execute("""
            SELECT slot_id, status, patient_id FROM slot_bindings
            WHERE status != 'empty'
        """).fetchall()
        busy_slots = {r["slot_id"]: dict(r) for r in busy_rows}
    finally:
        conn.close()

    available = []
    occupied  = []
    for sid in range(14):
        if sid in occupied_by_schedule or sid in busy_slots:
            info = {"slot_id": sid, "available": False}
            if sid in busy_slots:
                info["status"] = busy_slots[sid]["status"]
                info["patient_id"] = busy_slots[sid]["patient_id"]
            else:
                info["status"] = "scheduled"
            occupied.append(info)
        else:
            available.append({"slot_id": sid, "available": True, "status": "empty"})

    return _ok({
        "ok": True,
        "available": available,
        "occupied": occupied,
    })


@app.route("/api/slots/<int:slot_id>/medications", methods=["GET"])
def get_slot_medications_api(slot_id: int):
    meds = DispenserStateMachine.get_slot_medications(slot_id)
    return _ok({"ok": True, "slot_id": slot_id, "medications": meds})


@app.route("/api/slots/<int:slot_id>/medications", methods=["POST"])
def set_slot_medications_api(slot_id: int):
    """Define (replace) the medication list for a slot.

    Body: {
      "medications": [
        {"medication_id": "...", "medication_name": "Aspirin",
         "barcode": "1234", "target_count": 1},
        ...
      ]
    }
    """
    if slot_id < 0 or slot_id > 13:
        return _err("slot_id must be 0-13")
    body = request.get_json(silent=True) or {}
    medications = body.get("medications", [])
    if not isinstance(medications, list):
        return _err("medications must be a list")

    try:
        _db_define_slot_medications(slot_id, medications)
    except Exception as e:
        return _err(f"Failed to set medications: {e}", 500)

    return _ok({"ok": True, "slot_id": slot_id, "medications_set": len(medications)})


@app.route("/api/slots/<int:slot_id>", methods=["DELETE"])
def delete_slot(slot_id: int):
    """Remove a slot binding and its medication definitions."""
    conn = sqlite3.connect(LOCAL_DB)
    try:
        cur = conn.execute(
            "DELETE FROM slot_bindings WHERE slot_id = ?", (slot_id,)
        )
        conn.execute(
            "DELETE FROM slot_medications WHERE slot_id = ?", (slot_id,)
        )
        conn.commit()
    finally:
        conn.close()
    if cur.rowcount == 0:
        return _err(f"Slot {slot_id} not found", 404)
    return _ok({"ok": True, "deleted_slot": slot_id})


@app.route("/api/face-auth-logs", methods=["GET"])
def face_auth_logs():
    limit = request.args.get("limit", 20, type=int)
    logs = DispenserStateMachine.get_face_auth_logs(limit)
    return _ok({"ok": True, "logs": logs})


@app.route("/api/face-auth-logs", methods=["DELETE"])
def clear_face_auth_logs():
    """Delete all face auth log entries."""
    conn = sqlite3.connect(LOCAL_DB)
    try:
        conn.execute("DELETE FROM face_auth_log")
        conn.commit()
    finally:
        conn.close()
    return _ok({"ok": True, "message": "Face auth logs cleared"})


# ── Face registration ───────────────────────────────────────────────────

@app.route("/api/face/register", methods=["POST"])
def face_register():
    """Trigger face registration via Pi camera. Captures N samples."""
    body = request.get_json(silent=True) or {}
    patient_id = body.get("patient_id")
    first_name = body.get("first_name", "")
    last_name = body.get("last_name", "")
    samples = body.get("samples", 5)
    allow_duplicate = body.get("allow_duplicate", False)

    if not patient_id or not first_name or not last_name:
        return _err("patient_id, first_name, and last_name are required")

    try:
        from register import capture_face_encodings, save_user_embedding, check_face_duplicates
        import numpy as np

        encodings = capture_face_encodings(max_samples=min(samples, 10))
        if not encodings:
            return _err("No face samples captured", 422)

        avg = np.mean(encodings, axis=0).astype(np.float32)

        if not allow_duplicate:
            duplicate = check_face_duplicates(avg, threshold=0.6,
                                              exclude_patient_id=patient_id)
            if duplicate:
                return _ok({
                    "ok": False,
                    "duplicate_found": True,
                    "existing_patient_id": duplicate["patient_id"],
                    "existing_name": f"{duplicate['first_name']} {duplicate['last_name']}",
                    "similarity_distance": duplicate["distance"],
                    "message": f"This face matches an existing patient: {duplicate['first_name']} {duplicate['last_name']}. "
                              f"Set allow_duplicate=true to override.",
                }, 409)

        save_user_embedding(
            patient_id, first_name, last_name, avg,
            individual_encodings=encodings,
        )

        return _ok({
            "ok": True,
            "patient_id": patient_id,
            "samples_captured": len(encodings),
            "message": f"Registered {first_name} {last_name} with {len(encodings)} samples",
        })
    except Exception as e:
        return _err(f"Registration failed: {e}", 500)


@app.route("/api/face/users", methods=["GET"])
def face_users():
    """List registered face users (without vectors)."""
    conn = sqlite3.connect(LOCAL_DB)
    try:
        try:
            rows = conn.execute(
                "SELECT patient_id, first_name, last_name FROM local_users"
            ).fetchall()
        except sqlite3.OperationalError:
            return _ok({"ok": True, "users": []})

        users = []
        for pid, fn, ln in rows:
            sample_count = 0
            try:
                row = conn.execute(
                    "SELECT COUNT(*) FROM face_samples WHERE patient_id = ?", (pid,)
                ).fetchone()
                sample_count = row[0] if row else 0
            except sqlite3.OperationalError:
                pass
            users.append({
                "patient_id": pid,
                "first_name": fn,
                "last_name": ln,
                "sample_count": sample_count,
            })

        return _ok({"ok": True, "users": users})
    finally:
        conn.close()


# ── Patients ────────────────────────────────────────────────────────────

def _db():
    conn = sqlite3.connect(LOCAL_DB)
    conn.row_factory = sqlite3.Row
    return conn


def _migrate_local_schedules(conn: sqlite3.Connection) -> None:
    """
    If local_schedules exists but uses the OLD schema (has medication_id or
    is missing slot_id), drop and recreate it so the new architecture works.
    Data loss is acceptable — the user is doing a clean start.
    """
    cols = {
        row[1]
        for row in conn.execute("PRAGMA table_info(local_schedules)").fetchall()
    }
    if not cols:
        return  # table doesn't exist yet; CREATE IF NOT EXISTS will handle it

    needs_rebuild = "slot_id" not in cols or "medication_id" in cols
    if needs_rebuild:
        print("[DB] Migrating local_schedules to new slot-centric schema…", flush=True)
        conn.execute("DROP TABLE IF EXISTS local_schedules")
        conn.execute("DROP TABLE IF EXISTS slot_medications")
        conn.execute("DROP TABLE IF EXISTS slot_bindings")


def _ensure_tables():
    """Create core tables if missing (idempotent)."""
    with _db() as conn:
        _migrate_local_schedules(conn)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS patients (
                patient_id      TEXT PRIMARY KEY,
                first_name      TEXT NOT NULL,
                last_name       TEXT NOT NULL,
                date_of_birth   TEXT,
                created_at      TEXT NOT NULL,
                cloud_synced_at TEXT,
                deleted_at      TEXT
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS medications (
                medication_id       TEXT PRIMARY KEY,
                patient_id          TEXT NOT NULL,
                medication_name     TEXT NOT NULL,
                pill_barcode        TEXT,
                pill_color_shape    TEXT,
                remaining_count     INTEGER DEFAULT 0,
                low_stock_threshold INTEGER DEFAULT 5,
                expiry_date         TEXT,
                created_at          TEXT NOT NULL
            )""")
        # New clean schema: slot_id is required, no medication_id, no dosage_quantity.
        # Each row = one slot + one planned time + frequency settings.
        # Medications for the slot are stored in slot_medications table.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS local_schedules (
                schedule_id     TEXT PRIMARY KEY,
                patient_id      TEXT NOT NULL,
                slot_id         INTEGER NOT NULL,
                planned_time    TEXT NOT NULL,
                is_active       INTEGER DEFAULT 1,
                start_date      TEXT,
                end_date        TEXT,
                frequency_type  TEXT DEFAULT 'daily',
                week_days       TEXT DEFAULT '',
                window_seconds  INTEGER DEFAULT 300,
                group_id        TEXT,
                synced_at       TEXT
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS slot_bindings (
                slot_id     INTEGER PRIMARY KEY,
                patient_id  TEXT,
                status      TEXT DEFAULT 'empty',
                updated_at  TEXT
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS slot_medications (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                slot_id         INTEGER NOT NULL,
                medication_id   TEXT NOT NULL,
                medication_name TEXT,
                barcode         TEXT,
                target_count    INTEGER DEFAULT 1,
                loaded_count    INTEGER DEFAULT 0,
                updated_at      TEXT,
                FOREIGN KEY (slot_id) REFERENCES slot_bindings(slot_id)
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS sync_queue (
                log_id          TEXT PRIMARY KEY,
                patient_id      TEXT NOT NULL,
                schedule_id     TEXT,
                status          TEXT NOT NULL,
                face_auth_score REAL,
                dispensing_at   TEXT,
                taken_at        TEXT,
                device_timestamp TEXT,
                error_details   TEXT,
                is_synced       INTEGER DEFAULT 0,
                retry_count     INTEGER DEFAULT 0
            )""")
        conn.commit()

    _run_migrations()


def _run_migrations():
    """Add missing columns to existing tables (safe to run on every startup)."""
    migrations = [
        ("patients", "cloud_synced_at", "TEXT"),
        ("patients", "deleted_at",      "TEXT"),
    ]
    with _db() as conn:
        for table, column, col_type in migrations:
            existing = [
                row[1] for row in conn.execute(f"PRAGMA table_info({table})")
            ]
            if column not in existing:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {col_type}")
                print(f"[Migration] Added {table}.{column}", flush=True)
        conn.commit()


_ensure_tables()


def _ensure_default_accounts() -> None:
    """Create default caregiver/patient accounts from .env if they don't exist."""
    from auth import create_user
    import dotenv as _dotenv
    _env: dict = {}
    _env_file = os.path.join(os.path.dirname(__file__), ".env")
    if os.path.exists(_env_file):
        for line in open(_env_file).read().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                _env[k.strip()] = v.strip()

    email    = _env.get("DEFAULT_CAREGIVER_EMAIL", "caregiver@medidispense.local")
    password = _env.get("DEFAULT_CAREGIVER_PASSWORD", "MediPass2024!")

    result = create_user(email, password, role="caregiver")
    if result.get("ok"):
        print(f"[Auth] Default caregiver created: {email}", flush=True)


_ensure_default_accounts()


@app.route("/api/patients", methods=["GET"])
def list_patients():
    with _db() as conn:
        rows = conn.execute(
            "SELECT * FROM patients ORDER BY last_name, first_name"
        ).fetchall()
    patients = [dict(r) for r in rows]
    return _ok({"ok": True, "patients": patients})


@app.route("/api/patients", methods=["POST"])
def create_patient():
    body = request.get_json(silent=True) or {}
    first = body.get("first_name", "").strip()
    last  = body.get("last_name", "").strip()
    if not first or not last:
        return _err("first_name and last_name are required")

    pid = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    with _db() as conn:
        conn.execute(
            "INSERT INTO patients (patient_id, first_name, last_name, date_of_birth, created_at, cloud_synced_at) "
            "VALUES (?,?,?,?,?,?)",
            (pid, first, last, body.get("date_of_birth"), now, None),
        )
        conn.commit()
    _fire_and_forget_sync()
    return _ok({"ok": True, "patient_id": pid, "first_name": first, "last_name": last}, 201)


@app.route("/api/patients/<patient_id>", methods=["GET"])
def get_patient(patient_id: str):
    with _db() as conn:
        row = conn.execute(
            "SELECT * FROM patients WHERE patient_id=?", (patient_id,)
        ).fetchone()
    if not row:
        return _err("Patient not found", 404)
    return _ok({"ok": True, **dict(row)})


@app.route("/api/patients/<patient_id>", methods=["PUT"])
def update_patient(patient_id: str):
    body = request.get_json(silent=True) or {}
    first = body.get("first_name", "").strip()
    last  = body.get("last_name", "").strip()
    if not first or not last:
        return _err("first_name and last_name are required")

    with _db() as conn:
        cur = conn.execute(
            "UPDATE patients SET first_name=?, last_name=?, date_of_birth=?, "
            "cloud_synced_at=NULL WHERE patient_id=?",
            (first, last, body.get("date_of_birth"), patient_id),
        )
        conn.commit()
    if cur.rowcount == 0:
        return _err("Patient not found", 404)
    _fire_and_forget_sync()
    return _ok({"ok": True, "patient_id": patient_id, "first_name": first, "last_name": last})


@app.route("/api/patients/<patient_id>", methods=["DELETE"])
def delete_patient(patient_id: str):
    """
    Full patient removal — hard-deletes everything in one transaction.
    """
    with _db() as conn:
        row = conn.execute(
            "SELECT patient_id FROM patients WHERE patient_id=?",
            (patient_id,)
        ).fetchone()
        if not row:
            return _err("Patient not found", 404)

        # 1. Face data
        conn.execute("DELETE FROM face_samples  WHERE patient_id=?", (patient_id,))
        try:
            conn.execute("DELETE FROM local_users   WHERE patient_id=?", (patient_id,))
        except Exception:
            pass

        # 2. Scheduling & dispensing data
        # Collect slot_ids used by this patient's schedules so we can clear medications
        slot_rows = conn.execute(
            "SELECT DISTINCT slot_id FROM local_schedules WHERE patient_id=? AND slot_id IS NOT NULL",
            (patient_id,)
        ).fetchall()
        for srow in slot_rows:
            conn.execute("DELETE FROM slot_medications WHERE slot_id=?", (srow["slot_id"],))

        conn.execute("DELETE FROM local_schedules WHERE patient_id=?", (patient_id,))
        conn.execute("DELETE FROM slot_bindings   WHERE patient_id=?", (patient_id,))
        conn.execute("DELETE FROM sync_queue      WHERE patient_id=?", (patient_id,))

        # 3. Medications (must come before patients row)
        conn.execute("DELETE FROM medications     WHERE patient_id=?", (patient_id,))

        # 4. Patient login account
        try:
            conn.execute("DELETE FROM users WHERE patient_id=?", (patient_id,))
        except Exception:
            pass

        # 5. Patient row — hard delete
        conn.execute("DELETE FROM patients WHERE patient_id=?", (patient_id,))

        conn.commit()

    # 6. Also delete from AWS RDS so sync doesn't resurrect the patient
    try:
        from sync_service import SyncService, _rds_connect
        svc = SyncService()
        if not svc._config_error():
            aws = _rds_connect(svc.env)
            cur = aws.cursor()
            cur.execute("DELETE FROM patients WHERE patient_id=%s", (patient_id,))
            cur.execute("DELETE FROM medications WHERE patient_id=%s", (patient_id,))
            cur.execute("DELETE FROM users WHERE patient_id=%s", (patient_id,))
            aws.commit()
            aws.close()
            print(f"[API] Patient {patient_id} deleted from AWS RDS.", flush=True)
    except Exception as e:
        print(f"[API] AWS delete failed (non-critical): {e}", flush=True)

    print(f"[API] Patient {patient_id} and all related data hard-deleted.", flush=True)
    return _ok({"ok": True, "deleted": patient_id})


# ── Medications ──────────────────────────────────────────────────────────

@app.route("/api/medications/barcode/<path:barcode>", methods=["GET"])
def get_medication_by_barcode(barcode: str):
    """Look up medication info by barcode across all patients."""
    with _db() as conn:
        row = conn.execute(
            """SELECT medication_name, pill_barcode, pill_color_shape, expiry_date
               FROM medications WHERE pill_barcode=? LIMIT 1""",
            (barcode,),
        ).fetchone()
    if not row:
        return _err("No medication found with this barcode", 404)
    return _ok({"ok": True, "medication": dict(row)})


@app.route("/api/medications/patient/<patient_id>", methods=["GET"])
def list_medications(patient_id: str):
    with _db() as conn:
        rows = conn.execute(
            "SELECT * FROM medications WHERE patient_id=? ORDER BY medication_name",
            (patient_id,),
        ).fetchall()
    return _ok({"ok": True, "medications": [dict(r) for r in rows]})


@app.route("/api/medications", methods=["POST"])
def create_medication():
    body = request.get_json(silent=True) or {}
    pid  = body.get("patient_id", "").strip()
    name = body.get("medication_name", "").strip()
    if not pid or not name:
        return _err("patient_id and medication_name are required")

    mid = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    with _db() as conn:
        conn.execute(
            """INSERT INTO medications
               (medication_id, patient_id, medication_name, pill_barcode,
                pill_color_shape, remaining_count, low_stock_threshold, expiry_date, created_at)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            (
                mid, pid, name,
                body.get("pill_barcode"),
                body.get("pill_color_shape"),
                int(body.get("remaining_count", 0)),
                int(body.get("low_stock_threshold", 5)),
                body.get("expiry_date"),
                now,
            ),
        )
        conn.commit()
    _fire_and_forget_sync()
    return _ok({"ok": True, "medication_id": mid, "medication_name": name}, 201)


@app.route("/api/medications/<medication_id>", methods=["PUT"])
def update_medication(medication_id: str):
    body = request.get_json(silent=True) or {}
    with _db() as conn:
        row = conn.execute(
            "SELECT medication_id FROM medications WHERE medication_id=?",
            (medication_id,),
        ).fetchone()
        if not row:
            return _err("Medication not found", 404)

        fields = []
        values = []
        for col, key in [
            ("medication_name",    "medication_name"),
            ("pill_barcode",       "pill_barcode"),
            ("pill_color_shape",   "pill_color_shape"),
            ("remaining_count",    "remaining_count"),
            ("low_stock_threshold","low_stock_threshold"),
            ("expiry_date",        "expiry_date"),
        ]:
            if key in body:
                fields.append(f"{col}=?")
                val = body[key]
                if col in ("remaining_count", "low_stock_threshold") and val is not None:
                    val = int(val)
                values.append(val)

        if not fields:
            return _err("No fields to update")

        # Always reset cloud_synced_at so the sync service will re-push this row
        fields.append("cloud_synced_at=?")
        values.append(None)

        values.append(medication_id)
        conn.execute(
            f"UPDATE medications SET {', '.join(fields)} WHERE medication_id=?",
            values,
        )
        conn.commit()
    _fire_and_forget_sync()
    return _ok({"ok": True, "medication_id": medication_id})


@app.route("/api/medications/<medication_id>", methods=["DELETE"])
def delete_medication(medication_id: str):
    with _db() as conn:
        row = conn.execute(
            "SELECT medication_id FROM medications WHERE medication_id=?",
            (medication_id,),
        ).fetchone()
        if not row:
            return _err("Medication not found", 404)
        conn.execute(
            "DELETE FROM medications WHERE medication_id=?", (medication_id,)
        )
        conn.commit()

    # Best-effort delete from AWS RDS so sync doesn't resurrect the row
    try:
        from sync_service import SyncService, _rds_connect
        svc = SyncService()
        if not svc._config_error():
            aws = _rds_connect(svc.env)
            cur = aws.cursor()
            cur.execute(
                "DELETE FROM medications WHERE medication_id=%s", (medication_id,)
            )
            aws.commit()
            aws.close()
            print(f"[API] Medication {medication_id} deleted from AWS RDS.", flush=True)
    except Exception as e:
        print(f"[API] AWS medication delete skipped (non-critical): {e}", flush=True)

    return _ok({"ok": True, "deleted": medication_id})


# ── Schedules ─────────────────────────────────────────────────────────────
#
# New architecture:
#   - One schedule row = one slot + one planned_time + frequency settings
#   - Medications are stored per-slot in slot_medications table
#   - No medication_id or dosage_quantity on schedule rows
#   - slot_id is required
#   - group_id is optional (for UI grouping of related slots)
#   - Slot occupancy: creating a schedule for an already-scheduled slot → 409
# ─────────────────────────────────────────────────────────────────────────

def _get_slot_medications_for_schedule(slot_id: int, conn) -> list:
    """Return medication list for a slot from slot_medications table."""
    rows = conn.execute("""
        SELECT medication_id, medication_name, barcode,
               target_count, loaded_count
        FROM slot_medications
        WHERE slot_id = ?
        ORDER BY id
    """, (slot_id,)).fetchall()
    return [dict(r) for r in rows]


@app.route("/api/schedules/<patient_id>", methods=["GET"])
def list_schedules(patient_id: str):
    """List schedules for a patient, enriched with medications from slot_medications."""
    with _db() as conn:
        rows = conn.execute("""
            SELECT ls.schedule_id, ls.patient_id, ls.slot_id,
                   ls.planned_time, ls.is_active,
                   ls.start_date, ls.end_date,
                   COALESCE(ls.frequency_type, 'daily') AS frequency_type,
                   COALESCE(ls.week_days, '')            AS week_days,
                   ls.group_id,
                   COALESCE(ls.window_seconds, 300)      AS window_seconds,
                   COALESCE(sb.status, 'empty')          AS slot_status
            FROM local_schedules ls
            LEFT JOIN slot_bindings sb ON ls.slot_id = sb.slot_id
            WHERE ls.patient_id = ?
            ORDER BY ls.slot_id, ls.planned_time
        """, (patient_id,)).fetchall()

        schedules = []
        for r in rows:
            s = dict(r)
            # Attach medications for this slot
            s["medications"] = _get_slot_medications_for_schedule(s["slot_id"], conn)
            schedules.append(s)

    return _ok({"ok": True, "schedules": schedules})


@app.route("/api/schedules", methods=["POST"])
def create_schedule():
    """
    Create a schedule for one slot.

    Body: {
      patient_id:      str   (required),
      slot_id:         int   (required, 0-13),
      planned_time:    str   "HH:MM" (required),
      frequency_type:  str   "daily" | "weekly" | "alternate"  (default "daily"),
      week_days:       str   "0,2,4"  Mon=0 … Sun=6 (for weekly),
      start_date:      str   "YYYY-MM-DD" (default today),
      end_date:        str   "YYYY-MM-DD" or null,
      window_seconds:  int   30-3600 (default 300),
      group_id:        str   optional, to group related slots,
      medications: [
        { medication_id, medication_name, barcode?, target_count }
      ]
    }
    """
    body = request.get_json(silent=True) or {}

    patient_id   = (body.get("patient_id") or "").strip()
    slot_id_raw  = body.get("slot_id")
    planned_time = (body.get("planned_time") or "").strip()

    if not patient_id:
        return _err("patient_id is required")
    if slot_id_raw is None:
        return _err("slot_id is required")
    if not planned_time:
        return _err("planned_time is required")

    try:
        slot_id = int(slot_id_raw)
    except (ValueError, TypeError):
        return _err("slot_id must be an integer")

    if slot_id < 0 or slot_id > 13:
        return _err("slot_id must be 0-13")

    # Validate patient exists
    with _db() as conn:
        p_row = conn.execute(
            "SELECT patient_id FROM patients WHERE patient_id=?", (patient_id,)
        ).fetchone()
    if not p_row:
        return _err("Patient not found", 404)

    # Slot occupancy check: refuse if another active schedule already uses this slot
    with _db() as conn:
        existing = conn.execute("""
            SELECT schedule_id, patient_id FROM local_schedules
            WHERE slot_id = ? AND is_active = 1
            LIMIT 1
        """, (slot_id,)).fetchone()
    if existing:
        return _err(
            f"Slot {slot_id} is already occupied by an active schedule "
            f"(patient: {existing['patient_id']}, schedule: {existing['schedule_id']}). "
            f"Deactivate or delete the existing schedule first.",
            409,
        )

    # Also check slot_bindings status — refuse if already loaded/dispensed
    with _db() as conn:
        sb_row = conn.execute(
            "SELECT status FROM slot_bindings WHERE slot_id=?", (slot_id,)
        ).fetchone()
    if sb_row and sb_row["status"] != "empty":
        return _err(
            f"Slot {slot_id} is currently '{sb_row['status']}'. "
            f"Cannot assign a new schedule until it is emptied.",
            409,
        )

    frequency_type = body.get("frequency_type", "daily")
    week_days      = body.get("week_days", "")
    start_date     = body.get("start_date") or datetime.now(timezone.utc).date().isoformat()
    end_date       = body.get("end_date")
    window_seconds = max(30, min(3600, int(body.get("window_seconds", 300))))
    group_id       = body.get("group_id") or str(uuid.uuid4())
    medications    = body.get("medications", [])

    # Create the schedule row
    schedule_id = str(uuid.uuid4())
    with _db() as conn:
        conn.execute("""
            INSERT INTO local_schedules
                (schedule_id, patient_id, slot_id, planned_time,
                 is_active, start_date, end_date,
                 frequency_type, week_days, window_seconds, group_id)
            VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
        """, (
            schedule_id, patient_id, slot_id, planned_time,
            start_date, end_date,
            frequency_type, week_days, window_seconds, group_id,
        ))
        conn.commit()

    # Bind the slot to this patient (creates or updates slot_bindings row, status = 'empty')
    with _db() as conn:
        conn.execute("""
            INSERT INTO slot_bindings (slot_id, patient_id, status, updated_at)
            VALUES (?, ?, 'empty', ?)
            ON CONFLICT(slot_id) DO UPDATE SET patient_id=excluded.patient_id,
                                               updated_at=excluded.updated_at
        """, (slot_id, patient_id, datetime.now(timezone.utc).isoformat()))
        conn.commit()

    # Define medications for this slot
    if medications:
        try:
            _db_define_slot_medications(slot_id, medications)
        except Exception as e:
            print(f"[Schedule] Warning: failed to set slot medications: {e}", flush=True)

    _fire_and_forget_sync()

    return _ok({
        "ok": True,
        "schedule_id": schedule_id,
        "group_id": group_id,
        "slot_id": slot_id,
        "medications_set": len(medications),
    }, 201)


@app.route("/api/schedules/group/<group_id>", methods=["PUT"])
def update_schedule_group(group_id: str):
    """
    Update schedule metadata for all rows in a group.
    Does NOT change slot_id or medications (those are slot-level, not group-level).

    Accepts same fields as POST /api/schedules (except slot_id, medications).
    """
    body = request.get_json(silent=True) or {}

    with _db() as conn:
        existing = conn.execute(
            "SELECT schedule_id, patient_id, slot_id FROM local_schedules WHERE group_id=?",
            (group_id,)
        ).fetchall()
    if not existing:
        return _err("Schedule group not found", 404)

    planned_time   = (body.get("planned_time") or "").strip()
    frequency_type = body.get("frequency_type", "daily")
    week_days      = body.get("week_days", "")
    start_date     = body.get("start_date") or datetime.now(timezone.utc).date().isoformat()
    end_date       = body.get("end_date")
    window_seconds = max(30, min(3600, int(body.get("window_seconds", 300))))

    # Build update query — only update non-None provided fields
    updates = {
        "frequency_type": frequency_type,
        "week_days": week_days,
        "start_date": start_date,
        "window_seconds": window_seconds,
        "synced_at": None,  # mark for re-sync
    }
    if end_date is not None:
        updates["end_date"] = end_date
    if planned_time:
        updates["planned_time"] = planned_time

    set_clause = ", ".join(f"{k}=?" for k in updates)
    values = list(updates.values()) + [group_id]

    with _db() as conn:
        conn.execute(
            f"UPDATE local_schedules SET {set_clause} WHERE group_id=?",
            values,
        )
        conn.commit()

    # If medications were provided, update them per slot
    medications = body.get("medications")
    if medications is not None:
        for row in existing:
            try:
                _db_define_slot_medications(row["slot_id"], medications)
            except Exception as e:
                print(f"[Schedule] Warning: failed to update slot {row['slot_id']} medications: {e}", flush=True)

    return _ok({"ok": True, "group_id": group_id, "updated": len(existing)})


@app.route("/api/schedules/<schedule_id>", methods=["PUT"])
def update_schedule(schedule_id: str):
    """
    Update a single schedule row.
    Can update: planned_time, frequency_type, week_days, start_date, end_date,
                window_seconds, medications.
    Cannot change slot_id or patient_id.
    """
    body = request.get_json(silent=True) or {}

    with _db() as conn:
        row = conn.execute(
            "SELECT * FROM local_schedules WHERE schedule_id=?", (schedule_id,)
        ).fetchone()
    if not row:
        return _err("Schedule not found", 404)

    planned_time   = (body.get("planned_time") or row["planned_time"]).strip()
    frequency_type = body.get("frequency_type", row["frequency_type"])
    week_days      = body.get("week_days", row["week_days"] or "")
    start_date     = body.get("start_date", row["start_date"])
    end_date       = body.get("end_date", row["end_date"])
    window_seconds = max(30, min(3600, int(body.get("window_seconds", row["window_seconds"] or 300))))

    with _db() as conn:
        conn.execute("""
            UPDATE local_schedules
            SET planned_time=?, frequency_type=?, week_days=?,
                start_date=?, end_date=?, window_seconds=?, synced_at=NULL
            WHERE schedule_id=?
        """, (planned_time, frequency_type, week_days, start_date, end_date, window_seconds, schedule_id))
        conn.commit()

    medications = body.get("medications")
    if medications is not None:
        try:
            _db_define_slot_medications(row["slot_id"], medications)
        except Exception as e:
            print(f"[Schedule] Warning: failed to update slot medications: {e}", flush=True)

    return _ok({"ok": True, "schedule_id": schedule_id})


@app.route("/api/schedules/group/<group_id>/active", methods=["PATCH"])
def toggle_schedule_group_active(group_id: str):
    """Toggle is_active for all schedules in a group."""
    with _db() as conn:
        row = conn.execute(
            "SELECT is_active FROM local_schedules WHERE group_id=? LIMIT 1",
            (group_id,)
        ).fetchone()
    if not row:
        return _err("Schedule group not found", 404)
    new_state = 0 if row["is_active"] else 1
    with _db() as conn:
        conn.execute(
            "UPDATE local_schedules SET is_active=?, synced_at=NULL WHERE group_id=?",
            (new_state, group_id)
        )
        conn.commit()
    return _ok({"ok": True, "group_id": group_id, "is_active": bool(new_state)})


@app.route("/api/schedules/<schedule_id>/active", methods=["PATCH"])
def toggle_schedule_active(schedule_id: str):
    """Toggle is_active for a single schedule."""
    with _db() as conn:
        row = conn.execute(
            "SELECT is_active FROM local_schedules WHERE schedule_id=? LIMIT 1",
            (schedule_id,)
        ).fetchone()
    if not row:
        return _err("Schedule not found", 404)
    new_state = 0 if row["is_active"] else 1
    with _db() as conn:
        conn.execute(
            "UPDATE local_schedules SET is_active=?, synced_at=NULL WHERE schedule_id=?",
            (new_state, schedule_id)
        )
        conn.commit()
    return _ok({"ok": True, "schedule_id": schedule_id, "is_active": bool(new_state)})


@app.route("/api/schedules/group/<group_id>", methods=["DELETE"])
def delete_schedule_group(group_id: str):
    """Delete all schedule rows in a group (local + AWS)."""
    with _db() as conn:
        id_rows = conn.execute(
            "SELECT schedule_id, slot_id FROM local_schedules WHERE group_id=?", (group_id,)
        ).fetchall()
    if not id_rows:
        return _err("Schedule group not found", 404)

    schedule_ids = [r["schedule_id"] for r in id_rows]
    slot_ids = [r["slot_id"] for r in id_rows if r["slot_id"] is not None]

    with _db() as conn:
        conn.execute("DELETE FROM local_schedules WHERE group_id=?", (group_id,))
        # Only clear slot medications for slots whose bindings are still empty
        for sid in slot_ids:
            sb = conn.execute(
                "SELECT status FROM slot_bindings WHERE slot_id=?", (sid,)
            ).fetchone()
            if not sb or sb["status"] == "empty":
                conn.execute("DELETE FROM slot_medications WHERE slot_id=?", (sid,))
        conn.commit()

    # Best-effort delete from AWS RDS
    try:
        from sync_service import SyncService, _rds_connect
        svc = SyncService()
        if not svc._config_error():
            aws = _rds_connect(svc.env)
            cur = aws.cursor()
            for sid in schedule_ids:
                cur.execute(
                    "DELETE FROM medication_schedules WHERE schedule_id=%s", (sid,)
                )
            aws.commit()
            aws.close()
    except Exception as e:
        print(f"[Schedule] AWS group delete skipped: {e}", flush=True)

    return _ok({"ok": True, "deleted_group": group_id})


@app.route("/api/schedules/<schedule_id>", methods=["DELETE"])
def delete_schedule(schedule_id: str):
    """Delete a single schedule row."""
    with _db() as conn:
        row = conn.execute(
            "SELECT slot_id FROM local_schedules WHERE schedule_id=?", (schedule_id,)
        ).fetchone()
    if not row:
        return _err("Schedule not found", 404)

    slot_id = row["slot_id"]

    with _db() as conn:
        conn.execute("DELETE FROM local_schedules WHERE schedule_id=?", (schedule_id,))
        # Clear slot medications only if the slot is still empty
        if slot_id is not None:
            sb = conn.execute(
                "SELECT status FROM slot_bindings WHERE slot_id=?", (slot_id,)
            ).fetchone()
            if not sb or sb["status"] == "empty":
                conn.execute("DELETE FROM slot_medications WHERE slot_id=?", (slot_id,))
        conn.commit()

    return _ok({"ok": True, "deleted": schedule_id})


# ── Dispensing Logs ───────────────────────────────────────────────────────

@app.route("/api/dispensing-logs/<patient_id>", methods=["GET"])
def get_dispensing_logs(patient_id: str):
    with _db() as conn:
        rows = conn.execute("""
            SELECT log_id, patient_id, schedule_id, status,
                   face_auth_score, dispensing_at, taken_at,
                   device_timestamp, error_details, is_synced
            FROM sync_queue
            WHERE patient_id = ?
            ORDER BY dispensing_at DESC
        """, (patient_id,)).fetchall()
    return _ok({"ok": True, "logs": [dict(r) for r in rows]})


@app.route("/api/dispensing-logs", methods=["POST"])
def create_dispensing_log():
    body = request.get_json(silent=True) or {}
    patient_id = body.get("patient_id", "").strip()
    status     = body.get("status", "").strip()
    if not patient_id or not status:
        return _err("patient_id and status are required")

    log_id = str(uuid.uuid4())
    now    = datetime.now(timezone.utc).isoformat()
    with _db() as conn:
        conn.execute("""
            INSERT INTO sync_queue
                (log_id, patient_id, schedule_id, status,
                 face_auth_score, dispensing_at, device_timestamp, error_details)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            log_id,
            patient_id,
            body.get("schedule_id"),
            status,
            body.get("face_auth_score"),
            now,
            body.get("device_timestamp", now),
            body.get("error_details"),
        ))
        conn.commit()
    return _ok({"ok": True, "log_id": log_id}, 201)


# ── Auth ────────────────────────────────────────────────────────────────

@app.route("/api/auth/signup", methods=["POST"])
def auth_signup():
    from auth import create_user, DISPENSER_MODEL_ID
    body = request.get_json(silent=True) or {}
    email      = body.get("email", "").strip()
    password   = body.get("password", "")
    model_id   = body.get("model_id", "").strip().upper()
    patient_id = body.get("patient_id")

    if not email or not password:
        return _err("email and password are required")

    if model_id:
        if model_id != DISPENSER_MODEL_ID.strip().upper():
            return _err("Invalid Model ID", 403)
        role = "caregiver"
        patient_id = None
    else:
        role = "patient"

    result = create_user(email, password, role=role, patient_id=patient_id)
    status = 200 if result["ok"] else 409
    return _ok(result, status)


@app.route("/api/auth/login", methods=["POST"])
def auth_login():
    from auth import authenticate_user
    body = request.get_json(silent=True) or {}
    email    = body.get("email", "").strip()
    password = body.get("password", "")

    if not email or not password:
        return _err("email and password are required")

    result = authenticate_user(email, password)
    status = 200 if result["ok"] else 401
    return _ok(result, status)


@app.route("/api/auth/model-id-hint", methods=["GET"])
def model_id_hint():
    from auth import DISPENSER_MODEL_ID
    hint = DISPENSER_MODEL_ID[:4] + "*" * (len(DISPENSER_MODEL_ID) - 4)
    return _ok({"ok": True, "hint": hint})


@app.route("/api/auth/patient-account", methods=["POST"])
def create_patient_account():
    from auth import create_user
    body       = request.get_json(silent=True) or {}
    email      = body.get("email", "").strip()
    password   = body.get("password", "")
    patient_id = body.get("patient_id", "").strip()

    if not email or not password or not patient_id:
        return _err("email, password and patient_id are required")

    with _db() as conn:
        row = conn.execute(
            "SELECT patient_id FROM patients WHERE patient_id=?",
            (patient_id,)
        ).fetchone()
    if not row:
        return _err("Patient not found", 404)

    result = create_user(email, password, role="patient", patient_id=patient_id)
    status = 201 if result["ok"] else 409
    return _ok(result, status)


@app.route("/api/auth/patient-accounts", methods=["GET"])
def list_patient_accounts():
    conn = sqlite3.connect(LOCAL_DB)
    try:
        rows = conn.execute(
            "SELECT email, patient_id, created_at FROM users WHERE role='patient' ORDER BY created_at DESC"
        ).fetchall()
    finally:
        conn.close()
    accounts = [{"email": r[0], "patient_id": r[1], "created_at": r[2]} for r in rows]
    return _ok({"ok": True, "accounts": accounts})


# ── Cloud sync ──────────────────────────────────────────────────────────

@app.route("/api/sync/status", methods=["GET"])
def sync_status():
    from sync_service import SyncService
    return _ok(SyncService().get_status())


@app.route("/api/sync", methods=["POST"])
def sync_full():
    from sync_service import SyncService
    result = SyncService().full_sync()
    status = 200 if result.get("ok") else 500
    return _ok(result, status)


@app.route("/api/sync/push", methods=["POST"])
def sync_push():
    from sync_service import SyncService, _rds_connect
    svc = SyncService()
    err = svc._config_error()
    if err:
        return _err(err, 503)
    try:
        aws = _rds_connect(svc.env)
    except Exception as e:
        return _err(f"RDS connection failed: {e}", 503)
    try:
        results = {
            "push_patients":        svc._push_patients(aws),
            "push_medications":     svc._push_medications(aws),
            "push_dispensing_logs": svc._push_dispensing_logs(aws),
            "push_schedules":       svc._push_schedules(aws),
            "push_slot_medications":svc._push_slot_medications(aws),
        }
    finally:
        aws.close()
    return _ok({"ok": True, "results": results})


@app.route("/api/sync/pull", methods=["POST"])
def sync_pull():
    from sync_service import SyncService, _rds_connect
    svc = SyncService()
    err = svc._config_error()
    if err:
        return _err(err, 503)
    try:
        aws = _rds_connect(svc.env)
    except Exception as e:
        return _err(f"RDS connection failed: {e}", 503)
    try:
        results = {
            "pull_patients":    svc._pull_patients(aws),
            "pull_medications": svc._pull_medications(aws),
            "pull_schedules":   svc._pull_schedules(aws),
        }
    finally:
        aws.close()
    return _ok({"ok": True, "results": results})


# ── Health check ────────────────────────────────────────────────────────

@app.route("/api/health", methods=["GET"])
def health():
    return _ok({
        "ok": True,
        "service": "MediDispense Pi Backend",
        "state": sm.state.value if sm else "not_initialized",
    })


# ── Error handlers ──────────────────────────────────────────────────────

@app.errorhandler(404)
def not_found(_):
    return _err("Endpoint not found", 404)


@app.errorhandler(500)
def internal_error(_):
    return _err("Internal server error", 500)


# ── Kiosk / Scheduler endpoints ────────────────────────────────────────

_kiosk_scheduler = None


def set_kiosk_scheduler(scheduler):
    """Called by kiosk_app to allow API-triggered dispensing."""
    global _kiosk_scheduler
    _kiosk_scheduler = scheduler


@app.route("/api/dispense/trigger", methods=["POST"])
def api_trigger_dispense_schedule():
    """Manually trigger a specific schedule for dispensing (for testing).
    Body: {"schedule_id": "..."}
    """
    body = request.get_json(silent=True) or {}
    schedule_id = body.get("schedule_id")
    if not schedule_id:
        return _err("schedule_id is required")

    if not _kiosk_scheduler:
        return _err("Kiosk scheduler not running", 503)

    result = _kiosk_scheduler.trigger_now(schedule_id)
    if result:
        meds_summary = ", ".join(
            m.get("medication_name", "?") for m in (result.medications or [])
        )
        return _ok({
            "ok": True,
            "message": f"Triggered: slot {result.slot_id} for {result.patient_name}",
            "schedule": {
                "schedule_id": result.schedule_id,
                "patient_name": result.patient_name,
                "slot_id": result.slot_id,
                "medications": result.medications,
                "medications_summary": meds_summary,
            },
        })
    return _err("Schedule not found", 404)


@app.route("/api/dispense/next", methods=["GET"])
def api_next_schedule():
    """Get the next upcoming scheduled medication."""
    if not _kiosk_scheduler:
        return _err("Kiosk scheduler not running", 503)

    nxt = _kiosk_scheduler.get_next_schedule()
    if nxt:
        return _ok({
            "ok": True,
            "next_schedule": {
                "schedule_id": nxt.schedule_id,
                "patient_name": nxt.patient_name,
                "slot_id": nxt.slot_id,
                "planned_time": nxt.planned_time,
                "medications": nxt.medications,
                "window_seconds": nxt.window_seconds,
            },
        })
    return _ok({"ok": True, "next_schedule": None,
                "message": "No upcoming schedules"})


@app.route("/api/servo/test", methods=["POST"])
def api_servo_test():
    """Test the servo motor (open/close cycle)."""
    body = request.get_json(silent=True) or {}
    action = body.get("action", "cycle")

    try:
        from servo_control import ServoController
        servo = ServoController()
        if action == "open":
            ok = servo.open_gate()
            return _ok({"ok": ok, "message": "Gate opened" if ok else "Open failed"})
        elif action == "close":
            ok = servo.close_gate()
            return _ok({"ok": ok, "message": "Gate closed" if ok else "Close failed"})
        else:
            ok = servo.dispense_cycle()
            return _ok({"ok": ok, "message": "Cycle complete" if ok else "Cycle failed"})
    except Exception as e:
        return _err(f"Servo error: {e}", 500)


# ── Entry point ─────────────────────────────────────────────────────────

def create_app(motor_controller=None) -> Flask:
    """Factory for external usage (e.g. gunicorn or testing)."""
    global sm
    sm = DispenserStateMachine(motor_controller=motor_controller)
    return app


def _fire_and_forget_sync() -> None:
    """
    Immediately kick off a full_sync() in a short-lived daemon thread.
    Called after any write operation so changes reach AWS within seconds,
    without blocking the HTTP response.
    """
    def _run():
        try:
            from sync_service import SyncService
            result = SyncService().full_sync()
            ok = result.get("ok", False)
            print(f"[Sync] Immediate push {'OK' if ok else 'PARTIAL'}: "
                  f"{result.get('results', {})}", flush=True)
        except Exception as e:
            print(f"[Sync] Immediate push error: {e}", flush=True)

    t = threading.Thread(target=_run, daemon=True)
    t.start()


def _start_background_sync(interval_minutes: int = 60) -> None:
    """Run full_sync() in a daemon thread, then reschedule itself."""

    def _run():
        print("[Sync] Background sync started", flush=True)
        try:
            from sync_service import SyncService
            result = SyncService().full_sync()
            ok = result.get("ok", False)
            synced_at = result.get("synced_at", "?")
            print(f"[Sync] {'OK' if ok else 'PARTIAL'} at {synced_at}", flush=True)
            if result.get("errors"):
                for e in result["errors"]:
                    print(f"[Sync]   error: {e}", flush=True)
        except Exception as e:
            print(f"[Sync] Background sync error: {e}", flush=True)
        finally:
            t = threading.Timer(interval_minutes * 60, _run)
            t.daemon = True
            t.start()

    t = threading.Timer(10, _run)
    t.daemon = True
    t.start()
    print(f"[Sync] Background sync scheduled every {interval_minutes} min", flush=True)


AUTO_SYNC_INTERVAL = 300  # seconds


def _auto_sync_loop():
    """Background thread: sync with AWS every AUTO_SYNC_INTERVAL seconds."""
    time.sleep(30)
    while True:
        try:
            from sync_service import SyncService
            result = SyncService().full_sync()
            if result.get("ok"):
                r = result.get("results", {})
                print(
                    f"[AutoSync] OK — meds: {r.get('push_medications', {})}, "
                    f"patients: {r.get('push_patients', {})}, "
                    f"schedules: {r.get('push_schedules', {})}",
                    flush=True,
                )
            else:
                print(f"[AutoSync] Partial/failed: {result.get('errors')}", flush=True)
        except Exception as e:
            print(f"[AutoSync] Error: {e}", flush=True)
        time.sleep(AUTO_SYNC_INTERVAL)


def main():
    global sm

    motor = None
    try:
        from motor_controller import MotorController
        motor = MotorController()
        print("[API] Motor controller loaded")
    except Exception:
        print("[API] Motor controller not available — dry run mode")

    sm = DispenserStateMachine(motor_controller=motor)

    _ensure_tables()
    _ensure_default_accounts()

    sync_interval = int(os.environ.get("SYNC_INTERVAL_MINUTES", "60"))
    _start_background_sync(interval_minutes=sync_interval)

    host  = os.environ.get("API_HOST",  "0.0.0.0")
    port  = int(os.environ.get("API_PORT",  "5000"))
    debug = os.environ.get("API_DEBUG", "0") == "1"

    sync_thread = threading.Thread(target=_auto_sync_loop, name="auto-sync", daemon=True)
    sync_thread.start()
    print(f"[API] Auto-sync enabled every {AUTO_SYNC_INTERVAL}s", flush=True)

    print(f"[API] Starting on {host}:{port} (debug={debug})")
    app.run(host=host, port=port, debug=debug, threaded=True)


if __name__ == "__main__":
    main()
