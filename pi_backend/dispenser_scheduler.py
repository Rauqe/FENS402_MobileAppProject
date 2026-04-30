"""Background scheduler that monitors local_schedules and fires dispensing
events when a medication time is due.

Runs in a background thread, checks every 30 seconds.
Marks schedules as "triggered" per day to avoid duplicate fires.

New architecture (slot-centric):
  - Each schedule row = one slot + one planned_time
  - Medications come from slot_medications table (target/loaded counts)
  - Only fires for slots whose slot_bindings.status = 'loaded'
"""

from __future__ import annotations

import sqlite3
import logging
import threading
import time
from datetime import datetime, date, timedelta
from dataclasses import dataclass, field
from typing import Callable, Optional

log = logging.getLogger(__name__)

CHECK_INTERVAL_SEC = 30   # how often to check for due schedules
TIME_TOLERANCE_MIN = 4    # ±4 minutes tolerance for matching schedule time

from state_machine import LOCAL_DB


@dataclass
class DueSchedule:
    """A schedule that is now due for dispensing."""
    schedule_id: str
    patient_id: str
    patient_name: str           # first_name + last_name
    slot_id: int
    planned_time: str           # "HH:MM"
    window_seconds: int = 300   # caregiver-configurable auth window
    medications: list = field(default_factory=list)
    # Each medication dict: {medication_id, medication_name, barcode, target_count, loaded_count}


def _fetch_slot_medications(slot_id: int) -> list:
    """Fetch the medication list for a slot from slot_medications."""
    try:
        conn = sqlite3.connect(LOCAL_DB)
        conn.row_factory = sqlite3.Row
        rows = conn.execute("""
            SELECT medication_id, medication_name, barcode,
                   target_count, loaded_count
            FROM slot_medications
            WHERE slot_id = ?
            ORDER BY id
        """, (slot_id,)).fetchall()
        conn.close()
        return [dict(r) for r in rows]
    except Exception as e:
        log.debug("_fetch_slot_medications error for slot %d: %s", slot_id, e)
        return []


class ScheduleMonitor:
    """Monitors local_schedules and fires a callback when a dose is due.

    Only slots with status='loaded' in slot_bindings are eligible for
    dispensing — a slot must be physically loaded before the window fires.

    Usage:
        monitor = ScheduleMonitor(on_schedule_due=my_callback)
        monitor.start()
        ...
        monitor.stop()
    """

    def __init__(self, on_schedule_due: Callable[[DueSchedule], None]):
        self._callback = on_schedule_due
        self._stop_event = threading.Event()
        self._thread: Optional[threading.Thread] = None
        # Track triggered schedules: set of (schedule_id, date_str)
        self._triggered: set[tuple[str, str]] = set()

    def start(self):
        """Start the background monitoring thread."""
        if self._thread and self._thread.is_alive():
            log.warning("Scheduler already running")
            return
        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._run_loop, name="schedule-monitor", daemon=True
        )
        self._thread.start()
        log.info("Schedule monitor started (check every %ds)", CHECK_INTERVAL_SEC)

    def stop(self):
        """Stop the monitoring thread."""
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=10)
        log.info("Schedule monitor stopped")

    def get_next_schedule(self) -> Optional[DueSchedule]:
        """Get the next upcoming schedule for display purposes.
        Returns the soonest active, loaded slot after the current time.
        """
        now = datetime.now()
        today_str = now.strftime("%Y-%m-%d")
        current_time = now.strftime("%H:%M")

        try:
            conn = sqlite3.connect(LOCAL_DB)
            conn.row_factory = sqlite3.Row

            # Try today first (times after now)
            rows = conn.execute("""
                SELECT ls.schedule_id, ls.patient_id, ls.slot_id,
                       ls.planned_time, ls.start_date, ls.end_date,
                       COALESCE(ls.window_seconds, 300) AS window_seconds,
                       p.first_name, p.last_name
                FROM local_schedules ls
                LEFT JOIN patients p ON ls.patient_id = p.patient_id
                LEFT JOIN slot_bindings sb ON ls.slot_id = sb.slot_id
                WHERE ls.is_active = 1
                  AND (ls.start_date IS NULL OR ls.start_date <= ?)
                  AND (ls.end_date IS NULL OR ls.end_date >= ?)
                  AND ls.planned_time >= ?
                  AND sb.status = 'loaded'
                ORDER BY ls.planned_time ASC
                LIMIT 1
            """, (today_str, today_str, current_time)).fetchall()

            if not rows:
                # Fallback: any loaded slot (might be tomorrow)
                rows = conn.execute("""
                    SELECT ls.schedule_id, ls.patient_id, ls.slot_id,
                           ls.planned_time, ls.start_date, ls.end_date,
                           COALESCE(ls.window_seconds, 300) AS window_seconds,
                           p.first_name, p.last_name
                    FROM local_schedules ls
                    LEFT JOIN patients p ON ls.patient_id = p.patient_id
                    LEFT JOIN slot_bindings sb ON ls.slot_id = sb.slot_id
                    WHERE ls.is_active = 1
                      AND sb.status = 'loaded'
                    ORDER BY ls.planned_time ASC
                    LIMIT 1
                """).fetchall()

            conn.close()

            if rows:
                r = rows[0]
                meds = _fetch_slot_medications(r["slot_id"])
                return DueSchedule(
                    schedule_id=r["schedule_id"],
                    patient_id=r["patient_id"],
                    patient_name=f"{r['first_name'] or ''} {r['last_name'] or ''}".strip(),
                    slot_id=r["slot_id"],
                    planned_time=r["planned_time"] or "",
                    window_seconds=int(r["window_seconds"] or 300),
                    medications=meds,
                )
        except Exception as e:
            log.debug("get_next_schedule error: %s", e)
        return None

    # ── Internal loop ──────────────────────────────────────────────────
    def _run_loop(self):
        """Main monitoring loop."""
        self._cleanup_old_triggers()

        while not self._stop_event.is_set():
            try:
                now = datetime.now()
                log.info("Checking schedules at %s", now.strftime("%H:%M:%S"))
                self._check_schedules()
            except Exception as e:
                log.error("Schedule check error: %s", e)
            self._stop_event.wait(CHECK_INTERVAL_SEC)

    def _check_schedules(self):
        """Query local_schedules and fire callback for due, loaded slots."""
        now = datetime.now()
        today_str = now.strftime("%Y-%m-%d")
        current_minutes = now.hour * 60 + now.minute

        conn = sqlite3.connect(LOCAL_DB)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute("""
                SELECT ls.schedule_id, ls.patient_id, ls.slot_id,
                       ls.planned_time, ls.start_date, ls.end_date,
                       COALESCE(ls.frequency_type, 'daily')  AS frequency_type,
                       COALESCE(ls.week_days, '')             AS week_days,
                       COALESCE(ls.window_seconds, 300)       AS window_seconds,
                       p.first_name, p.last_name,
                       sb.status AS slot_status
                FROM local_schedules ls
                LEFT JOIN patients p ON ls.patient_id = p.patient_id
                LEFT JOIN slot_bindings sb ON ls.slot_id = sb.slot_id
                WHERE ls.is_active = 1
                  AND (ls.start_date IS NULL OR ls.start_date <= ?)
                  AND (ls.end_date IS NULL OR ls.end_date >= ?)
                  AND sb.status = 'loaded'
            """, (today_str, today_str)).fetchall()
        finally:
            conn.close()

        today = now.date()

        for row in rows:
            sid = row["schedule_id"]
            trigger_key = (sid, today_str)

            # Skip already triggered today
            if trigger_key in self._triggered:
                continue

            # ── Frequency check ──────────────────────────────────────────
            freq = row["frequency_type"] or "daily"
            if freq == "weekly":
                allowed_days: list[int] = []
                for d in (row["week_days"] or "").split(","):
                    d = d.strip()
                    if d.isdigit():
                        allowed_days.append(int(d))
                if today.weekday() not in allowed_days:
                    continue
            elif freq == "alternate":
                start_str = row["start_date"]
                if start_str:
                    try:
                        start_dt = date.fromisoformat(str(start_str))
                        delta = (today - start_dt).days
                        if delta < 0 or delta % 2 != 0:
                            continue
                    except (ValueError, TypeError):
                        pass

            # Parse planned time
            planned = row["planned_time"]
            if not planned:
                continue
            try:
                parts = planned.split(":")
                planned_minutes = int(parts[0]) * 60 + int(parts[1])
            except (ValueError, IndexError):
                continue

            # Check if within tolerance window
            diff = abs(current_minutes - planned_minutes)
            log.debug("Schedule %s slot=%d planned=%s diff=%d min (tolerance=%d)",
                      sid, row["slot_id"], planned, diff, TIME_TOLERANCE_MIN)

            if diff <= TIME_TOLERANCE_MIN:
                meds = _fetch_slot_medications(row["slot_id"])

                sched = DueSchedule(
                    schedule_id=sid,
                    patient_id=row["patient_id"],
                    patient_name=f"{row['first_name'] or ''} {row['last_name'] or ''}".strip(),
                    slot_id=row["slot_id"],
                    planned_time=planned,
                    window_seconds=int(row["window_seconds"] or 300),
                    medications=meds,
                )

                self._triggered.add(trigger_key)
                med_names = ", ".join(m.get("medication_name", "?") for m in meds) or "?"
                log.info(
                    "Schedule DUE: %s for %s — slot %d [%s] at %s",
                    sid, sched.patient_name, sched.slot_id, med_names, sched.planned_time,
                )

                try:
                    self._callback(sched)
                except Exception as e:
                    log.error("Callback error for schedule %s: %s", sid, e)

    def _cleanup_old_triggers(self):
        """Remove trigger entries from previous days."""
        today = date.today().isoformat()
        old = {k for k in self._triggered if k[1] != today}
        self._triggered -= old
        if old:
            log.debug("Cleaned %d old trigger entries", len(old))

    def get_todays_schedules(self) -> list[dict]:
        """Return today's active schedule groups for display on IDLE screen.
        Respects frequency_type (daily/weekly/alternate).
        Returns list of dicts: {patient_name, slot_id, planned_time, medications[],
                                 frequency_type, week_days, slot_status}
        """
        today     = date.today()
        today_str = today.isoformat()
        weekday   = today.weekday()   # 0=Mon … 6=Sun

        try:
            conn = sqlite3.connect(LOCAL_DB)
            conn.row_factory = sqlite3.Row
            rows = conn.execute("""
                SELECT ls.schedule_id, ls.patient_id, ls.slot_id,
                       ls.planned_time, ls.start_date,
                       COALESCE(ls.frequency_type, 'daily') AS frequency_type,
                       COALESCE(ls.week_days, '')            AS week_days,
                       p.first_name, p.last_name,
                       COALESCE(sb.status, 'empty') AS slot_status
                FROM local_schedules ls
                LEFT JOIN patients p ON ls.patient_id = p.patient_id
                LEFT JOIN slot_bindings sb ON ls.slot_id = sb.slot_id
                WHERE ls.is_active = 1
                  AND (ls.start_date IS NULL OR ls.start_date <= ?)
                  AND (ls.end_date IS NULL OR ls.end_date >= ?)
                ORDER BY ls.planned_time ASC
            """, (today_str, today_str)).fetchall()
            conn.close()
        except Exception as e:
            log.debug("get_todays_schedules: %s", e)
            return []

        schedules = []
        for row in rows:
            freq = row["frequency_type"]

            # ── Frequency filter ──────────────────────────────
            if freq == "weekly":
                allowed = [int(d) for d in (row["week_days"] or "").split(",")
                           if d.strip().isdigit()]
                if weekday not in allowed:
                    continue
            elif freq == "alternate":
                start_str = row["start_date"]
                if start_str:
                    try:
                        start_dt = date.fromisoformat(str(start_str))
                        delta = (today - start_dt).days
                        if delta < 0 or delta % 2 != 0:
                            continue
                    except (ValueError, TypeError):
                        pass

            meds = _fetch_slot_medications(row["slot_id"])
            schedules.append({
                "schedule_id":   row["schedule_id"],
                "patient_name":  f"{row['first_name'] or ''} {row['last_name'] or ''}".strip(),
                "slot_id":       row["slot_id"],
                "planned_time":  row["planned_time"] or "",
                "medications":   meds,
                "frequency_type": freq,
                "week_days":     row["week_days"] or "",
                "slot_status":   row["slot_status"],
            })

        return schedules

    # ── Manual trigger (for testing) ───────────────────────────────────
    def trigger_now(self, schedule_id: str) -> Optional[DueSchedule]:
        """Manually trigger a specific schedule (for testing/API use)."""
        conn = sqlite3.connect(LOCAL_DB)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("""
                SELECT ls.schedule_id, ls.patient_id, ls.slot_id,
                       ls.planned_time,
                       COALESCE(ls.window_seconds, 300) AS window_seconds,
                       p.first_name, p.last_name
                FROM local_schedules ls
                LEFT JOIN patients p ON ls.patient_id = p.patient_id
                WHERE ls.schedule_id = ?
            """, (schedule_id,)).fetchone()
        finally:
            conn.close()

        if not row:
            log.warning("Schedule %s not found", schedule_id)
            return None

        meds = _fetch_slot_medications(row["slot_id"])

        sched = DueSchedule(
            schedule_id=row["schedule_id"],
            patient_id=row["patient_id"],
            patient_name=f"{row['first_name'] or ''} {row['last_name'] or ''}".strip(),
            slot_id=row["slot_id"],
            planned_time=row["planned_time"] or "",
            window_seconds=int(row["window_seconds"] or 300),
            medications=meds,
        )

        log.info("Manual trigger: %s slot=%d for %s", schedule_id, sched.slot_id, sched.patient_name)
        self._callback(sched)
        return sched
