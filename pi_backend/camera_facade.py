"""Uyumluluk: yüz kamerası face_authentication.facade içinde."""
import os
import sys

_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _root not in sys.path:
    sys.path.insert(0, _root)

from face_authentication.facade import FaceCamera

__all__ = ["FaceCamera"]
