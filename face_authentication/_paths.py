"""SQLite face DB path — same file as `pi_backend/state_machine.LOCAL_DB`."""

from __future__ import annotations

import os

# Must match pi_backend/state_machine.py so kiosk, API, and enrollment share faces.db


def _resolve_local_db() -> str:
    if os.environ.get("FACES_DB"):
        return os.environ["FACES_DB"]
    try:
        from pi_backend.state_machine import LOCAL_DB as _SM_DB

        return _SM_DB
    except Exception:
        _root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        return os.path.join(_root, "pi_backend", "faces.db")


LOCAL_DB = _resolve_local_db()
