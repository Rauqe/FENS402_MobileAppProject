"""
Single-frame face match against enrolled users (dispenser window).

Uses the same distance/score rules as `pi_backend/kiosk_app.py`:
`face_locations(..., model="hog")` and `face_recognition.face_distance`;
score = 1.0 - distance for the closest enrolled user.
"""

from __future__ import annotations

import sqlite3

import numpy as np

from ._paths import LOCAL_DB
from .facade import FaceCamera


def _blob_to_vec(blob: bytes) -> np.ndarray:
    return np.frombuffer(blob, dtype=np.float32)


def authenticate_user() -> dict:
    """
    Capture one frame and match against `local_users`.

    Returns:
        success: {"status": "success", "patient_id", "name", "score"}
        failed:  {"status": "failed", "reason": str}
    """
    import face_recognition

    cam = FaceCamera()
    if not cam.open():
        return {"status": "failed", "reason": "camera_unavailable"}

    try:
        ok, rgb = cam.read_rgb()
        if not ok or rgb is None:
            return {"status": "failed", "reason": "no_frame"}

        locations = face_recognition.face_locations(rgb, model="hog")
        if not locations:
            return {"status": "failed", "reason": "no_face"}

        encs = face_recognition.face_encodings(rgb, locations)
        if not encs:
            return {"status": "failed", "reason": "no_encoding"}

        probe = encs[0]

        conn = sqlite3.connect(LOCAL_DB)
        try:
            rows = conn.execute(
                "SELECT patient_id, first_name, last_name, vector FROM local_users"
            ).fetchall()
        finally:
            conn.close()

        if not rows:
            return {"status": "failed", "reason": "no_enrollments"}

        best_pid: str | None = None
        best_name = ""
        best_dist = 1.0

        for pid, fn, ln, blob in rows:
            ref = _blob_to_vec(blob)
            d = float(face_recognition.face_distance([ref], probe)[0])
            if d < best_dist:
                best_dist = d
                best_pid = pid
                best_name = f"{fn} {ln}".strip()

        # Same as kiosk: score = 1.0 - distance; state_machine compares score >= 0.6
        score = 1.0 - best_dist

        return {
            "status": "success",
            "patient_id": best_pid,
            "name": best_name,
            "score": score,
        }
    finally:
        cam.release()
