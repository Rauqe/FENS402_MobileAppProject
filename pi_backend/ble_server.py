#!/usr/bin/env python3
"""
SmartDrugDispenser — Raspberry Pi BLE GATT Server
==================================================

Görev: Ana sunucu — Bluetooth (BLE) bağlantısı ve telefondan gelen komutları yönetir.

This script turns the Raspberry Pi's built-in Bluetooth into a BLE peripheral
that the Flutter companion app can discover, connect to, and control.

İlgili dosyalar: faces.db (slot eşlemeleri), .env (API_BASE_URL), face_auth_headless / dispense_controller.

Architecture:
    Flutter App  ──BLE──►  This script (Raspberry Pi)
                                │
                                ├── GPIO control (motors, LEDs)  [TODO]
                                └── Sensor reading (IR, load-cell) [TODO]

Protocol (mirrors ble_constants.dart exactly):
    ┌──────────────────────────────────────────────────────────────────────────┐
    │  SERVICE UUID  : 12345678-1234-1234-1234-1234567890ab                   │
    │                                                                          │
    │  COMMAND CHAR  : abcd1234-ab12-ab12-ab12-abcdef123456   (write)         │
    │     0x01 = UNLOCK          – open compartment                           │
    │     0x02 = LOCK            – force-lock                                 │
    │     0x03 = STATUS_REQUEST  – query device state                         │
    │     0x04 = ACK             – acknowledge event                          │
    │     0x05 = IDENTIFY        – blink LED                                  │
    │     0x06 = BIND_SLOT       – bind patient to physical slot              │
    │     0x07 = BARCODE_INC     – barcode scanned, pill count +1             │
    │     0x08 = COMMIT_MEDS     – finish loading slot                        │
    │     0x09 = TRIGGER_DISP    – start 15-min dispense window               │
    │                                                                          │
    │  NOTIFY CHAR   : dcba4321-dc43-dc43-dc43-dcba98765432   (notify)       │
    │     0xA1 = PILL_TAKEN      – sensor-confirmed pill removal              │
    │     0xA2 = MISSED_DOSE     – compartment opened, pill not taken         │
    │     0xA3 = HARDWARE_ERROR  – error (byte[1] = error code)               │
    │     0xA4 = STATUS_RESPONSE – response to STATUS_REQUEST                 │
    │     0xA5 = COMMAND_ACK     – last command acknowledged                  │
    └──────────────────────────────────────────────────────────────────────────┘

Requirements (install on the Pi):
    sudo apt-get update
    sudo apt-get install -y python3-dbus python3-gi bluetooth bluez

Usage:
    sudo python3 ble_server.py

    "sudo" is required because BlueZ advertising needs root privileges.
"""

import dbus
import dbus.exceptions
import dbus.mainloop.glib
import dbus.service
import sqlite3
import struct
import sys
import threading
from datetime import datetime
from gi.repository import GLib

import os
try:
    from dotenv import load_dotenv
    load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
except ImportError:
    pass

try:
    import requests as _requests
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False

try:
    from face_auth_headless import authenticate_user
    FACE_AUTH_AVAILABLE = True
except ImportError:
    FACE_AUTH_AVAILABLE = False

try:
    from dispense_controller import DispenseController
    HAS_DISPENSE_CTRL = True
except ImportError:
    HAS_DISPENSE_CTRL = False

FACE_SCORE_THRESHOLD = 0.6
LOCAL_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "faces.db")

API_BASE_URL = os.getenv(
    "API_BASE_URL",
    "https://s766ccq1c7.execute-api.eu-north-1.amazonaws.com/default"
)

# ═══════════════════════════════════════════════════════════════════════════════
# Constants — MUST match ble_constants.dart
# ═══════════════════════════════════════════════════════════════════════════════

DEVICE_NAME = "SmartDispenser"

SERVICE_UUID        = "12345678-1234-1234-1234-1234567890ab"
COMMAND_CHAR_UUID   = "abcd1234-ab12-ab12-ab12-abcdef123456"
NOTIFY_CHAR_UUID    = "dcba4321-dc43-dc43-dc43-dcba98765432"

# Commands (mobile → Pi)
CMD_UNLOCK         = 0x01
CMD_LOCK           = 0x02
CMD_STATUS_REQUEST = 0x03
CMD_ACK            = 0x04
CMD_IDENTIFY       = 0x05
CMD_BIND_SLOT         = 0x06
CMD_BARCODE_INCREMENT = 0x07
CMD_COMMIT_MEDS       = 0x08
CMD_TRIGGER_DISPENSE  = 0x09

# Events (Pi → mobile)
EVT_PILL_TAKEN      = 0xA1
EVT_MISSED_DOSE     = 0xA2
EVT_HARDWARE_ERROR  = 0xA3
EVT_STATUS_RESPONSE = 0xA4
EVT_COMMAND_ACK     = 0xA5

# Error sub-codes (second byte of EVT_HARDWARE_ERROR)
ERR_AUTH_FAILED    = 0x01
ERR_MOTOR_ERROR    = 0x02
ERR_SLOT_NOT_BOUND = 0x03
ERR_TIMEOUT        = 0x04

# ═══════════════════════════════════════════════════════════════════════════════
# D-Bus constants
# ═══════════════════════════════════════════════════════════════════════════════

BLUEZ_SERVICE_NAME = "org.bluez"
LE_ADVERTISING_MANAGER_IFACE = "org.bluez.LEAdvertisingManager1"
LE_ADVERTISEMENT_IFACE       = "org.bluez.LEAdvertisement1"
GATT_MANAGER_IFACE           = "org.bluez.GattManager1"
GATT_SERVICE_IFACE           = "org.bluez.GattService1"
GATT_CHRC_IFACE              = "org.bluez.GattCharacteristic1"
GATT_DESC_IFACE              = "org.bluez.GattDescriptor1"
DBUS_OM_IFACE                = "org.freedesktop.DBus.ObjectManager"
DBUS_PROP_IFACE              = "org.freedesktop.DBus.Properties"

ADAPTER_PATH = "/org/bluez/hci0"

mainloop = None


def log(msg: str):
    ts = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    print(f"[{ts}] {msg}", flush=True)


# ═══════════════════════════════════════════════════════════════════════════════
# Local DB helpers — slot bindings persisted in faces.db
# ═══════════════════════════════════════════════════════════════════════════════

def _init_local_tables():
    """Ensure dispenser-related tables exist in faces.db."""
    conn = sqlite3.connect(LOCAL_DB)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS slot_bindings (
            slot_id     INTEGER PRIMARY KEY,
            patient_id  TEXT NOT NULL,
            pill_count  INTEGER DEFAULT 0,
            committed   INTEGER DEFAULT 0,
            updated_at  TEXT
        )
    """)
    conn.execute("""
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
    """)
    conn.commit()
    conn.close()


def _db_bind_slot(slot_id: int, patient_id: str):
    conn = sqlite3.connect(LOCAL_DB)
    conn.execute("""
        INSERT INTO slot_bindings (slot_id, patient_id, pill_count, committed, updated_at)
        VALUES (?, ?, 0, 0, ?)
        ON CONFLICT(slot_id) DO UPDATE SET
            patient_id = excluded.patient_id,
            pill_count = 0,
            committed  = 0,
            updated_at = excluded.updated_at
    """, (slot_id, patient_id, datetime.utcnow().isoformat()))
    conn.commit()
    conn.close()


def _db_increment_count(slot_id: int) -> int:
    """Increment pill_count for a slot and return the new count."""
    conn = sqlite3.connect(LOCAL_DB)
    conn.execute(
        "UPDATE slot_bindings SET pill_count = pill_count + 1, updated_at = ? WHERE slot_id = ?",
        (datetime.utcnow().isoformat(), slot_id),
    )
    conn.commit()
    row = conn.execute("SELECT pill_count FROM slot_bindings WHERE slot_id = ?", (slot_id,)).fetchone()
    conn.close()
    return row[0] if row else 0


def _db_get_binding(slot_id: int):
    """Return (patient_id, pill_count, committed) or None."""
    conn = sqlite3.connect(LOCAL_DB)
    row = conn.execute(
        "SELECT patient_id, pill_count, committed FROM slot_bindings WHERE slot_id = ?",
        (slot_id,),
    ).fetchone()
    conn.close()
    return row


def _db_mark_committed(slot_id: int):
    conn = sqlite3.connect(LOCAL_DB)
    conn.execute(
        "UPDATE slot_bindings SET committed = 1, updated_at = ? WHERE slot_id = ?",
        (datetime.utcnow().isoformat(), slot_id),
    )
    conn.commit()
    conn.close()


def _api_update_medication_slot(patient_id: str, slot_id: int, remaining_count: int = None):
    """Call PUT /medications to set slot_id (and optionally remaining_count) for a patient's medication.
    This is best-effort; failures are logged but do not block BLE flow."""
    if not HAS_REQUESTS:
        log("⚠  requests library not available — skipping API call")
        return False
    try:
        url = f"{API_BASE_URL}/medications/{patient_id}"
        resp = _requests.get(url, timeout=8)
        if resp.status_code != 200:
            log(f"⚠  API GET medications failed: {resp.status_code}")
            return False
        meds = resp.json().get("medications", [])
        if not meds:
            log("⚠  No medications found for patient — cannot set slot_id via API")
            return False
        med_id = str(meds[0]["medication_id"])
        payload = {"slot_id": slot_id}
        if remaining_count is not None:
            payload["remaining_count"] = remaining_count
        put_resp = _requests.put(f"{API_BASE_URL}/medications/{med_id}", json=payload, timeout=8)
        if put_resp.status_code == 200:
            log(f"✅  API: medication {med_id[:8]}... slot_id={slot_id} updated")
            return True
        else:
            log(f"⚠  API PUT failed: {put_resp.status_code} {put_resp.text[:120]}")
            return False
    except Exception as e:
        log(f"⚠  API call failed: {e}")
        return False


_init_local_tables()

# ═══════════════════════════════════════════════════════════════════════════════
# Base classes (thin D-Bus wrappers)
# ═══════════════════════════════════════════════════════════════════════════════

class Application(dbus.service.Object):
    """Root container that BlueZ queries via GetManagedObjects."""

    def __init__(self, bus):
        self.path = "/"
        self.services = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_service(self, service):
        self.services.append(service)

    @dbus.service.method(DBUS_OM_IFACE, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        response = {}
        for service in self.services:
            response[service.get_path()] = service.get_properties()
            for chrc in service.characteristics:
                response[chrc.get_path()] = chrc.get_properties()
                for desc in chrc.descriptors:
                    response[desc.get_path()] = desc.get_properties()
        return response


class Service(dbus.service.Object):
    PATH_BASE = "/org/bluez/example/service"

    def __init__(self, bus, index, uuid, primary):
        self.path = f"{self.PATH_BASE}{index}"
        self.bus = bus
        self.uuid = uuid
        self.primary = primary
        self.characteristics = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        return {
            GATT_SERVICE_IFACE: {
                "UUID": self.uuid,
                "Primary": self.primary,
                "Characteristics": dbus.Array(
                    [c.get_path() for c in self.characteristics],
                    signature="o",
                ),
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_characteristic(self, chrc):
        self.characteristics.append(chrc)

    @dbus.service.method(DBUS_PROP_IFACE, in_signature="s",
                         out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != GATT_SERVICE_IFACE:
            raise dbus.exceptions.DBusException(
                "org.freedesktop.DBus.Error.InvalidArgs",
                f"Unknown interface: {interface}",
            )
        return self.get_properties()[GATT_SERVICE_IFACE]


class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service):
        self.path = f"{service.path}/char{index}"
        self.bus = bus
        self.uuid = uuid
        self.service = service
        self.flags = flags
        self.descriptors = []
        self.value = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_properties(self):
        return {
            GATT_CHRC_IFACE: {
                "Service": self.service.get_path(),
                "UUID": self.uuid,
                "Flags": self.flags,
                "Descriptors": dbus.Array(
                    [d.get_path() for d in self.descriptors],
                    signature="o",
                ),
            }
        }

    def get_path(self):
        return dbus.ObjectPath(self.path)

    @dbus.service.method(DBUS_PROP_IFACE, in_signature="s",
                         out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != GATT_CHRC_IFACE:
            raise dbus.exceptions.DBusException(
                "org.freedesktop.DBus.Error.InvalidArgs",
                f"Unknown interface: {interface}",
            )
        return self.get_properties()[GATT_CHRC_IFACE]

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="a{sv}",
                         out_signature="ay")
    def ReadValue(self, options):
        return self.value

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="aya{sv}")
    def WriteValue(self, value, options):
        self.value = value

    @dbus.service.method(GATT_CHRC_IFACE)
    def StartNotify(self):
        pass

    @dbus.service.method(GATT_CHRC_IFACE)
    def StopNotify(self):
        pass

    @dbus.service.signal(DBUS_PROP_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass


class Advertisement(dbus.service.Object):
    PATH_BASE = "/org/bluez/example/advertisement"

    def __init__(self, bus, index, ad_type):
        self.path = f"{self.PATH_BASE}{index}"
        self.bus = bus
        self.ad_type = ad_type
        self.service_uuids = None
        self.local_name = None
        self.includes = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def get_properties(self):
        props = {"Type": self.ad_type}
        if self.service_uuids is not None:
            props["ServiceUUIDs"] = dbus.Array(self.service_uuids, signature="s")
        if self.local_name is not None:
            props["LocalName"] = dbus.String(self.local_name)
        if self.includes:
            props["Includes"] = dbus.Array(self.includes, signature="s")
        return {LE_ADVERTISEMENT_IFACE: props}

    @dbus.service.method(DBUS_PROP_IFACE, in_signature="s",
                         out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != LE_ADVERTISEMENT_IFACE:
            raise dbus.exceptions.DBusException(
                "org.freedesktop.DBus.Error.InvalidArgs",
                f"Unknown interface: {interface}",
            )
        return self.get_properties()[LE_ADVERTISEMENT_IFACE]

    @dbus.service.method(LE_ADVERTISEMENT_IFACE, in_signature="",
                         out_signature="")
    def Release(self):
        log("Advertisement released")


# ═══════════════════════════════════════════════════════════════════════════════
# SmartDispenser — Concrete GATT implementation
# ═══════════════════════════════════════════════════════════════════════════════

class DispenserAdvertisement(Advertisement):
    def __init__(self, bus, index):
        super().__init__(bus, index, "peripheral")
        self.service_uuids = [SERVICE_UUID]
        self.local_name = DEVICE_NAME
        self.includes = ["tx-power"]


class DispenserService(Service):
    def __init__(self, bus, index):
        super().__init__(bus, index, SERVICE_UUID, primary=True)

        # Command characteristic (mobile writes commands here)
        self.command_char = CommandCharacteristic(bus, 0, self)
        self.add_characteristic(self.command_char)

        # Notify characteristic (Pi pushes events to mobile)
        self.notify_char = NotifyCharacteristic(bus, 1, self)
        self.add_characteristic(self.notify_char)

        # Cross-link so CommandChar can push events via NotifyChar
        self.command_char.notify_char = self.notify_char

        # Dispense controller for 15-minute auth window
        if HAS_DISPENSE_CTRL:
            self.command_char.dispense_ctrl = DispenseController(
                api_base_url=API_BASE_URL,
                on_success=self.command_char._on_dispense_success,
                on_failure=self.command_char._on_dispense_failure,
            )
            log("DispenseController loaded ✓")
        else:
            self.command_char.dispense_ctrl = None
            log("⚠  DispenseController not available")


class CommandCharacteristic(Characteristic):
    """
    Receives byte commands from the Flutter app.

    Supported commands (first byte):
        0x01 UNLOCK            → face auth + unlock
        0x02 LOCK              → force-lock
        0x03 STATUS_REQUEST    → respond with STATUS_RESPONSE
        0x04 ACK               → no-op acknowledgement
        0x05 IDENTIFY          → blink LED
        0x06 BIND_SLOT         → bind patient to physical slot
        0x07 BARCODE_INCREMENT → barcode scanned, pill count +1
        0x08 COMMIT_MEDS       → finish loading slot
        0x09 TRIGGER_DISPENSE  → start 15-min dispense window
    """

    def __init__(self, bus, index, service):
        super().__init__(
            bus, index, COMMAND_CHAR_UUID,
            ["write", "write-without-response"],
            service,
        )
        self.notify_char = None  # set by DispenserService after construction

    def WriteValue(self, value, options):
        raw = bytes(value)
        if not raw:
            log("⚠  Empty command received — ignoring")
            return

        cmd = raw[0]
        payload = raw[1:]
        log(f"📥  Command received: 0x{cmd:02X}  payload={list(payload)}")

        if cmd == CMD_UNLOCK:
            self._handle_unlock(payload)
        elif cmd == CMD_LOCK:
            self._handle_lock(payload)
        elif cmd == CMD_STATUS_REQUEST:
            self._handle_status_request()
        elif cmd == CMD_ACK:
            log("✔  ACK received from mobile")
        elif cmd == CMD_IDENTIFY:
            self._handle_identify()
        elif cmd == CMD_BIND_SLOT:
            self._handle_bind_slot(payload)
        elif cmd == CMD_BARCODE_INCREMENT:
            self._handle_barcode_increment(payload)
        elif cmd == CMD_COMMIT_MEDS:
            self._handle_commit_meds(payload)
        elif cmd == CMD_TRIGGER_DISPENSE:
            self._handle_trigger_dispense(payload)
        else:
            log(f"⚠  Unknown command: 0x{cmd:02X}")

    # ── Command handlers ────────────────────────────────────────────────────────

    def _handle_unlock(self, payload):
        log("🔓  UNLOCK command received — starting face authentication...")

        if not FACE_AUTH_AVAILABLE:
            log("⚠  face_auth_headless not found — falling back to bridge test mode")
            def _deferred_ack():
                self._send_event(EVT_COMMAND_ACK)
                log("📤  COMMAND_ACK [0xA5] notification sent to mobile (bridge test)")
                return False
            GLib.timeout_add(200, _deferred_ack)
            return

        def _auth_worker():
            try:
                result = authenticate_user()
                # face_auth_headless.authenticate_user() returns a dict (same as dispense_controller)
                if isinstance(result, dict) and result.get("status") == "success":
                    patient_id = result["patient_id"]
                    name = result.get("name", "Unknown")
                    score = float(result.get("score", 0.0))
                    if score >= FACE_SCORE_THRESHOLD:
                        GLib.idle_add(self._on_auth_success, patient_id, name, score)
                    else:
                        GLib.idle_add(
                            self._on_auth_failure,
                            f"Low confidence: {name} score={score:.2f}",
                        )
                elif isinstance(result, dict):
                    reason = result.get("reason", "unknown")
                    GLib.idle_add(self._on_auth_failure, f"Auth failed: {reason}")
                else:
                    GLib.idle_add(
                        self._on_auth_failure,
                        "Unexpected auth return type (expected dict from face_auth_headless)",
                    )
            except Exception as e:
                GLib.idle_add(self._on_auth_failure, f"Error: {e}")

        thread = threading.Thread(target=_auth_worker, daemon=True)
        thread.start()

    def _on_auth_success(self, patient_id, name, score):
        msg = f"ACCESS GRANTED: {name} (score: {score:.2f})"
        log("╔" + "═" * (len(msg) + 4) + "╗")
        log("║  " + msg + "  ║")
        log("╚" + "═" * (len(msg) + 4) + "╝")
        self._send_event(EVT_COMMAND_ACK)
        log("📤  COMMAND_ACK [0xA5] → mobile (door unlocked)")
        return False

    def _on_auth_failure(self, reason):
        log(f"🚫  AUTH DENIED — {reason}")
        self._send_event_raw([EVT_HARDWARE_ERROR, ERR_AUTH_FAILED])
        log(f"📤  HARDWARE_ERROR [0xA3, 0x{ERR_AUTH_FAILED:02X}] → mobile (auth failed)")
        return False

    def _handle_lock(self, payload):
        log("🔒  LOCK command received — locking dispenser")

        def _deferred_ack():
            self._send_event(EVT_COMMAND_ACK)
            log("📤  COMMAND_ACK [0xA5] sent to mobile")
            return False

        GLib.timeout_add(200, _deferred_ack)

    def _handle_status_request(self):
        log("📊  STATUS_REQUEST received — sending status...")

        battery_level = 87
        is_online = 1
        remaining_pills = 14

        def _deferred_status():
            status_payload = [
                EVT_STATUS_RESPONSE,
                battery_level,
                is_online,
                remaining_pills,
            ]
            self._send_event_raw(status_payload)
            log(f"📤  STATUS_RESPONSE sent: battery={battery_level}% "
                f"online={bool(is_online)} pills={remaining_pills}")
            return False

        GLib.timeout_add(200, _deferred_status)

    def _handle_identify(self):
        log("💡  IDENTIFY command — blinking LED...")

        def _deferred_ack():
            self._send_event(EVT_COMMAND_ACK)
            log("📤  COMMAND_ACK [0xA5] sent to mobile")
            return False

        GLib.timeout_add(200, _deferred_ack)

    def _handle_bind_slot(self, payload):
        if len(payload) < 37:
            log("⚠  BIND_SLOT: payload too short (need slot_id + 36-byte UUID)")
            def _err():
                self._send_event_raw([EVT_HARDWARE_ERROR, ERR_SLOT_NOT_BOUND])
                return False
            GLib.timeout_add(200, _err)
            return

        slot_id = payload[0]
        patient_id = bytes(payload[1:37]).decode("utf-8", errors="replace")
        log(f"📌  BIND_SLOT: slot={slot_id} → patient={patient_id}")

        try:
            _db_bind_slot(slot_id, patient_id)
            log(f"📌  Local DB: slot {slot_id} bound to {patient_id[:8]}...")
        except Exception as e:
            log(f"❌  Local DB error: {e}")
            def _err():
                self._send_event_raw([EVT_HARDWARE_ERROR, ERR_SLOT_NOT_BOUND])
                return False
            GLib.timeout_add(200, _err)
            return

        def _api_and_ack():
            _api_update_medication_slot(patient_id, slot_id)
            GLib.idle_add(self._send_event, EVT_COMMAND_ACK)
            log("📤  COMMAND_ACK [0xA5] → mobile (slot bound)")

        threading.Thread(target=_api_and_ack, daemon=True).start()

    def _handle_barcode_increment(self, payload):
        if len(payload) < 1:
            log("⚠  BARCODE_INCREMENT: missing slot_id")
            def _err():
                self._send_event_raw([EVT_HARDWARE_ERROR, ERR_SLOT_NOT_BOUND])
                return False
            GLib.timeout_add(200, _err)
            return

        slot_id = payload[0]
        binding = _db_get_binding(slot_id)
        if binding is None:
            log(f"⚠  BARCODE_INCREMENT: slot {slot_id} not bound to any patient")
            def _err():
                self._send_event_raw([EVT_HARDWARE_ERROR, ERR_SLOT_NOT_BOUND])
                return False
            GLib.timeout_add(200, _err)
            return

        new_count = _db_increment_count(slot_id)
        log(f"📦  BARCODE_INCREMENT: slot={slot_id} → count={new_count}")

        def _deferred_ack():
            self._send_event(EVT_COMMAND_ACK)
            log(f"📤  COMMAND_ACK [0xA5] → mobile (count={new_count})")
            return False

        GLib.timeout_add(200, _deferred_ack)

    def _handle_commit_meds(self, payload):
        if len(payload) < 1:
            log("⚠  COMMIT_MEDS: missing slot_id")
            def _err():
                self._send_event_raw([EVT_HARDWARE_ERROR, ERR_SLOT_NOT_BOUND])
                return False
            GLib.timeout_add(200, _err)
            return

        slot_id = payload[0]
        binding = _db_get_binding(slot_id)
        if binding is None:
            log(f"⚠  COMMIT_MEDS: slot {slot_id} not bound")
            def _err():
                self._send_event_raw([EVT_HARDWARE_ERROR, ERR_SLOT_NOT_BOUND])
                return False
            GLib.timeout_add(200, _err)
            return

        patient_id, pill_count, already_committed = binding
        if already_committed:
            log(f"⚠  COMMIT_MEDS: slot {slot_id} already committed")

        log(f"✅  COMMIT_MEDS: slot={slot_id} patient={patient_id[:8]}... pills={pill_count}")
        _db_mark_committed(slot_id)

        def _api_and_ack():
            _api_update_medication_slot(patient_id, slot_id, remaining_count=pill_count)
            GLib.idle_add(self._send_event, EVT_COMMAND_ACK)
            log(f"📤  COMMAND_ACK [0xA5] → mobile (slot {slot_id} committed, {pill_count} pills)")

        threading.Thread(target=_api_and_ack, daemon=True).start()

    def _handle_trigger_dispense(self, payload):
        if len(payload) < 36:
            log("⚠  TRIGGER_DISPENSE: payload too short (need 36-byte patient UUID)")
            def _err():
                self._send_event_raw([EVT_HARDWARE_ERROR, ERR_SLOT_NOT_BOUND])
                return False
            GLib.timeout_add(200, _err)
            return

        patient_id = bytes(payload[:36]).decode("utf-8", errors="replace")

        schedule_id = None
        slot_id     = None
        if len(payload) >= 37:
            slot_id = payload[36]
        if len(payload) >= 73:
            schedule_id = bytes(payload[37:73]).decode("utf-8", errors="replace")

        if slot_id is None:
            conn = sqlite3.connect(LOCAL_DB)
            row = conn.execute(
                "SELECT slot_id FROM slot_bindings WHERE patient_id = ? AND committed = 1",
                (patient_id,),
            ).fetchone()
            conn.close()
            if row:
                slot_id = row[0]
                log(f"💊  Resolved slot_id={slot_id} from local DB for patient {patient_id[:8]}...")
            else:
                log(f"⚠  No committed slot found for patient {patient_id[:8]}...")
                def _err():
                    self._send_event_raw([EVT_HARDWARE_ERROR, ERR_SLOT_NOT_BOUND])
                    return False
                GLib.timeout_add(200, _err)
                return

        log(f"💊  TRIGGER_DISPENSE: patient={patient_id[:8]}... slot={slot_id} schedule={schedule_id}")

        if self.dispense_ctrl is not None:
            self.dispense_ctrl.start_window(patient_id, schedule_id, slot_id)
            def _deferred_ack():
                self._send_event(EVT_COMMAND_ACK)
                log("📤  COMMAND_ACK [0xA5] → mobile (dispense window started)")
                return False
            GLib.timeout_add(200, _deferred_ack)
        else:
            log("⚠  DispenseController not available — sending error")
            def _deferred_err():
                self._send_event_raw([EVT_HARDWARE_ERROR, ERR_MOTOR_ERROR])
                return False
            GLib.timeout_add(200, _deferred_err)

    def _on_dispense_success(self, patient_id, name, score):
        log(f"💊  Dispense SUCCESS: {name} (score={score:.2f})")
        GLib.idle_add(self._send_event, EVT_COMMAND_ACK)

    def _on_dispense_failure(self, reason):
        log(f"💊  Dispense FAILED: {reason}")
        error_code = ERR_TIMEOUT if "Timeout" in reason else ERR_AUTH_FAILED
        GLib.idle_add(self._send_event_raw, [EVT_HARDWARE_ERROR, error_code])

    # ── Helpers ─────────────────────────────────────────────────────────────────

    def _send_event(self, event_byte):
        """Send a single-byte event via the Notify characteristic."""
        self._send_event_raw([event_byte])

    def _send_event_raw(self, byte_list):
        """Send a multi-byte event via the Notify characteristic."""
        if self.notify_char is None:
            log("⚠  NotifyChar not linked — cannot send event")
            return
        self.notify_char.send_notification(byte_list)


class NotifyCharacteristic(Characteristic):
    """
    Push-notification channel from the Raspberry Pi to the Flutter app.

    The mobile subscribes to this characteristic via StartNotify().
    When an event occurs (pill taken, error, status), the Pi calls
    send_notification() which emits a D-Bus PropertiesChanged signal
    that BlueZ forwards to the connected phone as a GATT notification.
    """

    def __init__(self, bus, index, service):
        super().__init__(
            bus, index, NOTIFY_CHAR_UUID,
            ["notify"],
            service,
        )
        self._notifying = False

    def StartNotify(self):
        if self._notifying:
            return
        self._notifying = True
        log("🔔  Mobile subscribed to notifications")

    def StopNotify(self):
        if not self._notifying:
            return
        self._notifying = False
        log("🔕  Mobile unsubscribed from notifications")

    def send_notification(self, byte_list):
        """Push a byte-array notification to the connected mobile device."""
        if not self._notifying:
            log("⚠  Not notifying — mobile has not subscribed yet")
            return

        value = dbus.Array([dbus.Byte(b) for b in byte_list], signature="y")
        self.PropertiesChanged(
            GATT_CHRC_IFACE,
            {"Value": value},
            [],
        )


# ═══════════════════════════════════════════════════════════════════════════════
# Registration helpers
# ═══════════════════════════════════════════════════════════════════════════════

def register_ad_cb():
    log("✅  Advertisement registered successfully")


def register_ad_error_cb(error):
    log(f"❌  Failed to register advertisement: {error}")
    mainloop.quit()


def register_app_cb():
    log("✅  GATT application registered successfully")


def register_app_error_cb(error):
    log(f"❌  Failed to register GATT application: {error}")
    mainloop.quit()


def find_adapter(bus):
    """Locate the BlueZ adapter object (typically /org/bluez/hci0)."""
    remote_om = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE_NAME, "/"),
        DBUS_OM_IFACE,
    )
    objects = remote_om.GetManagedObjects()

    for path, interfaces in objects.items():
        if GATT_MANAGER_IFACE in interfaces:
            return path

    return None


# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    global mainloop

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    adapter_path = find_adapter(bus)
    if adapter_path is None:
        log("❌  No BLE adapter found. Is Bluetooth enabled?")
        log("   Try: sudo bluetoothctl power on")
        sys.exit(1)

    log(f"🔌  Using adapter: {adapter_path}")

    # ── Set adapter properties ──────────────────────────────────────────────────
    adapter_props = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE_NAME, adapter_path),
        DBUS_PROP_IFACE,
    )
    try:
        adapter_props.Set("org.bluez.Adapter1", "Powered", dbus.Boolean(True))
    except dbus.exceptions.DBusException as e:
        log(f"❌  Adapter Powered=True başarısız: {e}")
        log("   BlueZ bu işlem için çoğu sistemde root ister.")
        log("   Deneyin:")
        log("     sudo python3 ble_server.py")
        log("   Ayrıca (gerekirse):")
        log("     sudo rfkill unblock bluetooth")
        log("     sudo bluetoothctl power on")
        sys.exit(1)
    try:
        adapter_props.Set("org.bluez.Adapter1", "Alias", dbus.String(DEVICE_NAME))
        log(f"📛  Adapter alias set to '{DEVICE_NAME}'")
    except dbus.exceptions.DBusException as e:
        log(f"⚠  Alias ayarlanamadı (BLE yine çalışabilir): {e}")

    # ── Register GATT application ───────────────────────────────────────────────
    service_manager = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE_NAME, adapter_path),
        GATT_MANAGER_IFACE,
    )

    app = Application(bus)
    dispenser_service = DispenserService(bus, 0)
    app.add_service(dispenser_service)

    service_manager.RegisterApplication(
        app.get_path(),
        {},
        reply_handler=register_app_cb,
        error_handler=register_app_error_cb,
    )

    # ── Register BLE advertisement ──────────────────────────────────────────────
    ad_manager = dbus.Interface(
        bus.get_object(BLUEZ_SERVICE_NAME, adapter_path),
        LE_ADVERTISING_MANAGER_IFACE,
    )

    advertisement = DispenserAdvertisement(bus, 0)

    ad_manager.RegisterAdvertisement(
        advertisement.get_path(),
        {},
        reply_handler=register_ad_cb,
        error_handler=register_ad_error_cb,
    )

    # ── Print summary ───────────────────────────────────────────────────────────
    log("")
    log("╔══════════════════════════════════════════════════════════════╗")
    log("║           SmartDrugDispenser BLE Server Running            ║")
    log("╠══════════════════════════════════════════════════════════════╣")
    log(f"║  Device Name : {DEVICE_NAME:<44}║")
    log(f"║  Service UUID: {SERVICE_UUID:<44}║")
    log(f"║  Command Char: {COMMAND_CHAR_UUID:<44}║")
    log(f"║  Notify Char : {NOTIFY_CHAR_UUID:<44}║")
    log("╠══════════════════════════════════════════════════════════════╣")
    log("║  Waiting for connections from Flutter app...               ║")
    log("║  Press Ctrl+C to stop.                                     ║")
    log("╚══════════════════════════════════════════════════════════════╝")
    log("")

    mainloop = GLib.MainLoop()

    try:
        mainloop.run()
    except KeyboardInterrupt:
        log("\n🛑  Shutting down BLE server...")
        mainloop.quit()


if __name__ == "__main__":
    main()
