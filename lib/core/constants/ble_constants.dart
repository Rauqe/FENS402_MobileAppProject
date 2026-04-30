/// BLE constants shared between [BLEService] and the Raspberry Pi BLE daemon.
///
/// IMPORTANT: These UUIDs must match the GATT service/characteristic UUIDs
/// registered by the Python BLE server running on the Raspberry Pi.
///
/// How to generate your own UUIDs:
///   dart run uuid   — or any RFC 4122 UUID generator.
///
/// How to change them:
///   1. Update the values here.
///   2. Update the corresponding UUIDs in the Pi's Python BLE server.
library ble_constants;

// ── GATT Service UUID ──────────────────────────────────────────────────────────
/// Primary BLE service UUID advertised by the Raspberry Pi.
const String kDispenserServiceUuid = '12345678-1234-1234-1234-1234567890AB';

// ── GATT Characteristic UUIDs ──────────────────────────────────────────────────
/// Write-without-response characteristic: mobile → Raspberry Pi commands.
const String kCommandCharUuid = 'ABCD1234-AB12-AB12-AB12-ABCDEF123456';

/// Notify characteristic: Raspberry Pi → mobile events (pill taken, error, ack).
const String kNotifyCharUuid = 'DCBA4321-DC43-DC43-DC43-DCBA98765432';

// ── Device identification ──────────────────────────────────────────────────────
/// The advertised BLE device name set by the Pi. Used to filter scan results.
const String kDeviceAdvertisedName = 'SmartDispenser';

/// Connection timeout before giving up and emitting [BleConnectionState.failed].
const Duration kBleConnectTimeout = Duration(seconds: 10);

/// How long to scan for devices before stopping automatically.
const Duration kBleScanTimeout = Duration(seconds: 15);

// ── Command bytes (mobile → Raspberry Pi) ──────────────────────────────────────
/// Single-byte command protocol. The Pi's BLE daemon reads the first byte and
/// dispatches GPIO / motor actions accordingly. Extra payload bytes follow if
/// the command needs them.
enum BleCommand {
  /// Request the dispenser to open the current day's compartment.
  unlock(0x01),

  /// Force-lock the dispenser immediately.
  lock(0x02),

  /// Ask the Pi for its current status (battery, sensor readings, etc.).
  statusRequest(0x03),

  /// Acknowledge receipt of an event — prevents duplicate processing.
  ack(0x04),

  /// Trigger the LED indicator on the dispenser (for physical identification).
  identify(0x05),

  /// Bind a patient to a physical slot on the dispenser wheel.
  /// Payload: [slot_id: 1 byte] [patient_id: 36 byte UTF-8 UUID]
  bindSlot(0x06),

  /// Notify Pi that a barcode was scanned (pill count +1 for the given slot).
  /// Payload: [slot_id: 1 byte]
  barcodeIncrement(0x07),

  /// Commit the medication-loading session for a slot (admin done filling).
  /// Payload: [slot_id: 1 byte]
  commitMeds(0x08),

  /// Start the 15-minute dispensing window (face-auth + motor).
  /// Payload: [patient_id: 36 byte UTF-8 UUID]
  triggerDispense(0x09);

  const BleCommand(this.byte);
  final int byte;

  /// Converts the command (+ optional extra payload) to the byte list that
  /// will be written to the BLE characteristic.
  List<int> toBytes([List<int>? payload]) {
    return [byte, ...?payload];
  }
}

// ── Event bytes (Raspberry Pi → mobile, received via Notify) ──────────────────
/// Events pushed by the Pi's BLE daemon through the notify characteristic.
enum BleEvent {
  /// Pill was physically removed from the compartment (IR + load-cell confirmed).
  pillTaken(0xA1),

  /// Compartment was opened but no pill was removed within the expected window.
  missedDose(0xA2),

  /// Generic hardware or sensor error. Byte[1] carries an error code.
  hardwareError(0xA3),

  /// Response to [BleCommand.statusRequest]. Remaining bytes = status payload.
  statusResponse(0xA4),

  /// The Pi acknowledged the last command it received.
  commandAck(0xA5),

  /// Unknown / unrecognised event byte.
  unknown(0xFF);

  const BleEvent(this.byte);
  final int byte;

  static BleEvent fromByte(int byte) {
    return BleEvent.values.firstWhere(
      (e) => e.byte == byte,
      orElse: () => BleEvent.unknown,
    );
  }
}
