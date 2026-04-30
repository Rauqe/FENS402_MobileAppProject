import 'package:flutter/foundation.dart';

/// Global bridge-test state shared between the BLE layer and the UI.
///
/// - The BLE layer sets [verified] to `true` once it observes
///   [BleEvent.commandAck] (0xA5) right after an unlock (0x01) command.
/// - The UI can listen to [verified] and show a banner to the user.
class BridgeTestState {
  BridgeTestState._();

  /// Whether the Pi confirmed the unlock command via BLE notification (0xA5).
  static final ValueNotifier<bool> verified = ValueNotifier<bool>(false);

  /// Human-readable message to show in the UI/debug.
  static final ValueNotifier<String> message = ValueNotifier<String>('');

  static void reset() {
    verified.value = false;
    message.value = '';
  }

  static void setVerified(String msg) {
    verified.value = true;
    message.value = msg;
  }
}

