import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../core/constants/ble_constants.dart';
import 'permission_service.dart';
import '../core/bridge_test_state.dart';

// ── Connection state enum ──────────────────────────────────────────────────────

enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  failed,
}

// ── Parsed event from the Raspberry Pi ────────────────────────────────────────

class BleReceivedEvent {
  final BleEvent event;

  /// Raw bytes after the event-type byte.  May be empty.
  final List<int> payload;

  const BleReceivedEvent(this.event, this.payload);

  @override
  String toString() =>
      'BleReceivedEvent(event: ${event.name}, payload: $payload)';
}

// ── BLEService ────────────────────────────────────────────────────────────────

/// Manages the full BLE lifecycle with the Raspberry Pi SmartDispenser.
///
/// The Raspberry Pi runs a Python BLE GATT server (e.g. using `bluez` + `dbus`)
/// that advertises the service UUID defined in [ble_constants.dart].  This class
/// handles scanning, connecting, sending commands, and receiving hardware events.
///
/// Usage:
/// ```dart
/// final ble = BLEService();
///
/// ble.connectionState.listen((state) { ... });
/// ble.receivedEvents.listen((event) { ... });
///
/// await ble.startScanAndConnect();
/// await ble.sendCommand(BleCommand.unlock);
///
/// ble.dispose();
/// ```
class BLEService {
  // ── Internal streams ────────────────────────────────────────────────────────

  final _connectionStateController =
      StreamController<BleConnectionState>.broadcast();
  final _receivedEventController =
      StreamController<BleReceivedEvent>.broadcast();

  /// Emits [BleConnectionState] updates as the connection lifecycle progresses.
  Stream<BleConnectionState> get connectionState =>
      _connectionStateController.stream;

  /// Emits parsed [BleReceivedEvent]s whenever the Raspberry Pi sends a notification.
  Stream<BleReceivedEvent> get receivedEvents =>
      _receivedEventController.stream;

  // ── Private state ────────────────────────────────────────────────────────────

  BluetoothDevice? _device;
  BluetoothCharacteristic? _commandChar;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;

  bool get isConnected => _device != null && _commandChar != null;

  // ── Public API ───────────────────────────────────────────────────────────────

  /// Scans for the SmartDispenser Raspberry Pi, then establishes a GATT connection.
  ///
  /// Steps:
  ///   1. Verify Bluetooth is on.
  ///   2. Scan for [kBleScanTimeout] filtering by advertised device name.
  ///   3. Connect to the first matching device.
  ///   4. Discover services & grab command + notify characteristics.
  ///   5. Subscribe to the notify characteristic.
  Future<void> startScanAndConnect() async {
    // ── Step 0: Request runtime permissions ────────────────────────────────
    final granted = await PermissionService.ensureBlePermissions();
    if (!granted) {
      _emit(BleConnectionState.failed);
      throw StateError(
          'Bluetooth permissions were denied. Please grant Bluetooth and '
          'Location permissions in your device Settings to use the dispenser.');
    }
    debugPrint('[BLEService] BLE permissions granted ✓');

    // ── Step 1: Verify Bluetooth adapter is on ────────────────────────────
    // adapterStateNow can return stale/unknown on cold start, so we
    // wait for the first real value from the stream (up to 4 s).
    final adapterState = await FlutterBluePlus.adapterState
        .where((s) => s != BluetoothAdapterState.unknown)
        .first
        .timeout(const Duration(seconds: 4),
            onTimeout: () => FlutterBluePlus.adapterStateNow);

    debugPrint('[BLEService] Adapter state: $adapterState');

    if (adapterState != BluetoothAdapterState.on) {
      _emit(BleConnectionState.failed);
      throw StateError(
          'Bluetooth is off. Please enable Bluetooth and try again.');
    }

    _emit(BleConnectionState.scanning);

    BluetoothDevice? found;

    final completer = Completer<BluetoothDevice?>();
    final scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final result in results) {
        if (result.device.platformName == kDeviceAdvertisedName ||
            result.advertisementData.advName == kDeviceAdvertisedName) {
          if (!completer.isCompleted) {
            completer.complete(result.device);
          }
          break;
        }
      }
    });

    FlutterBluePlus.startScan(timeout: kBleScanTimeout);

    found = await completer.future
        .timeout(kBleScanTimeout, onTimeout: () => null);

    await FlutterBluePlus.stopScan();
    scanSub.cancel();

    if (found == null) {
      _emit(BleConnectionState.failed);
      throw TimeoutException(
          'SmartDispenser not found. Make sure the Raspberry Pi is powered on '
          'and nearby with BLE advertising enabled.');
    }

    await _connectToDevice(found);
  }

  /// Sends a typed [BleCommand] to the Raspberry Pi.
  ///
  /// [extraPayload] is appended after the command byte (e.g. a session token).
  /// Throws [StateError] if not connected.
  Future<void> sendCommand(
    BleCommand command, {
    List<int>? extraPayload,
  }) async {
    if (_commandChar == null) {
      throw StateError(
        'BLE not connected. Call startScanAndConnect() first.',
      );
    }

    // Bridge-test flow:
    // When we send UNLOCK (0x01), immediately wait for Pi's COMMAND_ACK (0xA5)
    // notification and expose it via [BridgeTestState.verified].
    if (command == BleCommand.unlock) {
      BridgeTestState.reset();

      // Race-condition safe: create a temporary listener before writing,
      // but only accept the ACK after we start the unlock write.
      final bytes = command.toBytes(extraPayload);
      final completer = Completer<void>();
      bool accepting = false;
      StreamSubscription<BleReceivedEvent>? sub;

      sub = receivedEvents.listen((e) {
        if (accepting && e.event == BleEvent.commandAck && !completer.isCompleted) {
          completer.complete();
        }
      });

      try {
        accepting = true;

        await _commandChar!.write(
          bytes,
          withoutResponse: command == BleCommand.statusRequest,
        );

        await completer.future.timeout(const Duration(seconds: 8));

        debugPrint('✅ [BRIDGE TEST] Pi confirmed the command!');
        BridgeTestState.setVerified('✅ Bridge verified (0xA5 received)');
      } on TimeoutException {
        debugPrint('❌ [BRIDGE TEST] No 0xA5 ack received (timeout).');
        BridgeTestState.message.value = '❌ Bridge verification failed (timeout)';
      } finally {
        await sub.cancel();
      }

      return;
    }

    final bytes = command.toBytes(extraPayload);

    await _commandChar!.write(
      bytes,
      withoutResponse: command == BleCommand.statusRequest,
    );
  }

  /// Sends [BleCommand.statusRequest] and returns the Pi's status response
  /// (or times out after 5 s).
  Future<BleReceivedEvent> requestStatus() async {
    final responseFuture = receivedEvents
        .where((e) => e.event == BleEvent.statusResponse)
        .first
        .timeout(const Duration(seconds: 5));

    await sendCommand(BleCommand.statusRequest);
    return responseFuture;
  }

  // ── Admin / Dispense convenience methods ──────────────────────────────────

  /// Sends a command and waits for ACK (0xA5) or ERROR (0xA3).
  /// Returns true on ACK, throws on ERROR or timeout.
  Future<bool> _sendAndWaitAck(
    BleCommand command, {
    List<int>? payload,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final completer = Completer<bool>();
    StreamSubscription<BleReceivedEvent>? sub;

    sub = receivedEvents.listen((e) {
      if (completer.isCompleted) return;
      if (e.event == BleEvent.commandAck) {
        completer.complete(true);
      } else if (e.event == BleEvent.hardwareError) {
        final code = e.payload.isNotEmpty ? e.payload.first : 0;
        completer.completeError(
          StateError('Hardware error 0x${code.toRadixString(16)}'),
        );
      }
    });

    try {
      await sendCommand(command, extraPayload: payload);
      return await completer.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }

  /// Bind a patient to a physical slot on the dispenser.
  /// Payload: [slot_id: 1B] [patient_id: 36B UTF-8 UUID]
  Future<bool> sendBindSlot(int slotId, String patientId) {
    final payload = [slotId, ...patientId.codeUnits.take(36)];
    return _sendAndWaitAck(BleCommand.bindSlot, payload: payload);
  }

  /// Notify Pi that a barcode was scanned (pill count +1 for slot).
  Future<bool> sendBarcodeIncrement(int slotId) {
    return _sendAndWaitAck(BleCommand.barcodeIncrement, payload: [slotId]);
  }

  /// Commit the medication-loading session for a slot.
  Future<bool> sendCommitMeds(int slotId) {
    return _sendAndWaitAck(BleCommand.commitMeds, payload: [slotId]);
  }

  /// Start the 15-minute dispense window for a patient.
  Future<bool> sendTriggerDispense(String patientId, {int? slotId}) {
    final bytes = <int>[...patientId.codeUnits.take(36)];
    if (slotId != null) bytes.add(slotId);
    return _sendAndWaitAck(
      BleCommand.triggerDispense,
      payload: bytes,
      timeout: const Duration(seconds: 15),
    );
  }

  /// Disconnects from the current device and cleans up subscriptions.
  Future<void> disconnect() async {
    await _notifySubscription?.cancel();
    await _connectionSubscription?.cancel();
    await _device?.disconnect();
    _reset();
    _emit(BleConnectionState.disconnected);
  }

  /// Release all resources. Call this in the widget/service owner's dispose().
  void dispose() {
    disconnect();
    _connectionStateController.close();
    _receivedEventController.close();
  }

  // ── Private helpers ──────────────────────────────────────────────────────────

  Future<void> _connectToDevice(BluetoothDevice device) async {
    _emit(BleConnectionState.connecting);
    _device = device;

    try {
      await device.connect(
        timeout: kBleConnectTimeout,
        autoConnect: false,
      );
    } catch (e) {
      _reset();
      _emit(BleConnectionState.failed);
      rethrow;
    }

    _connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _reset();
        _emit(BleConnectionState.disconnected);
      }
    });

    await _discoverAndBindCharacteristics(device);
    _emit(BleConnectionState.connected);
  }

  Future<void> _discoverAndBindCharacteristics(BluetoothDevice device) async {
    final services = await device.discoverServices();
    debugPrint('[BLEService] Discovered ${services.length} services');

    BluetoothService? dispenserService;
    for (final svc in services) {
      final svcUuid = svc.serviceUuid.toString().toUpperCase();
      debugPrint('[BLEService]   service: $svcUuid');
      if (svcUuid == kDispenserServiceUuid.toUpperCase()) {
        dispenserService = svc;
      }
    }

    if (dispenserService == null) {
      await device.disconnect();
      _reset();
      _emit(BleConnectionState.failed);
      throw StateError(
          'Dispenser GATT service not found. Check that the Raspberry Pi '
          'BLE server is running and the UUID in ble_constants.dart matches.');
    }

    debugPrint('[BLEService] Found dispenser service ✓');

    for (final char in dispenserService.characteristics) {
      final uuid = char.characteristicUuid.toString().toUpperCase();
      debugPrint('[BLEService]   char: $uuid  props: ${char.properties}');
      if (uuid == kCommandCharUuid.toUpperCase()) {
        _commandChar = char;
      } else if (uuid == kNotifyCharUuid.toUpperCase()) {
        _notifyChar = char;
      }
    }

    if (_commandChar == null || _notifyChar == null) {
      await device.disconnect();
      _reset();
      _emit(BleConnectionState.failed);
      throw StateError(
          'Required BLE characteristics not found. Check UUIDs in '
          'ble_constants.dart match the Pi BLE server configuration.');
    }

    debugPrint('[BLEService] Command char ✓  Notify char ✓');
    debugPrint('[BLEService] Subscribing to notifications...');
    await _notifyChar!.setNotifyValue(true);
    debugPrint('[BLEService] Notification subscription active ✓');
    _notifySubscription =
        _notifyChar!.onValueReceived.listen(_handleNotification);
  }

  void _handleNotification(List<int> bytes) {
    debugPrint('[BLEService] 📩 Raw notification received: $bytes');
    if (bytes.isEmpty) return;

    final event = BleEvent.fromByte(bytes.first);
    final payload = bytes.sublist(1);
    debugPrint('[BLEService] 📩 Parsed event: ${event.name} (0x${bytes.first.toRadixString(16)})');
    _receivedEventController.add(BleReceivedEvent(event, payload));
  }

  void _reset() {
    _notifySubscription?.cancel();
    _connectionSubscription?.cancel();
    _device = null;
    _commandChar = null;
    _notifyChar = null;
  }

  void _emit(BleConnectionState state) {
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(state);
    }
  }
}
