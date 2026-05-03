"""
Cloud sync service for MediDispense Pi backend.
Uses direct PostgreSQL connection to AWS RDS for bidirectional sync.

Strategy:
  Push (Pi → AWS): patients, medications, dispensing_logs
  Pull (AWS → Pi): patients, medications, schedules  (cloud wins on conflict)

AWS credentials are loaded from .env or environment variables.
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

_log = logging.getLogger("sync_service")

_SCRIPT_DIR = Path(__file__).parent
DB_PATH     = Path(os.environ.get("FACES_DB", str(_SCRIPT_DIR / "faces.db")))
STATE_FILE  = _SCRIPT_DIR / "sync_state.json"


# ── .env loader ──────────────────────────────────────────────────────────────

def _load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    env_file = _SCRIPT_DIR / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip()
    # Environment variables override .env (useful for systemd)
    for key in ("DB_HOST", "DB_PORT", "DB_NAME", "DB_USER",
                "DB_PASSWORD", "DB_SSLMODE"):
        if key in os.environ:
            env[key] = os.environ[key]
    return env


# ── Local SQLite ──────────────────────────────────────────────────────────────

def _local_db() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def _ensure_sync_schema() -> None:
    """
    Add sync-related columns to Pi's local SQLite tables (idempotent).
    local_schedules is created/managed by api_server._ensure_tables() —
    we only add columns here that may be missing from older installs.
    """
    conn = _local_db()
    try:
        # Sync tracking columns for patients / medications
        for stmt in [
            "ALTER TABLE patients    ADD COLUMN cloud_synced_at TEXT",
            "ALTER TABLE medications ADD COLUMN cloud_synced_at TEXT",
        ]:
            try:
                conn.execute(stmt)
            except Exception:
                pass  # column already exists

        # New columns for local_schedules (new architecture).
        # CREATE TABLE is handled by api_server; we only ALTER here for migrations.
        for col, typedef in [
            ("window_seconds", "INTEGER DEFAULT 300"),
            ("group_id",       "TEXT"),
            ("frequency_type", "TEXT DEFAULT 'daily'"),
            ("week_days",      "TEXT DEFAULT ''"),
        ]:
            try:
                conn.execute(
                    f"ALTER TABLE local_schedules ADD COLUMN {col} {typedef}"
                )
            except Exception:
                pass  # already exists

        conn.commit()
    finally:
        conn.close()


# ── AWS RDS connection ────────────────────────────────────────────────────────

def _rds_connect(env: dict[str, str]):
    """Open a psycopg2 connection to AWS RDS."""
    import psycopg2
    import psycopg2.extras

    conn = psycopg2.connect(
        host=env["DB_HOST"],
        port=int(env.get("DB_PORT", 5432)),
        dbname=env["DB_NAME"],
        user=env["DB_USER"],
        password=env["DB_PASSWORD"],
        sslmode=env.get("DB_SSLMODE", "require"),
        connect_timeout=10,
    )
    conn.cursor_factory = psycopg2.extras.RealDictCursor
    return conn


def _migrate_aws_schema(aws) -> None:
    """
    Ensure AWS RDS schema matches the slot-centric Pi architecture.
    Safe to run on every sync (fully idempotent).

    Strategy:
    - CREATE TABLE IF NOT EXISTS for every table the sync service needs.
    - ADD COLUMN IF NOT EXISTS for columns added in later revisions.
    - DROP NOT NULL on medication_schedules.medication_id so slot-centric
      schedules (which have no medication_id) can be pushed without error.
    """
    cur = aws.cursor()

    # ── Helper ────────────────────────────────────────────────────────────────
    def _exec(sql: str, label: str = "") -> None:
        try:
            cur.execute(sql)
            aws.commit()
        except Exception as e:
            aws.rollback()
            print(f"[AWS Migration] {label or sql[:60]}: {e}", flush=True)

    # ── Create tables if they don't exist ────────────────────────────────────

    _exec("""
        CREATE TABLE IF NOT EXISTS patients (
            patient_id      VARCHAR(255) PRIMARY KEY,
            first_name      VARCHAR(100) NOT NULL,
            last_name       VARCHAR(100) NOT NULL,
            date_of_birth   TEXT,
            deleted_at      TEXT,
            cloud_synced_at TEXT,
            created_at      TEXT
        )
    """, "create patients")

    _exec("""
        CREATE TABLE IF NOT EXISTS medications (
            medication_id       VARCHAR(255) PRIMARY KEY,
            patient_id          VARCHAR(255) NOT NULL,
            medication_name     VARCHAR(200) NOT NULL,
            pill_barcode        VARCHAR(100),
            pill_color_shape    VARCHAR(100),
            remaining_count     INTEGER      DEFAULT 0,
            low_stock_threshold INTEGER      DEFAULT 5,
            expiry_date         TEXT,
            created_at          TEXT,
            cloud_synced_at     TEXT
        )
    """, "create medications")

    _exec("""
        CREATE TABLE IF NOT EXISTS medication_schedules (
            schedule_id     VARCHAR(255) PRIMARY KEY,
            patient_id      VARCHAR(255),
            slot_id         INTEGER,
            medication_id   VARCHAR(255),
            planned_time    TEXT         NOT NULL,
            is_active       BOOLEAN      DEFAULT TRUE,
            start_date      TEXT,
            end_date        TEXT,
            frequency_type  TEXT         DEFAULT 'daily',
            week_days       TEXT         DEFAULT '',
            window_seconds  INTEGER      DEFAULT 300,
            group_id        VARCHAR(255),
            dosage_quantity INTEGER      DEFAULT 1
        )
    """, "create medication_schedules")

    _exec("""
        CREATE TABLE IF NOT EXISTS slot_bindings (
            slot_id    INTEGER      PRIMARY KEY,
            patient_id VARCHAR(255),
            status     VARCHAR(50)  DEFAULT 'empty',
            updated_at TEXT
        )
    """, "create slot_bindings")

    _exec("""
        CREATE TABLE IF NOT EXISTS slot_medications (
            id              SERIAL       PRIMARY KEY,
            slot_id         INTEGER      NOT NULL,
            patient_id      VARCHAR(255),
            medication_id   VARCHAR(255) NOT NULL,
            medication_name TEXT,
            barcode         TEXT,
            target_count    INTEGER      DEFAULT 1,
            loaded_count    INTEGER      DEFAULT 0,
            updated_at      TEXT
        )
    """, "create slot_medications")

    _exec("""
        CREATE TABLE IF NOT EXISTS dispensing_logs (
            log_id           VARCHAR(255) PRIMARY KEY,
            patient_id       VARCHAR(255) NOT NULL,
            schedule_id      VARCHAR(255),
            status           VARCHAR(50)  NOT NULL,
            face_auth_score  FLOAT,
            dispensing_at    TEXT,
            taken_at         TEXT,
            device_timestamp TEXT,
            error_details    TEXT
        )
    """, "create dispensing_logs")

    _exec("""
        CREATE TABLE IF NOT EXISTS users (
            id              SERIAL       PRIMARY KEY,
            email           VARCHAR(255) UNIQUE NOT NULL,
            password_hash   TEXT         NOT NULL,
            role            VARCHAR(50)  NOT NULL DEFAULT 'patient',
            patient_id      VARCHAR(255),
            created_at      TEXT,
            cloud_synced_at TEXT
        )
    """, "create users")

    # ── Add columns that may be missing from older installs ──────────────────
    column_additions = [
        ("patients",              "deleted_at",       "TEXT"),
        ("patients",              "cloud_synced_at",  "TEXT"),
        ("patients",              "created_at",       "TEXT"),
        ("medications",           "cloud_synced_at",  "TEXT"),
        ("medications",           "created_at",       "TEXT"),
        ("medication_schedules",  "slot_id",          "INTEGER"),
        ("medication_schedules",  "patient_id",       "VARCHAR(255)"),
        ("medication_schedules",  "window_seconds",   "INTEGER DEFAULT 300"),
        ("medication_schedules",  "frequency_type",   "TEXT DEFAULT 'daily'"),
        ("medication_schedules",  "week_days",        "TEXT DEFAULT ''"),
        ("medication_schedules",  "group_id",         "VARCHAR(255)"),
        ("medication_schedules",  "dosage_quantity",  "INTEGER DEFAULT 1"),
        ("medication_schedules",  "start_date",       "TEXT"),
        ("medication_schedules",  "end_date",         "TEXT"),
    ]
    for table, column, col_type in column_additions:
        _exec(
            f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {column} {col_type}",
            f"add {table}.{column}",
        )

    # ── Drop NOT NULL on medication_schedules.medication_id ──────────────────
    # Old schema had this as NOT NULL FK, but slot-centric architecture
    # no longer sets medication_id on schedules. Without this fix every
    # schedule push fails with "null value violates not-null constraint".
    _exec(
        "ALTER TABLE medication_schedules ALTER COLUMN medication_id DROP NOT NULL",
        "drop not-null on medication_schedules.medication_id",
    )

    # ── Drop NOT NULL on medication_schedules.start_date (if present) ────────
    _exec(
        "ALTER TABLE medication_schedules ALTER COLUMN start_date DROP NOT NULL",
        "drop not-null on medication_schedules.start_date",
    )

    # ── Indexes ───────────────────────────────────────────────────────────────
    for idx_sql in [
        "CREATE INDEX IF NOT EXISTS idx_medications_patient     ON medications (patient_id)",
        "CREATE INDEX IF NOT EXISTS idx_schedules_patient       ON medication_schedules (patient_id)",
        "CREATE INDEX IF NOT EXISTS idx_schedules_slot          ON medication_schedules (slot_id)",
        "CREATE INDEX IF NOT EXISTS idx_schedules_group         ON medication_schedules (group_id)",
        "CREATE INDEX IF NOT EXISTS idx_slot_meds_slot          ON slot_medications (slot_id)",
        "CREATE INDEX IF NOT EXISTS idx_dispensing_logs_patient ON dispensing_logs (patient_id)",
    ]:
        _exec(idx_sql, "index")

    cur.close()


# ── Sync state ────────────────────────────────────────────────────────────────

def _save_state(data: dict) -> None:
    STATE_FILE.write_text(json.dumps(data, indent=2))


def _load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {}


# ── SyncService ───────────────────────────────────────────────────────────────

class SyncService:

    def __init__(self) -> None:
        self.env = _load_env()
        _ensure_sync_schema()

    # ── Config check ─────────────────────────────────────────────────────────

    def _config_error(self) -> Optional[str]:
        missing = [k for k in ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD")
                   if not self.env.get(k)]
        return f"Missing RDS config: {', '.join(missing)}" if missing else None

    def get_status(self) -> dict[str, Any]:
        cfg_err = self._config_error()
        try:
            conn = _local_db()
            pending = conn.execute(
                "SELECT COUNT(*) FROM sync_queue WHERE is_synced=0"
            ).fetchone()[0]
            conn.close()
        except Exception:
            pending = 0

        state = _load_state()
        return {
            "ok":               True,
            "configured":       cfg_err is None,
            "config_error":     cfg_err,
            "pending_logs":     pending,
            "last_sync_at":     state.get("last_sync_at"),
            "last_results":     state.get("last_results"),
        }

    # ── Push helpers ──────────────────────────────────────────────────────────

    def _push_patients(self, aws) -> dict:
        """Push Pi patients (new + deleted) to RDS."""
        conn = _local_db()
        rows = conn.execute(
            "SELECT * FROM patients WHERE cloud_synced_at IS NULL OR deleted_at IS NOT NULL"
        ).fetchall()
        conn.close()

        pushed = failed = 0
        now = datetime.now(timezone.utc).isoformat()
        cur = aws.cursor()

        for row in [dict(r) for r in rows]:
            try:
                if row.get("deleted_at"):
                    # Push deletion
                    cur.execute(
                        "UPDATE patients SET deleted_at=%s WHERE patient_id=%s",
                        (row["deleted_at"], row["patient_id"]),
                    )
                else:
                    # Push new patient
                    cur.execute(
                        """
                        INSERT INTO patients
                            (patient_id, first_name, last_name, date_of_birth)
                        VALUES (%s, %s, %s, %s)
                        ON CONFLICT (patient_id) DO NOTHING
                        """,
                        (row["patient_id"], row["first_name"],
                         row["last_name"], row.get("date_of_birth")),
                    )
                aws.commit()

                conn = _local_db()
                conn.execute(
                    "UPDATE patients SET cloud_synced_at=? WHERE patient_id=?",
                    (now, row["patient_id"]),
                )
                conn.commit()
                conn.close()
                pushed += 1
            except Exception as e:
                aws.rollback()
                _log.warning("push_patients %s: %s", row["patient_id"][:8], e)
                failed += 1

        return {"pushed": pushed, "failed": failed}

    def _push_medications(self, aws) -> dict:
        """Push Pi-created medications to RDS."""
        conn = _local_db()
        rows = conn.execute(
            "SELECT * FROM medications WHERE cloud_synced_at IS NULL"
        ).fetchall()
        conn.close()

        pushed = failed = 0
        now = datetime.now(timezone.utc).isoformat()
        cur = aws.cursor()

        for row in [dict(r) for r in rows]:
            try:
                cur.execute(
                    """
                    INSERT INTO medications
                        (medication_id, patient_id, medication_name, pill_barcode,
                         pill_color_shape, remaining_count, low_stock_threshold, expiry_date)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (medication_id) DO UPDATE SET
                        medication_name     = EXCLUDED.medication_name,
                        pill_barcode        = EXCLUDED.pill_barcode,
                        pill_color_shape    = EXCLUDED.pill_color_shape,
                        remaining_count     = EXCLUDED.remaining_count,
                        low_stock_threshold = EXCLUDED.low_stock_threshold,
                        expiry_date         = EXCLUDED.expiry_date
                    """,
                    (
                        row["medication_id"], row["patient_id"],
                        row["medication_name"], row.get("pill_barcode"),
                        row.get("pill_color_shape"), row.get("remaining_count", 0),
                        row.get("low_stock_threshold", 5), row.get("expiry_date"),
                    ),
                )
                aws.commit()

                conn = _local_db()
                conn.execute(
                    "UPDATE medications SET cloud_synced_at=? WHERE medication_id=?",
                    (now, row["medication_id"]),
                )
                conn.commit()
                conn.close()
                pushed += 1
            except Exception as e:
                aws.rollback()
                _log.warning("push_meds %s: %s", row["medication_id"][:8], e)
                failed += 1

        return {"pushed": pushed, "failed": failed}

    def _push_dispensing_logs(self, aws) -> dict:
        """Push unsynced dispensing logs from sync_queue to AWS RDS."""
        conn = _local_db()
        rows = conn.execute(
            "SELECT * FROM sync_queue WHERE is_synced=0 ORDER BY dispensing_at"
        ).fetchall()
        conn.close()

        pushed = failed = 0
        cur = aws.cursor()

        for row in [dict(r) for r in rows]:
            try:
                cur.execute(
                    """
                    INSERT INTO dispensing_logs
                        (log_id, patient_id, schedule_id, status,
                         face_auth_score, dispensing_at, taken_at,
                         device_timestamp, error_details)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (log_id) DO NOTHING
                    """,
                    (
                        row["log_id"], row["patient_id"],
                        row.get("schedule_id"), row["status"],
                        row.get("face_auth_score"), row.get("dispensing_at"),
                        row.get("taken_at"), row.get("device_timestamp"),
                        row.get("error_details"),
                    ),
                )
                aws.commit()

                conn = _local_db()
                conn.execute(
                    "UPDATE sync_queue SET is_synced=1 WHERE log_id=?",
                    (row["log_id"],),
                )
                conn.commit()
                conn.close()
                pushed += 1
            except Exception as e:
                aws.rollback()
                _log.warning("push_logs %s: %s", row["log_id"][:8], e)
                conn = _local_db()
                conn.execute(
                    "UPDATE sync_queue SET retry_count=retry_count+1 WHERE log_id=?",
                    (row["log_id"],),
                )
                conn.commit()
                conn.close()
                failed += 1

        return {"pushed": pushed, "failed": failed, "total": len(rows)}

    def _push_schedules(self, aws) -> dict:
        """
        Push locally-created/updated schedules to AWS RDS medication_schedules.
        Uses the new slot-centric schema: slot_id + patient_id are the key fields.
        medication_id / dosage_quantity are left NULL (legacy columns, kept for compat).
        """
        conn = _local_db()
        rows = conn.execute(
            "SELECT * FROM local_schedules WHERE synced_at IS NULL"
        ).fetchall()
        conn.close()

        pushed = failed = 0
        now = datetime.now(timezone.utc).isoformat()
        cur = aws.cursor()

        for row in [dict(r) for r in rows]:
            try:
                cur.execute(
                    """
                    INSERT INTO medication_schedules
                        (schedule_id, patient_id, slot_id, planned_time,
                         is_active, start_date, end_date,
                         frequency_type, week_days, window_seconds, group_id)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (schedule_id) DO UPDATE SET
                        patient_id      = EXCLUDED.patient_id,
                        slot_id         = EXCLUDED.slot_id,
                        planned_time    = EXCLUDED.planned_time,
                        is_active       = EXCLUDED.is_active,
                        start_date      = EXCLUDED.start_date,
                        end_date        = EXCLUDED.end_date,
                        frequency_type  = EXCLUDED.frequency_type,
                        week_days       = EXCLUDED.week_days,
                        window_seconds  = EXCLUDED.window_seconds,
                        group_id        = EXCLUDED.group_id
                    """,
                    (
                        row["schedule_id"],
                        row.get("patient_id"),
                        row.get("slot_id"),
                        row.get("planned_time"),
                        bool(row.get("is_active", 1)),
                        row.get("start_date"),
                        row.get("end_date"),
                        row.get("frequency_type", "daily"),
                        row.get("week_days", ""),
                        int(row.get("window_seconds") or 300),
                        row.get("group_id"),
                    ),
                )
                aws.commit()

                conn = _local_db()
                conn.execute(
                    "UPDATE local_schedules SET synced_at=? WHERE schedule_id=?",
                    (now, row["schedule_id"]),
                )
                conn.commit()
                conn.close()
                pushed += 1
            except Exception as e:
                aws.rollback()
                _log.warning("push_schedules %s: %s", row["schedule_id"][:8], e)
                failed += 1

        return {"pushed": pushed, "failed": failed}

    def _push_slot_medications(self, aws) -> dict:
        """
        Push slot_medications (the physical medication definitions per slot)
        to AWS. Replaces existing rows for each slot that has updates.
        """
        conn = _local_db()
        rows = conn.execute(
            "SELECT * FROM slot_medications ORDER BY slot_id"
        ).fetchall()
        conn.close()

        if not rows:
            return {"pushed": 0, "failed": 0}

        pushed = failed = 0
        cur = aws.cursor()

        # Group by slot_id and upsert
        seen_slots: set[int] = set()
        for row in [dict(r) for r in rows]:
            slot_id = row["slot_id"]
            try:
                # Delete existing rows for this slot on first encounter
                if slot_id not in seen_slots:
                    cur.execute(
                        "DELETE FROM slot_medications WHERE slot_id = %s",
                        (slot_id,),
                    )
                    seen_slots.add(slot_id)

                cur.execute(
                    """
                    INSERT INTO slot_medications
                        (slot_id, patient_id, medication_id, medication_name,
                         barcode, target_count, loaded_count, updated_at)
                    VALUES (%s,
                            (SELECT patient_id FROM medication_schedules
                             WHERE slot_id = %s LIMIT 1),
                            %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        slot_id, slot_id,
                        row.get("medication_id"),
                        row.get("medication_name"),
                        row.get("barcode"),
                        int(row.get("target_count") or 1),
                        int(row.get("loaded_count") or 0),
                        row.get("updated_at"),
                    ),
                )
                aws.commit()
                pushed += 1
            except Exception as e:
                aws.rollback()
                _log.warning("push_slot_medications slot %s: %s", slot_id, e)
                failed += 1

        return {"pushed": pushed, "failed": failed}

    # ── Pull helpers ──────────────────────────────────────────────────────────

    def _pull_patients(self, aws) -> dict:
        """Pull all non-deleted patients from AWS → local. Cloud wins on conflict."""
        cur = aws.cursor()
        cur.execute(
            "SELECT patient_id, first_name, last_name, date_of_birth FROM patients "
            "WHERE deleted_at IS NULL"
        )
        rows = cur.fetchall()
        now = datetime.now(timezone.utc).isoformat()

        conn = _local_db()
        upserted = 0
        for p in [dict(r) for r in rows]:
            conn.execute(
                """
                INSERT INTO patients
                    (patient_id, first_name, last_name, date_of_birth,
                     created_at, cloud_synced_at, deleted_at)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(patient_id) DO UPDATE SET
                    first_name      = excluded.first_name,
                    last_name       = excluded.last_name,
                    date_of_birth   = excluded.date_of_birth,
                    cloud_synced_at = excluded.cloud_synced_at,
                    deleted_at      = NULL
                """,
                (
                    str(p["patient_id"]), p["first_name"], p["last_name"],
                    str(p["date_of_birth"]) if p.get("date_of_birth") else None,
                    now, now,
                ),
            )
            upserted += 1
        conn.commit()
        conn.close()
        return {"pulled": upserted}

    def _pull_medications(self, aws) -> dict:
        """Pull medications for all local patients from AWS. Cloud wins."""
        conn = _local_db()
        patient_ids = [str(r[0]) for r in conn.execute(
            "SELECT patient_id FROM patients"
        ).fetchall()]
        conn.close()

        now  = datetime.now(timezone.utc).isoformat()
        cur  = aws.cursor()
        total = 0

        for pid in patient_ids:
            cur.execute(
                """
                SELECT medication_id, patient_id, medication_name,
                       pill_barcode, pill_color_shape,
                       remaining_count, low_stock_threshold, expiry_date
                FROM medications WHERE patient_id = %s
                """,
                (pid,),
            )
            meds = cur.fetchall()

            conn = _local_db()
            for m in [dict(r) for r in meds]:
                conn.execute(
                    """
                    INSERT INTO medications
                        (medication_id, patient_id, medication_name, pill_barcode,
                         pill_color_shape, remaining_count, low_stock_threshold,
                         expiry_date, created_at, cloud_synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(medication_id) DO UPDATE SET
                        medication_name     = excluded.medication_name,
                        pill_barcode        = excluded.pill_barcode,
                        remaining_count     = excluded.remaining_count,
                        low_stock_threshold = excluded.low_stock_threshold,
                        expiry_date         = excluded.expiry_date,
                        cloud_synced_at     = excluded.cloud_synced_at
                    """,
                    (
                        str(m["medication_id"]), pid,
                        m["medication_name"], m.get("pill_barcode"),
                        m.get("pill_color_shape"), m.get("remaining_count", 0),
                        m.get("low_stock_threshold", 5),
                        str(m["expiry_date"]) if m.get("expiry_date") else None,
                        now, now,
                    ),
                )
                total += 1
            conn.commit()
            conn.close()

        return {"pulled": total}

    def _pull_schedules(self, aws) -> dict:
        """Pull active schedules from AWS for all local patients."""
        conn = _local_db()
        patient_ids = [str(r[0]) for r in conn.execute(
            "SELECT patient_id FROM patients"
        ).fetchall()]
        conn.close()

        now   = datetime.now(timezone.utc).isoformat()
        cur   = aws.cursor()
        total = 0

        for pid in patient_ids:
            try:
                cur.execute(
                    """
                    SELECT ms.schedule_id, m.patient_id, ms.medication_id,
                           ms.planned_time, ms.dosage_quantity, ms.is_active,
                           ms.start_date, ms.end_date, m.slot_id
                    FROM medication_schedules ms
                    JOIN medications m ON ms.medication_id = m.medication_id
                    WHERE m.patient_id = %s AND ms.is_active = TRUE
                    """,
                    (pid,),
                )
                schedules = cur.fetchall()
            except Exception as e:
                _log.warning("pull_schedules %s: %s", pid[:8], e)
                continue

            conn = _local_db()
            for s in [dict(r) for r in schedules]:
                conn.execute(
                    """
                    INSERT INTO local_schedules
                        (schedule_id, patient_id, medication_id, planned_time,
                         dosage_quantity, slot_id, is_active, start_date, end_date, synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(schedule_id) DO UPDATE SET
                        planned_time    = excluded.planned_time,
                        dosage_quantity = excluded.dosage_quantity,
                        slot_id         = excluded.slot_id,
                        is_active       = excluded.is_active,
                        end_date        = excluded.end_date,
                        synced_at       = excluded.synced_at
                    """,
                    (
                        str(s["schedule_id"]), pid,
                        str(s["medication_id"]) if s.get("medication_id") else None,
                        str(s["planned_time"]) if s.get("planned_time") else None,
                        s.get("dosage_quantity", 1), s.get("slot_id"),
                        1 if s.get("is_active", True) else 0,
                        str(s["start_date"]) if s.get("start_date") else None,
                        str(s["end_date"])   if s.get("end_date")   else None,
                        now,
                    ),
                )
                total += 1
            conn.commit()
            conn.close()

        return {"pulled": total}

    def _push_users(self, aws) -> dict:
        """Push unsynced user accounts (caregivers + patients) to AWS users table."""
        conn = _local_db()
        rows = conn.execute(
            "SELECT * FROM users WHERE cloud_synced_at IS NULL"
        ).fetchall()
        conn.close()

        pushed = failed = 0
        now = datetime.now(timezone.utc).isoformat()
        cur = aws.cursor()

        for row in [dict(r) for r in rows]:
            try:
                cur.execute(
                    """
                    INSERT INTO users
                        (email, password_hash, role, patient_id, created_at)
                    VALUES (%s, %s, %s, %s, %s)
                    ON CONFLICT (email) DO UPDATE SET
                        password_hash   = EXCLUDED.password_hash,
                        role            = EXCLUDED.role,
                        patient_id      = EXCLUDED.patient_id,
                        cloud_synced_at = NOW()
                    """,
                    (
                        row["email"],
                        row["password_hash"],
                        row["role"],
                        row.get("patient_id"),
                        row["created_at"],
                    ),
                )
                aws.commit()

                # Mark as synced in local SQLite
                conn = _local_db()
                conn.execute(
                    "UPDATE users SET cloud_synced_at=? WHERE email=?",
                    (now, row["email"]),
                )
                conn.commit()
                conn.close()
                pushed += 1
            except Exception as e:
                aws.rollback()
                _log.warning("push_users %s: %s", row["email"], e)
                failed += 1

        return {"pushed": pushed, "failed": failed}

    # ── Full sync ─────────────────────────────────────────────────────────────

    def full_sync(self) -> dict[str, Any]:
        """Run complete bidirectional sync. Returns results dict."""
        err = self._config_error()
        if err:
            return {"ok": False, "error": err}

        try:
            aws = _rds_connect(self.env)
        except Exception as e:
            return {"ok": False, "error": f"Cannot connect to AWS RDS: {e}"}

        # Migrate AWS schema — add columns that may be missing
        _migrate_aws_schema(aws)

        results: dict[str, Any] = {}
        errors:  list[str]      = []
        now = datetime.now(timezone.utc).isoformat()

        steps = [
            # Pi is the source of truth — push-only to AWS.
            ("push_users",            lambda: self._push_users(aws)),
            ("push_patients",         lambda: self._push_patients(aws)),
            ("push_medications",      lambda: self._push_medications(aws)),
            ("push_dispensing_logs",  lambda: self._push_dispensing_logs(aws)),
            ("push_schedules",        lambda: self._push_schedules(aws)),
            ("push_slot_medications", lambda: self._push_slot_medications(aws)),
        ]

        for name, fn in steps:
            try:
                results[name] = fn()
            except Exception as e:
                _log.error("sync step %s: %s", name, e)
                errors.append(f"{name}: {e}")
                results[name] = {"error": str(e)}

        try:
            aws.close()
        except Exception:
            pass

        _save_state({"last_sync_at": now, "last_results": results, "errors": errors})
        return {"ok": not errors, "synced_at": now, "results": results, "errors": errors}
