#!/usr/bin/env python3
"""MediDispense Kiosk Application.

Main entry point for the 5-inch Raspberry Pi display.
Combines: display UI + schedule monitor + face authentication + servo control.

Flow:
  IDLE ──(schedule due)──▸ WAITING ──▸ AUTHENTICATING ──(face match)──▸ SUCCESS
    ▲                                       │                              │
    │                                  (timeout)                     DISPENSING
    │                                       ▼                              │
    └──────────────── IDLE ◂── TIMEOUT      └────── IDLE ◂─────────────────┘

Usage:
  python3 kiosk_app.py                  # fullscreen on Pi display
  python3 kiosk_app.py --windowed       # windowed (for development)
  SERVO_DRY_RUN=1 python3 kiosk_app.py  # without servo hardware
"""

from __future__ import annotations

import os
import sys
import time
import signal
import logging
import sqlite3
import argparse
import threading
import queue
import numpy as np
from datetime import datetime
from typing import Optional

# ── Logging setup ──────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("kiosk")

# ── Local imports ──────────────────────────────────────────────────────
from state_machine import LOCAL_DB, _db_set_slot_dispensed
from pi_camera import PiCamera
from servo_control import ServoController
from display_ui import DispenserDisplay, DisplayState
from dispenser_scheduler import ScheduleMonitor, DueSchedule

# ── Constants ──────────────────────────────────────────────────────────
WINDOW_SECONDS = 300          # fallback auth window (overridden per-schedule)
AUTH_CHECK_INTERVAL = 0.5     # seconds between face auth checks
FACE_MATCH_THRESHOLD = 0.45   # distance threshold (lower = stricter)
SUCCESS_DISPLAY_SEC = 3       # show success screen for N seconds
TIMEOUT_DISPLAY_SEC = 5       # show timeout screen for N seconds
IDLE_SCHEDULE_REFRESH = 15    # refresh next-schedule info every N seconds


class KioskApp:
    """Main kiosk application controller."""

    def __init__(self, fullscreen: bool = True):
        self._display = DispenserDisplay(fullscreen=fullscreen)
        self._servo = ServoController()
        self._camera = PiCamera()
        self._scheduler: Optional[ScheduleMonitor] = None

        # Auth thread communication
        self._auth_queue: queue.Queue = queue.Queue(maxsize=2)
        self._auth_result: queue.Queue = queue.Queue(maxsize=1)
        self._auth_cancel = threading.Event()
        self._auth_thread: Optional[threading.Thread] = None

        # Current dispensing state
        self._current_schedule: Optional[DueSchedule] = None
        self._window_start: float = 0
        self._window_deadline: float = 0

        # Idle schedule display refresh
        self._last_schedule_refresh: float = 0

        # Graceful shutdown
        self._shutdown = False
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)

        # Load face data for recognition
        self._face_users: list[dict] = []
        self._load_face_users()

    def _signal_handler(self, signum, frame):
        log.info("Shutdown signal received (%s)", signum)
        self._shutdown = True

    # ── Face data loading ──────────────────────────────────────────────
    def _load_face_users(self):
        """Load registered face encodings from SQLite."""
        self._face_users = []
        try:
            conn = sqlite3.connect(LOCAL_DB)
            try:
                rows = conn.execute(
                    "SELECT patient_id, first_name, last_name, vector "
                    "FROM local_users"
                ).fetchall()
            except sqlite3.OperationalError:
                log.warning("local_users table not found")
                conn.close()
                return

            for pid, fn, ln, blob in rows:
                enc = np.frombuffer(blob, dtype=np.float32)
                self._face_users.append({
                    "patient_id": pid,
                    "name": f"{fn} {ln}".strip(),
                    "encoding": enc,
                })
            conn.close()
            log.info("Loaded %d face user(s)", len(self._face_users))
        except Exception as e:
            log.error("Failed to load face users: %s", e)

    # ── Schedule callback ──────────────────────────────────────────────
    @staticmethod
    def _meds_summary(medications: list) -> str:
        """Build a short display string from a medications list."""
        if not medications:
            return "Medication"
        names = [m.get("medication_name", "?") for m in medications]
        if len(names) == 1:
            return names[0]
        return f"{names[0]} +{len(names)-1} more"

    def _on_schedule_due(self, sched: DueSchedule):
        """Called by ScheduleMonitor when a medication time arrives."""
        med_summary = self._meds_summary(sched.medications)
        log.info(">>> SCHEDULE DUE: %s — slot %d [%s] for %s",
                 sched.planned_time, sched.slot_id, med_summary, sched.patient_name)

        # Reload face data in case new registrations happened
        self._load_face_users()

        # Set current schedule and start the dispensing window
        win = sched.window_seconds or WINDOW_SECONDS
        self._current_schedule = sched
        self._window_start = time.time()
        self._window_deadline = self._window_start + win

        # Transition display: IDLE → WAITING → AUTHENTICATING
        self._display.set_waiting(
            patient_name=sched.patient_name,
            medication_name=med_summary,
            slot_id=sched.slot_id,
            countdown=win,
        )

    # ── Face authentication (runs in separate thread) ──────────────────
    # ── Liveness (blink detection) ─────────────────────────────────────
    _EAR_CLOSED    = 0.22
    _EAR_OPEN      = 0.28
    _BLINKS_NEEDED = 1

    # MediaPipe Face Mesh eye landmark indices (6-point EAR)
    _LEFT_EYE  = [362, 385, 387, 263, 373, 380]
    _RIGHT_EYE = [33,  160, 158, 133, 153, 144]

    @staticmethod
    def _ear_from_mp(landmarks, indices: list[int], w: int, h: int) -> float:
        """Eye Aspect Ratio from MediaPipe Face Mesh landmarks."""
        import math
        pts = [(landmarks[i].x * w, landmarks[i].y * h) for i in indices]
        def d(a, b): return math.hypot(a[0]-b[0], a[1]-b[1])
        vert = d(pts[1], pts[5]) + d(pts[2], pts[4])
        horiz = 2.0 * d(pts[0], pts[3])
        return vert / horiz if horiz > 0 else 0.0

    def _auth_worker(self, expected_patient_id: str):
        """Background thread: face matching + MediaPipe blink liveness."""
        import face_recognition

        # Setup MediaPipe Face Mesh for blink detection
        face_mesh = None
        try:
            import mediapipe as mp
            face_mesh = mp.solutions.face_mesh.FaceMesh(
                static_image_mode=False,
                max_num_faces=1,
                refine_landmarks=True,
                min_detection_confidence=0.5,
                min_tracking_confidence=0.5,
            )
            log.info("MediaPipe liveness detection enabled")
        except Exception as e:
            log.warning("MediaPipe unavailable — liveness disabled: %s", e)

        blink_count    = 0
        eye_was_closed = False
        liveness_ok    = face_mesh is None  # skip liveness if MP not available
        face_matched_result = None

        log.info("Auth worker started for patient %s", expected_patient_id)

        while not self._auth_cancel.is_set():
            try:
                frame_rgb = self._auth_queue.get(timeout=1.0)
            except queue.Empty:
                continue

            if frame_rgb is None:
                break

            try:
                h, w = frame_rgb.shape[:2]

                # ── Blink detection via MediaPipe ──────────────────────
                if face_mesh is not None and not liveness_ok:
                    mp_result = face_mesh.process(frame_rgb)
                    if mp_result.multi_face_landmarks:
                        lm = mp_result.multi_face_landmarks[0].landmark
                        ear = (self._ear_from_mp(lm, self._LEFT_EYE, w, h) +
                               self._ear_from_mp(lm, self._RIGHT_EYE, w, h)) / 2.0
                        if ear < self._EAR_CLOSED:
                            eye_was_closed = True
                        elif eye_was_closed and ear > self._EAR_OPEN:
                            blink_count += 1
                            eye_was_closed = False
                            log.info("Blink detected (%d/%d)", blink_count, self._BLINKS_NEEDED)
                        if blink_count >= self._BLINKS_NEEDED:
                            liveness_ok = True
                            log.info("Liveness confirmed via blink")

                # ── Face recognition ───────────────────────────────────
                locations = face_recognition.face_locations(frame_rgb, model="hog")
                if not locations:
                    continue

                encodings = face_recognition.face_encodings(frame_rgb, locations)
                for enc in encodings:
                    for user in self._face_users:
                        dist = face_recognition.face_distance([user["encoding"]], enc)[0]
                        if dist <= FACE_MATCH_THRESHOLD:
                            if user["patient_id"] == expected_patient_id:
                                face_matched_result = {
                                    "matched":     True,
                                    "patient_id":  user["patient_id"],
                                    "name":        user["name"],
                                    "score":       1.0 - dist,
                                    "distance":    dist,
                                    "is_expected": True,
                                }
                                log.info("Face match: %s (dist=%.3f)", user["name"], dist)
                            else:
                                log.warning("Wrong face: %s (expected %s)",
                                            user["name"], expected_patient_id)

                # ── Accept only when face matched AND liveness confirmed ─
                if face_matched_result and liveness_ok:
                    try:
                        self._auth_result.put_nowait(face_matched_result)
                    except queue.Full:
                        pass
                    if face_mesh:
                        face_mesh.close()
                    return
                elif face_matched_result and not liveness_ok:
                    log.debug("Face matched — waiting for blink (%d/%d)",
                              blink_count, self._BLINKS_NEEDED)

            except Exception as e:
                log.error("Auth frame error: %s", e)

        if face_mesh:
            face_mesh.close()
        log.info("Auth worker stopped")

    def _start_auth_thread(self, patient_id: str):
        """Start the face authentication background thread."""
        self._auth_cancel.clear()
        # Drain queues
        while not self._auth_queue.empty():
            try:
                self._auth_queue.get_nowait()
            except queue.Empty:
                break
        while not self._auth_result.empty():
            try:
                self._auth_result.get_nowait()
            except queue.Empty:
                break

        self._auth_thread = threading.Thread(
            target=self._auth_worker,
            args=(patient_id,),
            name="face-auth",
            daemon=True,
        )
        self._auth_thread.start()

    def _stop_auth_thread(self):
        """Stop the face authentication thread."""
        self._auth_cancel.set()
        try:
            self._auth_queue.put_nowait(None)
        except queue.Full:
            pass
        if self._auth_thread:
            self._auth_thread.join(timeout=5)
            self._auth_thread = None

    # ── Dispensing logic ───────────────────────────────────────────────
    def _do_dispense(self, sched: DueSchedule, match_result: dict):
        """Execute the dispensing sequence after successful authentication."""
        med_summary = self._meds_summary(sched.medications)
        log.info("=== DISPENSING: slot %d [%s] for %s ===",
                 sched.slot_id, med_summary, match_result["name"])

        # Show dispensing screen
        self._display.set_dispensing(med_summary, sched.slot_id)

        # Run servo dispense cycle
        success = self._servo.dispense_cycle()

        if success:
            log.info("Dispense complete for slot %d", sched.slot_id)
        else:
            log.error("Dispense FAILED for slot %d", sched.slot_id)

        # Mark slot as 'dispensed' and reset loaded_counts to 0
        if success and sched.slot_id is not None:
            try:
                _db_set_slot_dispensed(sched.slot_id)
                log.info("Slot %d marked as dispensed", sched.slot_id)
            except Exception as e:
                log.warning("Failed to mark slot dispensed: %s", e)

        # Log to database
        self._log_dispense_event(sched, match_result, success)

    def _log_dispense_event(self, sched: DueSchedule, match: dict,
                            success: bool):
        """Log the dispensing event to face_auth_log and sync_queue."""
        try:
            conn = sqlite3.connect(LOCAL_DB)
            now = datetime.now().isoformat()

            # Face auth log
            conn.execute("""
                INSERT INTO face_auth_log
                    (patient_id, matched_patient, score, liveness_ok,
                     slot_dispensed, status, created_at)
                VALUES (?, ?, ?, 1, ?, ?, ?)
            """, (
                sched.patient_id,
                match["patient_id"],
                match["score"],
                sched.slot_id,
                "dispensed" if success else "dispense_failed",
                now,
            ))

            # Sync queue for AWS push
            try:
                import uuid
                conn.execute("""
                    INSERT INTO sync_queue
                        (log_id, patient_id, schedule_id, status,
                         face_auth_score, dispensing_at, device_timestamp,
                         is_synced, retry_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0)
                """, (
                    str(uuid.uuid4()),
                    sched.patient_id,
                    sched.schedule_id,
                    "dispensed" if success else "failed",
                    match["score"],
                    now,
                    now,
                ))
            except sqlite3.OperationalError as e:
                log.warning("sync_queue insert failed: %s", e)

            conn.commit()
            conn.close()
        except Exception as e:
            log.error("Failed to log dispense event: %s", e)

    def _log_timeout_event(self, sched: DueSchedule):
        """Log a missed dose event."""
        try:
            conn = sqlite3.connect(LOCAL_DB)
            now = datetime.now().isoformat()
            conn.execute("""
                INSERT INTO face_auth_log
                    (patient_id, matched_patient, score, liveness_ok,
                     slot_dispensed, status, created_at)
                VALUES (?, NULL, 0, 0, ?, 'timeout_missed', ?)
            """, (sched.patient_id, sched.slot_id, now))

            try:
                import uuid
                conn.execute("""
                    INSERT INTO sync_queue
                        (log_id, patient_id, schedule_id, status,
                         face_auth_score, dispensing_at, device_timestamp,
                         is_synced, retry_count)
                    VALUES (?, ?, ?, 'missed', 0, ?, ?, 0, 0)
                """, (
                    str(uuid.uuid4()),
                    sched.patient_id,
                    sched.schedule_id,
                    now, now,
                ))
            except sqlite3.OperationalError:
                pass

            conn.commit()
            conn.close()
        except Exception as e:
            log.error("Failed to log timeout: %s", e)

    def _get_next_info(self) -> str:
        """Fallback plain-string for IDLE (used when schedule list is empty)."""
        from datetime import datetime as _dt
        nxt = self._scheduler.get_next_schedule()
        if not nxt:
            return "No upcoming medications"
        now_hm = _dt.now().strftime("%H:%M")
        day = "Today" if nxt.planned_time > now_hm else "Tomorrow"
        med_summary = self._meds_summary(nxt.medications)
        return f"Next: {nxt.patient_name} — {med_summary} | {day} at {nxt.planned_time}"

    def _refresh_idle_display(self):
        """Push today's schedule list + fallback string to the display."""
        try:
            schedules = self._scheduler.get_todays_schedules()
            self._display.update_schedule_list(schedules)
        except Exception as e:
            log.warning("get_todays_schedules failed: %s", e)
        self._display.update_next_schedule(self._get_next_info())

    # ── Main loop ──────────────────────────────────────────────────────
    def run(self):
        """Main kiosk event loop."""
        log.info("=" * 50)
        log.info("  MediDispense Kiosk Starting")
        log.info("  Display: %s", "active" if self._display.running else "FAILED (headless mode)")
        log.info("  Servo: %s", "hardware" if self._servo.is_hardware else "dry-run")
        log.info("  Camera: PiCamera (picamera2/cv2)")
        log.info("  Face users: %d loaded", len(self._face_users))
        log.info("=" * 50)

        if not self._display.running:
            log.warning("Display unavailable — running in headless mode")
            log.warning("Fix: run with DISPLAY=:0 (X11) or WAYLAND_DISPLAY=wayland-1 (Wayland)")

        # Start schedule monitor
        self._scheduler = ScheduleMonitor(on_schedule_due=self._on_schedule_due)
        self._scheduler.start()

        # Populate IDLE screen immediately on startup
        self._refresh_idle_display()

        camera_open = False
        frame_skip = 0  # send every Nth frame to auth (save CPU)

        try:
            # Run even without display (headless mode)
            while not self._shutdown:
                state = self._display.state

                # ── IDLE state ─────────────────────────────────────
                if state == DisplayState.IDLE:
                    # Close camera if open
                    if camera_open:
                        self._camera.release()
                        camera_open = False

                    # Refresh schedule list periodically
                    now_t = time.time()
                    if now_t - self._last_schedule_refresh > IDLE_SCHEDULE_REFRESH:
                        self._last_schedule_refresh = now_t
                        self._refresh_idle_display()

                    if self._display.running:
                        self._display.render()
                    else:
                        time.sleep(0.1)  # headless idle

                # ── WAITING state (schedule triggered) ─────────────
                elif state == DisplayState.WAITING:
                    # Update countdown
                    remaining = int(self._window_deadline - time.time())
                    self._display.update_countdown(remaining)
                    if self._display.running:
                        self._display.render()

                    # After brief WAITING display, switch to camera
                    if time.time() - self._window_start > 2:
                        # Open camera
                        if not camera_open:
                            camera_open = self._camera.open()
                            if not camera_open:
                                log.error("Camera failed to open!")
                                self._display.set_error("Camera not available")
                                continue
                            log.info("Camera opened for face auth")

                        # Start auth thread
                        if self._current_schedule and self._auth_thread is None:
                            self._start_auth_thread(
                                self._current_schedule.patient_id
                            )

                        self._display.set_authenticating(remaining)

                # ── AUTHENTICATING state (camera active) ───────────
                elif state == DisplayState.AUTHENTICATING:
                    remaining = int(self._window_deadline - time.time())
                    self._display.update_countdown(remaining)

                    # Capture frame
                    frame_bgr = None
                    face_locs = None
                    if camera_open:
                        ok, frame_bgr = self._camera.read()
                        if ok and frame_bgr is not None:
                            # Get RGB for face detection
                            frame_rgb = frame_bgr[:, :, ::-1].copy()

                            # Detect face locations (for display overlay)
                            try:
                                import face_recognition
                                face_locs = face_recognition.face_locations(
                                    frame_rgb, model="hog"
                                )
                            except Exception:
                                face_locs = None

                            # Send to auth thread (skip frames to save CPU)
                            frame_skip += 1
                            if frame_skip >= 3:  # every 3rd frame
                                frame_skip = 0
                                try:
                                    self._auth_queue.put_nowait(frame_rgb)
                                except queue.Full:
                                    pass

                    # Render camera feed
                    if self._display.running:
                        self._display.render(
                            camera_frame=frame_bgr,
                            face_locations=face_locs,
                        )
                    else:
                        time.sleep(0.05)

                    # Check for auth result
                    try:
                        result = self._auth_result.get_nowait()
                        if result and result.get("matched") and result.get("is_expected"):
                            # SUCCESS!
                            self._stop_auth_thread()
                            self._camera.release()
                            camera_open = False

                            self._display.set_success(
                                result["name"], result["score"]
                            )
                            # Show success for a few seconds
                            t0 = time.time()
                            while time.time() - t0 < SUCCESS_DISPLAY_SEC:
                                if self._display.running:
                                    self._display.render()
                                else:
                                    time.sleep(0.1)

                            # Dispense medication
                            if self._current_schedule:
                                self._do_dispense(self._current_schedule, result)
                                # Show dispensing screen during servo action
                                t0 = time.time()
                                while time.time() - t0 < 2:
                                    if self._display.running:
                                        self._display.render()
                                    else:
                                        time.sleep(0.1)

                            # Return to idle — refresh schedule so past dose won't show
                            self._current_schedule = None
                            self._display.set_idle(next_info=self._get_next_info())
                            continue
                    except queue.Empty:
                        pass

                    # Check timeout
                    if remaining <= 0:
                        missed_sched = self._current_schedule
                        log.warning("Auth window TIMEOUT for %s",
                                    missed_sched.patient_name if missed_sched else "?")
                        self._stop_auth_thread()
                        self._camera.release()
                        camera_open = False

                        if missed_sched:
                            self._log_timeout_event(missed_sched)
                            # Show MISSED screen instead of generic timeout
                            self._display.set_missed(
                                missed_sched.patient_name,
                                self._meds_summary(missed_sched.medications),
                            )
                        else:
                            self._display.set_timeout()

                        t0 = time.time()
                        while time.time() - t0 < TIMEOUT_DISPLAY_SEC:
                            if self._display.running:
                                self._display.render()
                            else:
                                time.sleep(0.1)

                        self._current_schedule = None
                        self._display.set_idle(next_info=self._get_next_info())

                # ── SUCCESS / DISPENSING / TIMEOUT / MISSED / ERROR ──────────
                elif state in (DisplayState.SUCCESS, DisplayState.DISPENSING,
                               DisplayState.TIMEOUT, DisplayState.MISSED,
                               DisplayState.ERROR):
                    if self._display.running:
                        self._display.render()
                    else:
                        time.sleep(0.1)

        except KeyboardInterrupt:
            log.info("Keyboard interrupt")
        finally:
            self._cleanup()

    def _cleanup(self):
        """Graceful shutdown."""
        log.info("Shutting down kiosk...")
        self._stop_auth_thread()
        if self._scheduler:
            self._scheduler.stop()
        self._camera.release()
        self._servo.cleanup()
        self._display.shutdown()
        log.info("Kiosk stopped")


# ── Entry point ────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="MediDispense Kiosk")
    parser.add_argument("--windowed", action="store_true",
                        help="Run in windowed mode (not fullscreen)")
    args = parser.parse_args()

    # Set SDL video driver for Pi if running fullscreen
    if not args.windowed:
        # Try kmsdrm first (Pi 5 preferred), then fbdev
        if "DISPLAY" not in os.environ:
            os.environ.setdefault("SDL_VIDEODRIVER", "kmsdrm")

    app = KioskApp(fullscreen=not args.windowed)
    app.run()


if __name__ == "__main__":
    main()
