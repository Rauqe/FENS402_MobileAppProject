"""
Authentication helpers: password hashing, user CRUD.
Uses PBKDF2-SHA256 (built-in hashlib, no extra packages needed).

Model ID identifies the physical dispenser box.
If a user provides the correct Model ID during signup, they become Caregiver.
"""

import os
import hashlib
import secrets
import sqlite3
from datetime import datetime, timezone
from typing import Optional

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_DB = os.path.join(_SCRIPT_DIR, "faces.db")

# Set via env var on Pi, or change the default here.
DISPENSER_MODEL_ID = os.environ.get("DISPENSER_MODEL_ID", "MEDI-FENS402-2026")

_ITERATIONS = 100_000  # Balanced: secure enough, fast on Raspberry Pi 5


def _ensure_users_table():
    conn = sqlite3.connect(LOCAL_DB)
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                email           TEXT    UNIQUE NOT NULL,
                password_hash   TEXT    NOT NULL,
                role            TEXT    NOT NULL DEFAULT 'patient',
                patient_id      TEXT,
                created_at      TEXT    NOT NULL,
                cloud_synced_at TEXT
            )
        """)
        # Add cloud_synced_at if missing on existing DBs
        try:
            conn.execute("ALTER TABLE users ADD COLUMN cloud_synced_at TEXT")
        except Exception:
            pass  # Column already exists
        conn.commit()
    finally:
        conn.close()


_ensure_users_table()


# ── Password helpers ──────────────────────────────────────────────────────────

def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    key = hashlib.pbkdf2_hmac(
        "sha256", password.encode(), salt.encode(), _ITERATIONS
    )
    # Format: pbkdf2:{iterations}:{salt}:{key_hex}
    return f"pbkdf2:{_ITERATIONS}:{salt}:{key.hex()}"


def verify_password(password: str, stored_hash: str) -> bool:
    try:
        parts = stored_hash.split(":")
        if len(parts) == 4:
            # New format: pbkdf2:{iterations}:{salt}:{key_hex}
            _, iterations, salt, key_hex = parts
            iters = int(iterations)
        elif len(parts) == 3:
            # Legacy format: pbkdf2:{salt}:{key_hex} — was always 260_000
            _, salt, key_hex = parts
            iters = 260_000
        else:
            return False
        key = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), salt.encode(), iters
        )
        return secrets.compare_digest(key.hex(), key_hex)
    except Exception:
        return False


def validate_password_strength(password: str) -> Optional[str]:
    """Return error message if weak, None if strong enough."""
    if len(password) < 8:
        return "Password must be at least 8 characters"
    if not any(c.isupper() for c in password):
        return "Password must contain at least one uppercase letter"
    if not any(c.islower() for c in password):
        return "Password must contain at least one lowercase letter"
    if not any(c.isdigit() for c in password):
        return "Password must contain at least one number"
    return None


# ── User CRUD ─────────────────────────────────────────────────────────────────

def create_user(
    email: str,
    password: str,
    role: str = "patient",
    patient_id: Optional[str] = None,
) -> dict:
    """
    Create a new user. Returns {ok, message, role, patient_id, email}.
    """
    err = validate_password_strength(password)
    if err:
        return {"ok": False, "message": err}

    pw_hash = hash_password(password)
    now = datetime.now(timezone.utc).isoformat()

    conn = sqlite3.connect(LOCAL_DB)
    try:
        conn.execute(
            """
            INSERT INTO users (email, password_hash, role, patient_id, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (email.lower().strip(), pw_hash, role, patient_id, now),
        )
        conn.commit()
        return {
            "ok": True,
            "message": f"Account created as {role}",
            "email": email.lower().strip(),
            "role": role,
            "patient_id": patient_id,
        }
    except sqlite3.IntegrityError:
        return {"ok": False, "message": "Email already registered"}
    finally:
        conn.close()


def authenticate_user(email: str, password: str) -> dict:
    """
    Verify credentials. Returns {ok, role, patient_id, email} on success.
    """
    conn = sqlite3.connect(LOCAL_DB)
    try:
        row = conn.execute(
            "SELECT password_hash, role, patient_id FROM users WHERE email = ?",
            (email.lower().strip(),),
        ).fetchone()
    finally:
        conn.close()

    if row is None:
        return {"ok": False, "message": "Email not found"}

    pw_hash, role, patient_id = row
    if not verify_password(password, pw_hash):
        return {"ok": False, "message": "Incorrect password"}

    return {
        "ok": True,
        "email": email.lower().strip(),
        "role": role,
        "patient_id": patient_id,
        "message": f"Welcome back ({role})",
    }


def get_user(email: str) -> Optional[dict]:
    conn = sqlite3.connect(LOCAL_DB)
    try:
        row = conn.execute(
            "SELECT email, role, patient_id, created_at FROM users WHERE email = ?",
            (email.lower().strip(),),
        ).fetchone()
        if row:
            return {
                "email": row[0],
                "role": row[1],
                "patient_id": row[2],
                "created_at": row[3],
            }
        return None
    finally:
        conn.close()
