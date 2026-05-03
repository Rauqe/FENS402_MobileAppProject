"""
Public `FaceCamera` type — same class as `pi_backend.pi_camera.PiCamera`.

Used by `kiosk_app.py` (`FaceCamera as PiCamera`), `camera_facade.py`, BLE, and enrollment.
"""

from __future__ import annotations

import os
import sys

_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _root not in sys.path:
    sys.path.insert(0, _root)

from pi_backend.pi_camera import PiCamera as FaceCamera

__all__ = ["FaceCamera"]
