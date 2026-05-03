"""Uyumluluk: headless auth face_authentication.headless_auth içinde."""
import os
import sys

_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _root not in sys.path:
    sys.path.insert(0, _root)

from face_authentication.headless_auth import authenticate_user

__all__ = ["authenticate_user"]
