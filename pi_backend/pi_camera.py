"""
Camera abstraction for MediDispense.

Pi AI Camera (IMX500) uses picamera2/libcamera.
Falls back to cv2.VideoCapture for dev machines.
All consumers get a unified interface: open / read / release.
"""

import os
import time
import numpy as np

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def _log(msg: str):
    from datetime import datetime
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"[{ts}] [Camera] {msg}", flush=True)


class PiCamera:
    """Unified camera wrapper. Prefers picamera2 on Pi, falls back to OpenCV."""

    def __init__(self, width: int = 640, height: int = 480):
        self._width = width
        self._height = height
        self._backend = None  # "picamera2" or "cv2"
        self._cam = None
        self._opened = False

    def open(self) -> bool:
        # Try picamera2 first (Pi AI Camera / any Pi CSI camera)
        try:
            from picamera2 import Picamera2
            self._cam = Picamera2()
            config = self._cam.create_still_configuration(
                main={"size": (self._width, self._height), "format": "RGB888"},
            )
            self._cam.configure(config)
            self._cam.start()
            time.sleep(1)  # warm-up
            self._backend = "picamera2"
            self._opened = True
            _log(f"Opened via picamera2 ({self._width}x{self._height})")
            return True
        except Exception as e:
            _log(f"picamera2 not available: {e}")

        # Fall back to OpenCV V4L2 (try common indices; CSI vs USB order varies)
        try:
            import cv2
            for idx in (0, 1, 2):
                cap = cv2.VideoCapture(idx)
                if cap.isOpened():
                    cap.set(cv2.CAP_PROP_FRAME_WIDTH, self._width)
                    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self._height)
                    self._cam = cap
                    self._backend = "cv2"
                    self._opened = True
                    _log(
                        f"Opened via OpenCV device {idx} ({self._width}x{self._height})"
                    )
                    return True
                cap.release()
        except Exception as e:
            _log(f"OpenCV not available: {e}")

        _log("ERROR: No camera backend available")
        return False

    def read(self):
        """
        Read a frame as BGR numpy array (OpenCV convention).
        Returns (True, frame) or (False, None).
        """
        if not self._opened or self._cam is None:
            return False, None

        if self._backend == "picamera2":
            try:
                # picamera2 returns RGB, convert to BGR for OpenCV compat
                import cv2
                rgb = self._cam.capture_array()
                bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
                return True, bgr
            except Exception:
                return False, None

        elif self._backend == "cv2":
            return self._cam.read()

        return False, None

    def read_rgb(self):
        """
        Read a frame as RGB numpy array (face_recognition convention).
        Returns (True, frame) or (False, None).
        """
        if not self._opened or self._cam is None:
            return False, None

        if self._backend == "picamera2":
            try:
                rgb = self._cam.capture_array()
                return True, rgb
            except Exception:
                return False, None

        elif self._backend == "cv2":
            import cv2
            ret, bgr = self._cam.read()
            if ret:
                rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
                return True, rgb
            return False, None

        return False, None

    def isOpened(self) -> bool:
        return self._opened

    def release(self):
        if self._cam is None:
            return
        try:
            if self._backend == "picamera2":
                self._cam.stop()
                self._cam.close()
            elif self._backend == "cv2":
                self._cam.release()
        except Exception as e:
            _log(f"Release error: {e}")
        self._cam = None
        self._opened = False
        _log("Camera released")

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *args):
        self.release()

    @property
    def backend(self) -> str:
        return self._backend or "none"
