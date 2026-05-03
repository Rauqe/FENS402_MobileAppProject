"""Uyumluluk: yüz kaydı face_authentication.pi_face_register içinde."""
import os
import sys

_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _root not in sys.path:
    sys.path.insert(0, _root)

from face_authentication.pi_face_register import (
    capture_face_encodings,
    check_face_duplicates,
    save_user_embedding,
)

__all__ = ["capture_face_encodings", "check_face_duplicates", "save_user_embedding"]
