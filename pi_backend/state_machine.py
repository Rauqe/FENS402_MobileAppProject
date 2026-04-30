"""
SmartDrugDispenser — Dispenser State Machine

New slot model:
  - Each slot (0-13) represents ONE dose event for ONE patient.
  - slot_bindings: slot → patient + status (empty/loaded/dispensed)
  - slot_medications: slot → multiple medication definitions (one row per med type)
  - A slot is 'loaded' when all defined medications have loaded_count == target_count.
  - A slot is 'dispensed' after a successful dispense cycle.

IDLE -> ROTATING -> LOADING_MODE -> SLOT_READY ->
WAITING_FOR_PATIENT -> FACE_MATCHED -> DISPENSING -> IDLE
Any state -> ERROR (on failure), ERROR -> IDLE (via reset())

Thread-safe: all public methods are guarded by threading.Lock.
"""

from __future__ import annotations

import os
import time
import uuid
import sqlite3
import threading
from enum import Enum
from datetime import datetime, timezone
from dataclasses import dataclass, field, asdict
from typing import Optional, Callable, List, Dict, Any


_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_DB = os.path.join(_SCRIPT_DIR, "faces.db")


TOTAL_SLOTS = 14
WINDOW_SECONDS = 5 * 60          # 5-minute face-auth window (fallback)
FACE_SCORE_THRESHOLD = 0.6       # 1.0 - euclidean distance
AUTH_RETRY_COOLDOWN = 3           # seconds between face-auth attempts


def _log(msg: str):
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"[{ts}] [StateMachine] {msg}", flush=True)


class DispenserState(str, Enum):
    """Possible dispenser states. Inherits str for JSON serialization."""
    IDLE = "idle"
    ROTATING = "rotating"
    LOADING_MODE = "loading_mode"
    SLOT_READY = "slot_ready"
    WAITING_FOR_PATIENT = "waiting_for_patient"
    FACE_MATCHED = "face_matched"
    DISPENSING = "dispensing"
    ERROR = "error"


@dataclass
class DispenserContext:
    """Snapshot of the current dispenser state."""

    state: DispenserState = DispenserState.IDLE

    # ── Slot & patient ──
    current_patient_id: Optional[str] = None
    current_patient_name: Optional[str] = None
    selected_slot: Optional[int] = None

    # ── Barcode loading ──
    barcode_count: int = 0
    scanned_barcodes: List[str] = field(default_factory=list)

    # ── Motor / servo ──
    motor_busy: bool = False
    servo_open: bool = False

    # ── Face auth window ──
    window_start: Optional[float] = None
    window_deadline: Optional[float] = None
    auth_attempts: int = 0
    last_auth_score: Optional[float] = None

    # ── Camera ──
    camera_active: bool = False

    # ── Error ──
    last_error: Optional[str] = None
    last_error_time: Optional[str] = None

    # ── Timestamps ──
    state_changed_at: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        """JSON-safe dictionary for the Flask API."""
        d = {
            "state": self.state.value,
            "current_patient_id": self.current_patient_id,
            "current_patient_name": self.current_patient_name,
            "selected_slot": self.selected_slot,
            "barcode_count": self.barcode_count,
            "scanned_barcodes": self.scanned_barcodes[-10:],   # last 10
            "motor_busy": self.motor_busy,
            "servo_open": self.servo_open,
            "camera_active": self.camera_active,
            "last_error": self.last_error,
            "last_error_time": self.last_error_time,
            "state_changed_at": self.state_changed_at,
        }
        # Window info (only meaningful in WAITING_FOR_PATIENT)
        if self.window_deadline is not None:
            remaining = max(0, int(self.window_deadline - time.time()))
            d["window_remaining_sec"] = remaining
            d["auth_attempts"] = self.auth_attempts
            d["last_auth_score"] = self.last_auth_score
        else:
            d["window_remaining_sec"] = None
            d["auth_attempts"] = 0
            d["last_auth_score"] = None

        return d


def _ensure_tables():
    """Create tables required by the state machine if they don't exist."""
    conn = sqlite3.connect(LOCAL_DB)
    try:
        # ── Slot bindings: slot → patient + status ──────────────────────
        # status: 'empty' | 'loaded' | 'dispensed'
        conn.execute("""
            CREATE TABLE IF NOT EXISTS slot_bindings (
                slot_id     INTEGER PRIMARY KEY,
                patient_id  TEXT,
                status      TEXT DEFAULT 'empty',
                updated_at  TEXT
            )
        """)

        # ── Slot medications: what medications go in each slot ──────────
        # One row per medication type per slot.
        # target_count = how many pills expected (set when caregiver defines the slot)
        # loaded_count = how many pills physically scanned/confirmed
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
            )
        """)

        # ── Face auth attempt log ────────────────────────────────────────
        conn.execute("""
            CREATE TABLE IF NOT EXISTS face_auth_log (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                patient_id      TEXT,
                matched_patient TEXT,
                score           REAL,
                liveness_ok     INTEGER,
                slot_dispensed  INTEGER,
                status          TEXT NOT NULL,
                created_at      TEXT NOT NULL
            )
        """)

        conn.commit()
    finally:
        conn.close()


# ── DB helpers ──────────────────────────────────────────────────────────────

def _db_bind_slot(slot_id: int, patient_id: str):
    """Assign (or reassign) a slot to a patient. Clears existing medication defs."""
    conn = sqlite3.connect(LOCAL_DB)
    try:
        conn.execute("""
            INSERT INTO slot_bindings (slot_id, patient_id, status, updated_at)
            VALUES (?, ?, 'empty', ?)
            ON CONFLICT(slot_id) DO UPDATE SET
                patient_id = excluded.patient_id,
                status     = 'empty',
                updated_at = excluded.updated_at
        """, (slot_id, patient_id, datetime.now(timezone.utc).isoformat()))
        # Clear old medication definitions for this slot
        conn.execute("DELETE FROM slot_medications WHERE slot_id = ?", (slot_id,))
        conn.commit()
    finally:
        conn.close()


def _db_define_slot_medications(slot_id: int,
                                 medications: list[dict]) -> None:
    """
    Set medication definitions for a slot.
    Each dict: {medication_id, medication_name, barcode, target_count}
    Replaces any existing definitions for this slot.
    """
    conn = sqlite3.connect(LOCAL_DB)
    try:
        conn.execute("DELETE FROM slot_medications WHERE slot_id = ?", (slot_id,))
        now = datetime.now(timezone.utc).isoformat()
        for med in medications:
            conn.execute("""
                INSERT INTO slot_medications
                    (slot_id, medication_id, medication_name, barcode, target_count, loaded_count, updated_at)
                VALUES (?, ?, ?, ?, ?, 0, ?)
            """, (
                slot_id,
                med.get("medication_id", ""),
                med.get("medication_name", ""),
                med.get("barcode"),
                max(1, int(med.get("target_count", 1))),
                now,
            ))
        conn.commit()
    finally:
        conn.close()


def _db_scan_barcode(slot_id: int, barcode: str) -> dict:
    """
    Match a scanned barcode against defined medications for this slot.
    Returns: {ok, loaded_count, total_loaded, total_target, medication_name, message}
    """
    conn = sqlite3.connect(LOCAL_DB)
    conn.row_factory = sqlite3.Row
    try:
        # Find matching medication definition
        row = conn.execute("""
            SELECT id, medication_id, medication_name, target_count, loaded_count
            FROM slot_medications
            WHERE slot_id = ? AND barcode = ?
        """, (slot_id, barcode)).fetchone()

        if not row:
            # Check if slot even has medication defs
            any_defs = conn.execute(
                "SELECT COUNT(*) FROM slot_medications WHERE slot_id = ?",
                (slot_id,)
            ).fetchone()[0]
            if any_defs == 0:
                # No defs yet — accept any barcode (legacy / free-load mode)
                conn.execute("""
                    INSERT INTO slot_medications
                        (slot_id, medication_id, barcode, target_count, loaded_count, updated_at)
                    VALUES (?, 'unknown', ?, 1, 1, ?)
                """, (slot_id, barcode, datetime.now(timezone.utc).isoformat()))
                conn.commit()
                return {
                    "ok": True,
                    "loaded_count": 1,
                    "total_loaded": 1,
                    "total_target": 1,
                    "medication_name": "Unknown",
                    "message": "Pill scanned (free-load mode)",
                }
            return {
                "ok": False,
                "loaded_count": 0,
                "total_loaded": 0,
                "total_target": 0,
                "medication_name": None,
                "message": f"Barcode '{barcode}' does not match any expected medication for this slot",
            }

        med_id = row["id"]
        new_loaded = min(row["loaded_count"] + 1, row["target_count"])
        now = datetime.now(timezone.utc).isoformat()

        conn.execute("""
            UPDATE slot_medications SET loaded_count = ?, updated_at = ?
            WHERE id = ?
        """, (new_loaded, now, med_id))
        conn.execute("""
            UPDATE slot_bindings SET updated_at = ? WHERE slot_id = ?
        """, (now, slot_id))
        conn.commit()

        # Calculate totals
        totals = conn.execute("""
            SELECT SUM(loaded_count) AS total_loaded, SUM(target_count) AS total_target
            FROM slot_medications WHERE slot_id = ?
        """, (slot_id,)).fetchone()

        return {
            "ok": True,
            "medication_id": row["medication_id"],
            "loaded_count": new_loaded,
            "total_loaded": totals["total_loaded"] or 0,
            "total_target": totals["total_target"] or 0,
            "medication_name": row["medication_name"],
            "message": f"{row['medication_name']} — pill #{new_loaded} of {row['target_count']}",
        }
    finally:
        conn.close()


def _db_commit_slot(slot_id: int) -> dict:
    """
    Mark slot as 'loaded'. Returns warning if not all pills scanned.
    """
    conn = sqlite3.connect(LOCAL_DB)
    conn.row_factory = sqlite3.Row
    try:
        totals = conn.execute("""
            SELECT SUM(loaded_count) AS total_loaded, SUM(target_count) AS total_target
            FROM slot_medications WHERE slot_id = ?
        """, (slot_id,)).fetchone()

        total_loaded = totals["total_loaded"] or 0
        total_target = totals["total_target"] or 0
        now = datetime.now(timezone.utc).isoformat()

        conn.execute("""
            UPDATE slot_bindings SET status = 'loaded', updated_at = ?
            WHERE slot_id = ?
        """, (now, slot_id))
        conn.commit()

        return {
            "ok": True,
            "total_loaded": total_loaded,
            "total_target": total_target,
            "complete": total_loaded >= total_target,
        }
    finally:
        conn.close()


def _db_set_slot_dispensed(slot_id: int):
    """Mark slot as dispensed and reset loaded_counts."""
    conn = sqlite3.connect(LOCAL_DB)
    try:
        now = datetime.now(timezone.utc).isoformat()
        conn.execute("""
            UPDATE slot_bindings SET status = 'dispensed', updated_at = ?
            WHERE slot_id = ?
        """, (now, slot_id))
        conn.execute("""
            UPDATE slot_medications SET loaded_count = 0, updated_at = ?
            WHERE slot_id = ?
        """, (now, slot_id))
        conn.commit()
    finally:
        conn.close()


def _db_get_slot_for_patient(patient_id: str) -> Optional[int]:
    """Find a loaded slot for a patient."""
    conn = sqlite3.connect(LOCAL_DB)
    try:
        row = conn.execute(
            "SELECT slot_id FROM slot_bindings WHERE patient_id = ? AND status = 'loaded'",
            (patient_id,),
        ).fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def _db_get_any_loaded_slot() -> Optional[tuple]:
    """Return (patient_id, slot_id) for the first loaded slot found."""
    conn = sqlite3.connect(LOCAL_DB)
    try:
        row = conn.execute(
            "SELECT patient_id, slot_id FROM slot_bindings WHERE status = 'loaded' LIMIT 1",
        ).fetchone()
        return (row[0], row[1]) if row else None
    finally:
        conn.close()


def _db_log_face_auth(patient_id: Optional[str], matched: Optional[str],
                       score: Optional[float], liveness: bool,
                       slot: Optional[int], status: str):
    """Log a face authentication attempt."""
    conn = sqlite3.connect(LOCAL_DB)
    try:
        conn.execute("""
            INSERT INTO face_auth_log
                (patient_id, matched_patient, score, liveness_ok,
                 slot_dispensed, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, (
            patient_id, matched, score, int(liveness),
            slot, status, datetime.now(timezone.utc).isoformat(),
        ))
        conn.commit()
    finally:
        conn.close()


class DispenserStateMachine:
    """Central state machine managing the full dispenser workflow. Thread-safe."""

    def __init__(
        self,
        motor_controller=None,
        on_state_change: Optional[Callable] = None,
        on_notify: Optional[Callable] = None,
    ):
        _ensure_tables()

        self._ctx = DispenserContext()
        self._lock = threading.Lock()
        self._motor = motor_controller
        self._on_state_change = on_state_change
        self._on_notify = on_notify

        # Background thread refs
        self._auth_thread: Optional[threading.Thread] = None
        self._auth_cancel = threading.Event()

        _log("Initialized (IDLE)")

    # ── Properties ──────────────────────────────────────────────────────────

    @property
    def state(self) -> DispenserState:
        return self._ctx.state

    @property
    def context(self) -> DispenserContext:
        return self._ctx

    @property
    def snapshot(self) -> DispenserContext:
        return self._ctx

    def get_state_dict(self) -> Dict[str, Any]:
        with self._lock:
            return self._ctx.to_dict()

    # ── State transition helper ─────────────────────────────────────────────

    def _set_state(self, new_state: DispenserState, reason: str = ""):
        old = self._ctx.state
        self._ctx.state = new_state
        self._ctx.state_changed_at = datetime.now(timezone.utc).isoformat()
        arrow = f"{old.value} → {new_state.value}"
        _log(f"STATE: {arrow}" + (f"  ({reason})" if reason else ""))
        if self._on_state_change:
            try:
                self._on_state_change(old, new_state, self._ctx.to_dict())
            except Exception as e:
                _log(f"on_state_change callback error: {e}")

    # ── Slot Binding & Rotation ─────────────────────────────────────────────

    def bind_slot(self, patient_id: str, slot_id: int,
                  patient_name: str = "") -> Dict[str, Any]:
        """Bind a patient to a slot and start wheel rotation."""
        with self._lock:
            if self._ctx.state not in (
                DispenserState.IDLE,
                DispenserState.SLOT_READY,
                DispenserState.ERROR,
            ):
                return {
                    "ok": False,
                    "message": f"Cannot bind slot in state '{self._ctx.state.value}'. Reset first.",
                    "state": self._ctx.state.value,
                }

            if slot_id < 0 or slot_id >= TOTAL_SLOTS:
                return {
                    "ok": False,
                    "message": f"Invalid slot {slot_id} (valid: 0-{TOTAL_SLOTS - 1})",
                    "state": self._ctx.state.value,
                }

            self._ctx.current_patient_id = patient_id
            self._ctx.current_patient_name = patient_name
            self._ctx.selected_slot = slot_id
            self._ctx.barcode_count = 0
            self._ctx.scanned_barcodes = []
            self._ctx.last_error = None

            try:
                _db_bind_slot(slot_id, patient_id)
            except Exception as e:
                self._set_state(DispenserState.ERROR, f"DB error: {e}")
                self._ctx.last_error = str(e)
                return {
                    "ok": False,
                    "message": f"Database error: {e}",
                    "state": self._ctx.state.value,
                }

            self._set_state(DispenserState.ROTATING, f"slot={slot_id}")
            self._ctx.motor_busy = True

        def _rotate():
            success = True
            if self._motor:
                try:
                    success = self._motor.rotate_to_slot(slot_id)
                except Exception as e:
                    _log(f"Motor error: {e}")
                    success = False

            with self._lock:
                self._ctx.motor_busy = False
                if success:
                    self._set_state(
                        DispenserState.LOADING_MODE,
                        f"slot {slot_id} ready for loading",
                    )
                else:
                    self._set_state(DispenserState.ERROR, "Motor rotation failed")
                    self._ctx.last_error = "Motor rotation failed"
                    self._ctx.last_error_time = datetime.now(timezone.utc).isoformat()

        thread = threading.Thread(target=_rotate, daemon=True)
        thread.start()

        return {
            "ok": True,
            "message": f"Rotating to slot {slot_id} for {patient_name or patient_id[:8]}",
            "state": DispenserState.ROTATING.value,
        }

    # ── Barcode Scanning ────────────────────────────────────────────────────

    def increment_barcode(self, barcode_data: str = "") -> Dict[str, Any]:
        """Record a barcode scan, matched against defined medications for this slot."""
        with self._lock:
            if self._ctx.state != DispenserState.LOADING_MODE:
                return {
                    "ok": False,
                    "count": self._ctx.barcode_count,
                    "message": f"Not in loading mode (current: {self._ctx.state.value})",
                }

            if self._ctx.selected_slot is None or self._ctx.current_patient_id is None:
                return {
                    "ok": False,
                    "count": self._ctx.barcode_count,
                    "message": "No slot or patient selected",
                }

            try:
                result = _db_scan_barcode(self._ctx.selected_slot, barcode_data)
            except Exception as e:
                _log(f"DB scan error: {e}")
                return {
                    "ok": False,
                    "count": self._ctx.barcode_count,
                    "message": f"Database error: {e}",
                }

            if not result["ok"]:
                return {
                    "ok": False,
                    "count": self._ctx.barcode_count,
                    "message": result["message"],
                }

            self._ctx.barcode_count = result["total_loaded"]
            if barcode_data:
                self._ctx.scanned_barcodes.append(barcode_data)

            _log(f"BARCODE: slot={self._ctx.selected_slot} "
                 f"loaded={result['total_loaded']}/{result['total_target']} "
                 f"med='{result['medication_name']}'")

            return {
                "ok": True,
                "count": result["total_loaded"],
                "total_target": result["total_target"],
                "barcode": barcode_data,
                "medication_id": result.get("medication_id"),
                "loaded_count": result.get("loaded_count", 0),
                "medication_name": result["medication_name"],
                "message": result["message"],
                "all_loaded": result["total_loaded"] >= result["total_target"],
            }

    # ── Commit Slot ─────────────────────────────────────────────────────────

    def commit_slot(self) -> Dict[str, Any]:
        """Finalize slot loading — marks slot as 'loaded'."""
        with self._lock:
            if self._ctx.state != DispenserState.LOADING_MODE:
                return {
                    "ok": False,
                    "message": f"Not in loading mode (current: {self._ctx.state.value})",
                }

            if self._ctx.barcode_count == 0:
                return {
                    "ok": False,
                    "message": "No pills scanned yet. Scan at least one barcode.",
                }

            slot_id = self._ctx.selected_slot
            count = self._ctx.barcode_count

            try:
                result = _db_commit_slot(slot_id)
            except Exception as e:
                return {"ok": False, "message": f"Database error: {e}"}

            if self._motor:
                self._motor.open_gate()
                self._ctx.servo_open = True

            self._set_state(
                DispenserState.SLOT_READY,
                f"slot {slot_id} loaded ({count} pills)",
            )

            msg = f"Slot {slot_id} loaded with {count} pills"
            if not result.get("complete"):
                msg += f" (partial: {result['total_loaded']}/{result['total_target']} expected)"

            return {
                "ok": True,
                "pill_count": count,
                "total_loaded": result["total_loaded"],
                "total_target": result["total_target"],
                "slot": slot_id,
                "patient_id": self._ctx.current_patient_id,
                "message": msg,
            }

    # ── Trigger Dispense Window ─────────────────────────────────────────────

    def trigger_dispense(
        self,
        patient_id: Optional[str] = None,
        schedule_id: Optional[str] = None,
        window_seconds: Optional[int] = None,
    ) -> Dict[str, Any]:
        """Open camera and start the face-auth window for dispensing."""
        with self._lock:
            if self._ctx.state in (
                DispenserState.WAITING_FOR_PATIENT,
                DispenserState.FACE_MATCHED,
                DispenserState.DISPENSING,
            ):
                return {
                    "ok": False,
                    "message": f"Already in {self._ctx.state.value} state",
                }

            pid = patient_id or self._ctx.current_patient_id

            slot = self._ctx.selected_slot
            if slot is None and pid:
                slot = _db_get_slot_for_patient(pid)

            if not pid or slot is None:
                any_loaded = _db_get_any_loaded_slot()
                if any_loaded:
                    pid, slot = any_loaded
                else:
                    return {
                        "ok": False,
                        "message": "No loaded slot found. Load pills first.",
                    }

            duration = window_seconds or WINDOW_SECONDS
            now = time.time()

            self._ctx.current_patient_id = pid
            self._ctx.selected_slot = slot
            self._ctx.window_start = now
            self._ctx.window_deadline = now + duration
            self._ctx.auth_attempts = 0
            self._ctx.last_auth_score = None
            self._ctx.camera_active = True

            self._auth_cancel.clear()

            self._set_state(
                DispenserState.WAITING_FOR_PATIENT,
                f"patient={pid[:8]}... slot={slot} window={duration}s",
            )

        def _timeout_watcher():
            self._auth_cancel.wait(timeout=duration)
            with self._lock:
                if self._ctx.state == DispenserState.WAITING_FOR_PATIENT:
                    _log("TIMEOUT: window expired — MISSED DOSE")
                    self._ctx.camera_active = False
                    _db_log_face_auth(pid, None, None, False, slot, "timeout_missed")
                    self._set_state(DispenserState.IDLE, "window expired")
                    if self._on_notify:
                        self._on_notify([0xA2])

        self._auth_thread = threading.Thread(target=_timeout_watcher, daemon=True)
        self._auth_thread.start()

        def _face_auth_worker():
            try:
                from face_auth_headless import authenticate_user
            except ImportError:
                _log("face_auth_headless not available — face auth disabled")
                return

            while not self._auth_cancel.is_set():
                with self._lock:
                    if self._ctx.state != DispenserState.WAITING_FOR_PATIENT:
                        break

                result = authenticate_user()

                if self._auth_cancel.is_set():
                    break

                status = result.get("status")

                if status == "success":
                    matched_pid = result["patient_id"]
                    score = result["score"]
                    name = result.get("name", "")

                    match_result = self.on_face_matched(
                        matched_patient_id=matched_pid,
                        score=score,
                        name=name,
                        liveness_ok=True,
                    )
                    if match_result.get("ok"):
                        self.dispense()
                    break

                elif status == "failed":
                    reason = result.get("reason", "unknown")
                    if reason == "camera_unavailable":
                        break
                    self._auth_cancel.wait(timeout=AUTH_RETRY_COOLDOWN)

        face_thread = threading.Thread(target=_face_auth_worker, daemon=True)
        face_thread.start()

        return {
            "ok": True,
            "window_seconds": duration,
            "patient_id": pid,
            "slot": slot,
            "message": f"Camera active. Waiting for patient face ({duration}s window)",
        }

    # ── Face Authentication Result ──────────────────────────────────────────

    def on_face_matched(
        self,
        matched_patient_id: str,
        score: float,
        name: str = "",
        liveness_ok: bool = True,
    ) -> Dict[str, Any]:
        with self._lock:
            if self._ctx.state != DispenserState.WAITING_FOR_PATIENT:
                return {
                    "ok": False,
                    "message": f"Not waiting for patient (current: {self._ctx.state.value})",
                }

            self._ctx.auth_attempts += 1
            self._ctx.last_auth_score = score

            expected_pid = self._ctx.current_patient_id
            slot = self._ctx.selected_slot

            if not liveness_ok:
                _db_log_face_auth(expected_pid, matched_patient_id, score, False, slot, "liveness_failed")
                return {"ok": False, "message": "Liveness check failed.", "attempts": self._ctx.auth_attempts}

            if score < FACE_SCORE_THRESHOLD:
                _db_log_face_auth(expected_pid, matched_patient_id, score, True, slot, "low_score")
                return {"ok": False, "message": f"Score too low: {score:.2f}", "attempts": self._ctx.auth_attempts}

            if matched_patient_id != expected_pid:
                _db_log_face_auth(expected_pid, matched_patient_id, score, True, slot, "wrong_patient")
                return {"ok": False, "message": "Face does not match expected patient", "attempts": self._ctx.auth_attempts}

            _db_log_face_auth(expected_pid, matched_patient_id, score, True, slot, "success")
            self._ctx.camera_active = False
            self._auth_cancel.set()

            self._set_state(
                DispenserState.FACE_MATCHED,
                f"{name or matched_patient_id[:8]}... score={score:.2f}",
            )

            return {
                "ok": True,
                "action": "dispense",
                "patient_id": matched_patient_id,
                "score": score,
                "slot": slot,
                "message": f"Access granted for {name or matched_patient_id[:8]}",
            }

    # ── Dispense ────────────────────────────────────────────────────────────

    def dispense(self) -> Dict[str, Any]:
        with self._lock:
            if self._ctx.state != DispenserState.FACE_MATCHED:
                return {"ok": False, "message": f"Cannot dispense in state '{self._ctx.state.value}'"}

            slot = self._ctx.selected_slot
            patient_id = self._ctx.current_patient_id

            self._set_state(DispenserState.DISPENSING, f"slot={slot}")
            self._ctx.motor_busy = True

        def _dispense_worker():
            success = True
            try:
                if self._motor:
                    self._motor.rotate_to_slot(slot)
                    self._motor.open_gate()
                    with self._lock:
                        self._ctx.servo_open = True
                    time.sleep(5)
                    self._motor.close_gate()
                    with self._lock:
                        self._ctx.servo_open = False
                else:
                    _log("[DRY-RUN] Motor not available — simulating dispense")
                    time.sleep(1)
            except Exception as e:
                _log(f"Dispense motor error: {e}")
                success = False

            with self._lock:
                self._ctx.motor_busy = False
                if success:
                    _log(f"DISPENSED: slot={slot} patient={patient_id[:8]}...")
                    if self._on_notify:
                        self._on_notify([0xA1])
                    self._set_state(DispenserState.IDLE, "dispense complete")
                    self._reset_context()
                else:
                    self._set_state(DispenserState.ERROR, "motor error during dispense")
                    self._ctx.last_error = "Motor error during dispense"
                    self._ctx.last_error_time = datetime.now(timezone.utc).isoformat()
                    if self._on_notify:
                        self._on_notify([0xA3, 0x02])

        thread = threading.Thread(target=_dispense_worker, daemon=True)
        thread.start()

        return {"ok": True, "slot": slot, "patient_id": patient_id, "message": f"Dispensing from slot {slot}"}

    # ── Camera Override ─────────────────────────────────────────────────────

    def open_camera_manual(self, patient_id: Optional[str] = None,
                            duration: int = WINDOW_SECONDS) -> Dict[str, Any]:
        with self._lock:
            if self._ctx.state in (DispenserState.WAITING_FOR_PATIENT, DispenserState.DISPENSING):
                return {"ok": False, "message": f"Already active ({self._ctx.state.value})"}
        return self.trigger_dispense(patient_id=patient_id, window_seconds=duration)

    # ── Reset ────────────────────────────────────────────────────────────────

    def reset(self) -> Dict[str, Any]:
        with self._lock:
            self._auth_cancel.set()
            if self._auth_thread and self._auth_thread.is_alive():
                self._auth_thread.join(timeout=1)
                self._auth_thread = None

            if self._motor and self._ctx.servo_open:
                try:
                    self._motor.close_gate()
                except Exception:
                    pass

            old_state = self._ctx.state
            self._reset_context()
            self._set_state(DispenserState.IDLE, f"reset from {old_state.value}")

            return {"ok": True, "message": f"Reset from {old_state.value} to IDLE", "state": DispenserState.IDLE.value}

    def _reset_context(self):
        self._ctx.current_patient_id = None
        self._ctx.current_patient_name = None
        self._ctx.selected_slot = None
        self._ctx.barcode_count = 0
        self._ctx.scanned_barcodes = []
        self._ctx.motor_busy = False
        self._ctx.servo_open = False
        self._ctx.window_start = None
        self._ctx.window_deadline = None
        self._ctx.auth_attempts = 0
        self._ctx.last_auth_score = None
        self._ctx.camera_active = False
        self._ctx.last_error = None
        self._ctx.last_error_time = None

    # ── Slot Queries ─────────────────────────────────────────────────────────

    @staticmethod
    def get_all_slots() -> List[Dict[str, Any]]:
        """Return all slot bindings with their medication definitions."""
        conn = sqlite3.connect(LOCAL_DB)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute("""
                SELECT sb.slot_id, sb.patient_id, sb.status, sb.updated_at,
                       p.first_name, p.last_name
                FROM slot_bindings sb
                LEFT JOIN patients p ON sb.patient_id = p.patient_id
                ORDER BY sb.slot_id
            """).fetchall()

            result = []
            for r in rows:
                meds = conn.execute("""
                    SELECT medication_id, medication_name, barcode,
                           target_count, loaded_count
                    FROM slot_medications
                    WHERE slot_id = ?
                    ORDER BY id
                """, (r["slot_id"],)).fetchall()

                result.append({
                    "slot_id": r["slot_id"],
                    "patient_id": r["patient_id"],
                    "patient_name": f"{r['first_name'] or ''} {r['last_name'] or ''}".strip(),
                    "status": r["status"] or "empty",
                    "updated_at": r["updated_at"],
                    "medications": [
                        {
                            "medication_id": m["medication_id"],
                            "medication_name": m["medication_name"],
                            "barcode": m["barcode"],
                            "target_count": m["target_count"],
                            "loaded_count": m["loaded_count"],
                        }
                        for m in meds
                    ],
                    "total_pills": sum(m["target_count"] for m in meds),
                    "loaded_pills": sum(m["loaded_count"] for m in meds),
                })
            return result
        finally:
            conn.close()

    @staticmethod
    def get_slot_medications(slot_id: int) -> List[Dict[str, Any]]:
        """Return medication definitions for a given slot."""
        conn = sqlite3.connect(LOCAL_DB)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute("""
                SELECT id, medication_id, medication_name, barcode,
                       target_count, loaded_count, updated_at
                FROM slot_medications
                WHERE slot_id = ?
                ORDER BY id
            """, (slot_id,)).fetchall()
            return [dict(r) for r in rows]
        finally:
            conn.close()

    @staticmethod
    def get_face_auth_logs(limit: int = 20) -> List[Dict[str, Any]]:
        conn = sqlite3.connect(LOCAL_DB)
        try:
            rows = conn.execute("""
                SELECT id, patient_id, matched_patient, score,
                       liveness_ok, slot_dispensed, status, created_at
                FROM face_auth_log
                ORDER BY id DESC
                LIMIT ?
            """, (limit,)).fetchall()
            return [
                {
                    "id": r[0],
                    "patient_id": r[1],
                    "matched_patient": r[2],
                    "score": r[3],
                    "liveness_ok": bool(r[4]),
                    "slot_dispensed": r[5],
                    "status": r[6],
                    "created_at": r[7],
                }
                for r in rows
            ]
        finally:
            conn.close()
