import sqlite3
import psycopg2
import psycopg2.extras
from pathlib import Path
from fastapi import HTTPException
from dotenv import load_dotenv
import os

load_dotenv()

_BASE_DIR = Path(__file__).resolve().parent.parent
LOCAL_DB_PATH = _BASE_DIR / "faces.db"

_AWS_CONFIG = {
    "host":     os.getenv("DB_HOST"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME"),
    "user":     os.getenv("DB_USER"),
    "password": os.getenv("DB_PASSWORD"),
    "sslmode":  os.getenv("DB_SSLMODE", "require"),
}

def init_db():
    """Lambda doesn't have faces.db, only AWS connection check."""
    import os
    if os.getenv("AWS_LAMBDA_FUNCTION_NAME"):
        # We are in Lambda environment, skip SQLite check
        print("[DB] Lambda environment, skipping SQLite check.")
    else:
        # Local environment, check faces.db
        if not LOCAL_DB_PATH.exists():
            raise RuntimeError(f"faces.db not found: {LOCAL_DB_PATH}")
        print(f"[DB] Local DB: {LOCAL_DB_PATH}")

def close_db():
    print("[DB] Application closed.")

def get_aws():
    conn = None
    try:
        conn = psycopg2.connect(
            **_AWS_CONFIG,
            cursor_factory=psycopg2.extras.RealDictCursor
        )
        yield conn
    except psycopg2.OperationalError as e:
        raise HTTPException(status_code=503, detail=f"AWS connection error: {e}")
    finally:
        if conn:
            conn.close()

def get_local():
    conn = sqlite3.connect(LOCAL_DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()