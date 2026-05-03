"""Face enrollment: capture samples, store embeddings, duplicate detection."""

from __future__ import annotations

import sqlite3
import time
from datetime import datetime, timezone

import numpy as np

from ._paths import LOCAL_DB
from .facade import FaceCamera


def _ensure_face_user_tables() -> None:
    conn = sqlite3.connect(LOCAL_DB)
    try:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS local_users (
                patient_id TEXT PRIMARY KEY,
                first_name TEXT NOT NULL,
                last_name TEXT NOT NULL,
                vector BLOB NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS face_samples (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                patient_id TEXT NOT NULL,
                vector     BLOB NOT NULL,
                label      TEXT DEFAULT '',
                created_at TEXT NOT NULL,
                FOREIGN KEY (patient_id) REFERENCES local_users(patient_id)
            )
            """
        )
        conn.commit()
    finally:
        conn.close()


def _blob_to_vec(blob: bytes) -> np.ndarray:
    return np.frombuffer(blob, dtype=np.float32)


def capture_face_encodings(max_samples: int = 5) -> list[np.ndarray]:
    """
    Capture up to max_samples 128-d encodings from the Pi camera.

    Uses the same detection model as `pi_backend/kiosk_app.py` (HOG on Pi).
    """
    import face_recognition

    max_samples = max(1, min(int(max_samples), 10))
    cam = FaceCamera()
    if not cam.open():
        raise RuntimeError("Camera could not be opened")

    encodings: list[np.ndarray] = []
    attempts = 0
    max_attempts = max(30, max_samples * 15)

    try:
        while len(encodings) < max_samples and attempts < max_attempts:
            attempts += 1
            ok, rgb = cam.read_rgb()
            if not ok or rgb is None:
                time.sleep(0.15)
                continue

            locations = face_recognition.face_locations(rgb, model="hog")
            if not locations:
                time.sleep(0.2)
                continue

            encs = face_recognition.face_encodings(rgb, locations)
            if encs:
                encodings.append(encs[0])
            time.sleep(0.25)
    finally:
        cam.release()

    return encodings


def check_face_duplicates(
    avg_vector: np.ndarray,
    threshold: float = 0.6,
    exclude_patient_id: str | None = None,
) -> dict | None:
    """
    Return duplicate if another enrolled user is closer than `threshold`
    (same metric as `face_recognition.face_distance`, used in kiosk_app).
    """
    import face_recognition

    _ensure_face_user_tables()
    conn = sqlite3.connect(LOCAL_DB)
    try:
        rows = conn.execute(
            "SELECT patient_id, first_name, last_name, vector FROM local_users"
        ).fetchall()
    finally:
        conn.close()

    probe = np.asarray(avg_vector, dtype=np.float64)
    best: dict | None = None
    best_dist = threshold

    for pid, fn, ln, blob in rows:
        if exclude_patient_id and pid == exclude_patient_id:
            continue
        ref = _blob_to_vec(blob).astype(np.float64)
        dist = float(face_recognition.face_distance([ref], probe)[0])
        if dist < best_dist:
            best_dist = dist
            best = {
                "patient_id": pid,
                "first_name": fn,
                "last_name": ln,
                "distance": dist,
            }
    return best


def save_user_embedding(
    patient_id: str,
    first_name: str,
    last_name: str,
    avg_vector: np.ndarray,
    *,
    individual_encodings: list[np.ndarray] | None = None,
) -> None:
    """Upsert average embedding and optional per-sample rows."""
    _ensure_face_user_tables()
    blob = np.asarray(avg_vector, dtype=np.float32).tobytes()
    now = datetime.now(timezone.utc).isoformat()

    conn = sqlite3.connect(LOCAL_DB)
    try:
        conn.execute(
            """
            INSERT INTO local_users (patient_id, first_name, last_name, vector)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(patient_id) DO UPDATE SET
                first_name = excluded.first_name,
                last_name = excluded.last_name,
                vector = excluded.vector
            """,
            (patient_id, first_name, last_name, blob),
        )

        conn.execute("DELETE FROM face_samples WHERE patient_id = ?", (patient_id,))

        if individual_encodings:
            for enc in individual_encodings:
                sb = np.asarray(enc, dtype=np.float32).tobytes()
                conn.execute(
                    """
                    INSERT INTO face_samples (patient_id, vector, label, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    (patient_id, sb, "registration", now),
                )
        conn.commit()
    finally:
        conn.close()
