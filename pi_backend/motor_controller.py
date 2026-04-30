"""
MotorController — 28BYJ-48 stepper motor (14-slot tray) + SG90 gate servo.

Hardware connections:
    28BYJ-48 Stepper Motor (via ULN2003 driver):
        GPIO17 (Pin 11) → IN1
        GPIO18 (Pin 12) → IN2
        GPIO27 (Pin 13) → IN3
        GPIO22 (Pin 15) → IN4
        Pin 2           → VCC (5V)
        Pin 6           → GND

    SG90 Gate Servo:
        GPIO12 (Pin 32) → Signal (orange/yellow)
        External 5V     → VCC (red)
        Pin 14          → GND (brown)

System:
    - 14 slots, 4096 steps/revolution → 293 steps per slot
    - Half-step sequence (8 steps) — smoother movement
    - SG90: 0° = closed, 90° = open

Environment variables:
    MOTOR_DRY_RUN=1  → simulate without hardware
    GPIO_CHIP=4      → Pi 5 = 4, Pi 4 = 0
"""

from __future__ import annotations

import os
import time
from datetime import datetime

# ── Constants ─────────────────────────────────────────────────────────────────

DRY_RUN   = os.environ.get("MOTOR_DRY_RUN", "").lower() in ("1", "true", "yes")
GPIO_CHIP = int(os.environ.get("GPIO_CHIP", "4"))

# 28BYJ-48 stepper motor pins (BCM)
STEP_PINS = [17, 18, 27, 22]

TOTAL_SLOTS    = 14
STEPS_PER_REV  = 4096
STEPS_PER_SLOT = STEPS_PER_REV // TOTAL_SLOTS   # 293 steps
STEP_DELAY     = 0.001   # seconds per step (lower = faster, min ~0.001)

# Half-step sequence (8 steps) — standard for 28BYJ-48
HALF_STEP_SEQ = [
    [1, 0, 0, 0],
    [1, 1, 0, 0],
    [0, 1, 0, 0],
    [0, 1, 1, 0],
    [0, 0, 1, 0],
    [0, 0, 1, 1],
    [0, 0, 0, 1],
    [1, 0, 0, 1],
]

# SG90 gate servo
GATE_PIN        = 12    # BCM GPIO 12
GATE_FREQ       = 50    # Hz
GATE_CLOSE_DUTY = 2.5   # 0°  — gate closed
GATE_OPEN_DUTY  = 7.5   # 90° — gate open
GATE_MOVE_TIME  = 0.5   # seconds for servo to reach position

# ── Logging

def _log(msg: str):
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"[{ts}] [MotorCtrl] {msg}", flush=True)

# ── lgpio initialization

_chip = None

if not DRY_RUN:
    try:
        import lgpio as _lgpio
        _chip = _lgpio.gpiochip_open(GPIO_CHIP)
        # Claim stepper motor pins as outputs
        for pin in STEP_PINS:
            _lgpio.gpio_claim_output(_chip, pin)
        # Claim gate servo pin as output
        _lgpio.gpio_claim_output(_chip, GATE_PIN)
        _log(f"lgpio chip {GPIO_CHIP} opened — step pins={STEP_PINS}, gate pin={GATE_PIN}")
    except Exception as e:
        DRY_RUN = True
        _chip = None
        _log(f"lgpio unavailable ({e}) → switching to DRY_RUN")

# ── MotorController

class MotorController:
    """14-slot stepper motor tray controller + SG90 gate servo."""

    def __init__(self):
        self._current_slot = 0
        self._seq_index    = 0   # current position in half-step sequence
        _log(f"Ready (DRY_RUN={DRY_RUN}, slots={TOTAL_SLOTS}, "
             f"{STEPS_PER_SLOT} steps/slot)")

    # ── Internal: stepper motor

    def _set_step(self, seq: list):
        """Apply a single half-step to the motor coils."""
        if DRY_RUN or _chip is None:
            return
        import lgpio
        for i, pin in enumerate(STEP_PINS):
            lgpio.gpio_write(_chip, pin, seq[i])

    def _step_motor(self, steps: int, cw: bool = True):
        """
        Rotate the stepper motor by the given number of steps.
        cw=True → clockwise, cw=False → counter-clockwise.
        """
        direction = 1 if cw else -1
        for _ in range(abs(steps)):
            self._seq_index = (self._seq_index + direction) % 8
            self._set_step(HALF_STEP_SEQ[self._seq_index])
            time.sleep(STEP_DELAY)
        # Power off coils after movement to prevent overheating
        self._motor_off()

    def _motor_off(self):
        """Turn off all motor coils."""
        if DRY_RUN or _chip is None:
            return
        import lgpio
        for pin in STEP_PINS:
            lgpio.gpio_write(_chip, pin, 0)

    # ── Internal: SG90 gate servo

    def _gate_pwm(self, duty: float):
        """Send PWM signal to the gate servo."""
        if DRY_RUN or _chip is None:
            return
        import lgpio
        lgpio.tx_pwm(_chip, GATE_PIN, GATE_FREQ, duty)

    # ── Slot rotation

    def rotate_to_slot(self, target_slot: int) -> bool:
        """Rotate tray to the target slot via the shortest path."""
        if not (0 <= target_slot < TOTAL_SLOTS):
            _log(f"Invalid slot: {target_slot} (valid range: 0–{TOTAL_SLOTS - 1})")
            return False

        if target_slot == self._current_slot:
            _log(f"Already at slot {target_slot}")
            return True

        # Calculate shortest rotation direction
        delta_fwd = (target_slot - self._current_slot) % TOTAL_SLOTS
        delta_rev = TOTAL_SLOTS - delta_fwd

        if delta_fwd <= delta_rev:
            delta, cw = delta_fwd, True
        else:
            delta, cw = delta_rev, False

        steps = delta * STEPS_PER_SLOT
        _log(f"Rotating: slot {self._current_slot} → {target_slot}  "
             f"{'CW' if cw else 'CCW'}  {delta} slots  {steps} steps")

        if DRY_RUN:
            time.sleep(delta * 0.5)  # simulate movement delay
        else:
            self._step_motor(steps, cw=cw)

        self._current_slot = target_slot
        _log(f"Arrived at slot {target_slot}")
        return True

    def rotate_one_slot(self, cw: bool = True) -> bool:
        """Rotate one slot forward or backward."""
        nxt = (self._current_slot + (1 if cw else -1)) % TOTAL_SLOTS
        return self.rotate_to_slot(nxt)

    def full_revolution(self, cw: bool = True) -> bool:
        """Full revolution — 14 slots = 4096 steps."""
        _log(f"Full revolution {'CW' if cw else 'CCW'} — {STEPS_PER_REV} steps")
        if DRY_RUN:
            time.sleep(4.0)
        else:
            self._step_motor(STEPS_PER_REV, cw=cw)
        return True

    # ── Gate servo

    def open_gate(self) -> bool:
        """Rotate SG90 servo to 90° — open the gate."""
        _log("Opening gate (90°)")
        if DRY_RUN:
            _log("[DRY-RUN] open_gate simulated")
            return True
        try:
            self._gate_pwm(GATE_OPEN_DUTY)
            time.sleep(GATE_MOVE_TIME)
            self._gate_pwm(0)  # stop PWM signal to prevent jitter
            return True
        except Exception as e:
            _log(f"open_gate error: {e}")
            return False

    def close_gate(self) -> bool:
        """Rotate SG90 servo to 0° — close the gate."""
        _log("Closing gate (0°)")
        if DRY_RUN:
            _log("[DRY-RUN] close_gate simulated")
            return True
        try:
            self._gate_pwm(GATE_CLOSE_DUTY)
            time.sleep(GATE_MOVE_TIME)
            self._gate_pwm(0)
            return True
        except Exception as e:
            _log(f"close_gate error: {e}")
            return False

    # ── Properties

    @property
    def current_slot(self) -> int:
        return self._current_slot

    @property
    def is_gate_open(self) -> bool:
        return False

    # ── Cleanup

    def cleanup(self):
        """Release all GPIO resources."""
        if not DRY_RUN and _chip is not None:
            try:
                import lgpio
                self._motor_off()
                self._gate_pwm(0)
                lgpio.gpiochip_close(_chip)
            except Exception:
                pass
        _log("GPIO cleaned up")