#!/usr/bin/env python3
"""Bootstrap script for the Pi backend. Downloads models and creates DB tables."""

from __future__ import annotations

import os
import sqlite3
import urllib.request

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(_SCRIPT_DIR, "faces.db")
MODEL_PATH = os.path.join(_SCRIPT_DIR, "face_landmarker.task")
MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/"
    "face_landmarker/face_landmarker/float16/1/face_landmarker.task"
)


def ensure_face_landmarker_task() -> None:
    if os.path.exists(MODEL_PATH):
        print(f"[bootstrap] Model exists: {MODEL_PATH}")
        return
    print(f"[bootstrap] Downloading: {MODEL_URL}")
    urllib.request.urlretrieve(MODEL_URL, MODEL_PATH)
    print(f"[bootstrap] Saved: {MODEL_PATH}")


def ensure_faces_db() -> None:
    conn = sqlite3.connect(DB_PATH)
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
            CREATE TABLE IF NOT EXISTS slot_bindings (
                slot_id     INTEGER PRIMARY KEY,
                patient_id  TEXT NOT NULL,
                pill_count  INTEGER DEFAULT 0,
                committed   INTEGER DEFAULT 0,
                updated_at  TEXT
            )
            """
        )
        # Individual face samples for multi-sample matching
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

        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS patients (
                patient_id   TEXT PRIMARY KEY,
                first_name   TEXT NOT NULL,
                last_name    TEXT NOT NULL,
                date_of_birth TEXT,
                created_at   TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS medications (
                medication_id       TEXT PRIMARY KEY,
                patient_id          TEXT NOT NULL,
                medication_name     TEXT NOT NULL,
                pill_barcode        TEXT,
                pill_color_shape    TEXT,
                remaining_count     INTEGER DEFAULT 0,
                low_stock_threshold INTEGER DEFAULT 5,
                expiry_date         TEXT,
                created_at          TEXT NOT NULL,
                FOREIGN KEY (patient_id) REFERENCES patients(patient_id)
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS sync_queue (
                log_id            TEXT PRIMARY KEY,
                schedule_id       TEXT,
                patient_id        TEXT NOT NULL,
                status            TEXT NOT NULL,
                face_auth_score   REAL,
                dispensing_at     TEXT,
                taken_at          TEXT,
                device_timestamp  TEXT,
                error_details     TEXT,
                is_synced         INTEGER DEFAULT 0,
                retry_count       INTEGER DEFAULT 0
            )
            """
        )
        conn.commit()
    finally:
        conn.close()
    print(f"[bootstrap] Database ready: {DB_PATH}")


def main() -> None:
    print("[bootstrap] Checking pi_backend files...\n")
    ensure_face_landmarker_task()
    ensure_faces_db()
    print("\n[bootstrap] Done. Next steps:")
    print("  - Fill in .env (API_BASE_URL etc.)")
    print("  - Register face: python3 register.py --first-name ... --last-name ...")
    print("  - Start BLE server: sudo python3 ble_server.py")


if __name__ == "__main__":
    main()
