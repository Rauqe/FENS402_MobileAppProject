"""
Register a user's face into faces.db with multiple samples.

Captures N samples, saves each individually to face_samples table,
and stores the averaged embedding in local_users for backward compat.
"""

import argparse
import os
import sqlite3
import time
import uuid

import cv2
import face_recognition
import numpy as np

from pi_camera import PiCamera


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(SCRIPT_DIR, "faces.db")


def ensure_local_users_table(conn: sqlite3.Connection) -> None:
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
    conn.commit()


def capture_face_encodings(
    max_samples: int = 5,
    timeout_sec: int = 30,
) -> list[np.ndarray]:
    """
    Capture face encodings. Works headless (SSH) — auto-captures when
    exactly one face is detected. No display needed.
    """
    cam = PiCamera()
    if not cam.open():
        raise RuntimeError("Camera could not be opened")

    print(f"\n[Register] Camera opened (backend: {cam.backend})")
    print(f"[Register] Auto-capturing {max_samples} samples...")
    print("[Register] Stand ~50cm in front of the camera, face forward.\n")

    encodings: list[np.ndarray] = []
    started = time.time()
    frame_count = 0
    # Skip initial frames (camera warm-up)
    warmup_frames = 5

    try:
        while len(encodings) < max_samples and (time.time() - started) < timeout_sec:
            ok, rgb = cam.read_rgb()
            if not ok:
                time.sleep(0.1)
                continue

            frame_count += 1
            if frame_count <= warmup_frames:
                continue

            face_locations = face_recognition.face_locations(rgb)

            if len(face_locations) == 0:
                if frame_count % 15 == 0:
                    print("[Register] No face detected — keep looking at camera...")
                time.sleep(0.1)
                continue

            if len(face_locations) > 1:
                print(f"[Register] {len(face_locations)} faces — need exactly 1")
                time.sleep(0.3)
                continue

            # Exactly one face found — auto-capture
            enc = face_recognition.face_encodings(rgb, known_face_locations=face_locations)
            if not enc:
                print("[Register] Encoding failed, retrying...")
                continue

            encodings.append(enc[0].astype(np.float32))
            print(f"[Register] Sample {len(encodings)}/{max_samples} captured")
            # Brief pause between samples for slight pose variation
            time.sleep(0.5)

    finally:
        cam.release()

    elapsed = time.time() - started
    print(f"[Register] Done: {len(encodings)} samples in {elapsed:.1f}s")
    return encodings


def _ensure_face_samples_table(conn: sqlite3.Connection) -> None:
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


def check_face_duplicates(
    new_encoding: np.ndarray,
    threshold: float = 0.6,
    exclude_patient_id: str | None = None,
) -> dict | None:
    """
    Check if the new face encoding matches any existing registered face.
    Returns {patient_id, first_name, last_name, distance} if duplicate found, None otherwise.
    Uses face_recognition distance: <0.6 is typically a match.

    exclude_patient_id: skip this patient when checking (used during re-registration
                        so a patient's own existing face doesn't block the update).
    """
    conn = sqlite3.connect(DB_PATH)
    try:
        try:
            rows = conn.execute(
                "SELECT patient_id, vector FROM face_samples"
            ).fetchall()
        except sqlite3.OperationalError:
            return None  # Table doesn't exist yet

        if not rows:
            return None

        min_distance = float('inf')
        closest_patient = None

        for patient_id, vector_blob in rows:
            # Skip the patient being re-registered — their own face shouldn't block update
            if exclude_patient_id and patient_id == exclude_patient_id:
                continue
            existing_enc = np.frombuffer(vector_blob, dtype=np.float32)
            distance = face_recognition.face_distance([existing_enc], new_encoding)[0]

            if distance < min_distance:
                min_distance = distance
                closest_patient = patient_id

        # If closest match is below threshold, return match details
        if min_distance <= threshold and closest_patient:
            user = conn.execute(
                "SELECT first_name, last_name FROM local_users WHERE patient_id = ?",
                (closest_patient,)
            ).fetchone()
            if user:
                return {
                    "patient_id": closest_patient,
                    "first_name": user[0],
                    "last_name": user[1],
                    "distance": float(min_distance),
                }

        return None
    finally:
        conn.close()


def save_user_embedding(
    patient_id: str,
    first_name: str,
    last_name: str,
    avg_encoding: np.ndarray,
    individual_encodings: list[np.ndarray] | None = None,
) -> None:
    from datetime import datetime, timezone

    conn = sqlite3.connect(DB_PATH)
    try:
        ensure_local_users_table(conn)
        _ensure_face_samples_table(conn)

        # Save averaged vector to local_users (backward compat)
        blob = avg_encoding.astype(np.float32).tobytes()
        conn.execute(
            """
            INSERT INTO local_users (patient_id, first_name, last_name, vector)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(patient_id) DO UPDATE SET
                first_name=excluded.first_name,
                last_name=excluded.last_name,
                vector=excluded.vector
            """,
            (patient_id, first_name, last_name, blob),
        )

        # Save individual samples to face_samples
        if individual_encodings:
            # Clear old samples for this patient
            conn.execute(
                "DELETE FROM face_samples WHERE patient_id = ?", (patient_id,)
            )
            now = datetime.now(timezone.utc).isoformat()
            for i, enc in enumerate(individual_encodings):
                conn.execute(
                    """
                    INSERT INTO face_samples (patient_id, vector, label, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    (patient_id, enc.astype(np.float32).tobytes(), f"sample_{i}", now),
                )

        conn.commit()
    finally:
        conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Register face to faces.db")
    parser.add_argument("--patient-id", dest="patient_id", default=None)
    parser.add_argument("--first-name", dest="first_name", required=True)
    parser.add_argument("--last-name", dest="last_name", required=True)
    parser.add_argument("--samples", dest="samples", type=int, default=5)
    args = parser.parse_args()

    patient_id = args.patient_id or str(uuid.uuid4())
    first_name = args.first_name.strip()
    last_name = args.last_name.strip()

    if not first_name or not last_name:
        raise ValueError("first_name and last_name must not be empty")

    print(f"[Register] DB path: {DB_PATH}")
    print(f"[Register] patient_id: {patient_id}")
    print(f"[Register] name: {first_name} {last_name}")

    encodings = capture_face_encodings(max_samples=max(1, args.samples))
    if not encodings:
        print("[Register] No valid face samples captured. Nothing was saved.")
        return

    avg = np.mean(encodings, axis=0).astype(np.float32)
    save_user_embedding(
        patient_id, first_name, last_name, avg,
        individual_encodings=encodings,
    )

    print("\n[Register] Success!")
    print(f"[Register] Saved user: {first_name} {last_name}")
    print(f"[Register] patient_id: {patient_id}")
    print(f"[Register] samples used: {len(encodings)}")


if __name__ == "__main__":
    main()
