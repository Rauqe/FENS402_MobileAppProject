import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Centralised runtime permission handler.
///
/// Android and iOS require different permission sets for BLE scanning.
/// This class encapsulates all platform-specific logic so the rest of
/// the codebase simply calls:
///
/// ```dart
/// final ok = await PermissionService.ensureBlePermissions();
/// if (!ok) { /* show error / settings redirect */ }
/// ```
class PermissionService {
  PermissionService._();

  // ── BLE permissions ──────────────────────────────────────────────────────────

  /// Requests all permissions required for BLE scanning and connecting.
  ///
  /// Returns `true` if every required permission was granted.
  /// Returns `false` if any permission was denied or permanently denied.
  ///
  /// Platform behaviour:
  ///   **Android 12+ (API 31+):** BLUETOOTH_SCAN + BLUETOOTH_CONNECT
  ///   **Android < 12:**          ACCESS_FINE_LOCATION (needed for BLE scan)
  ///   **iOS:**                   Bluetooth (automatically prompted by system)
  static Future<bool> ensureBlePermissions() async {
    if (Platform.isAndroid) {
      return _requestAndroidBlePermissions();
    } else if (Platform.isIOS) {
      return _requestIosBlePermissions();
    }
    return true;
  }

  // ── Camera permissions ───────────────────────────────────────────────────────

  /// Requests camera permission (needed for Face-ID authentication).
  static Future<bool> ensureCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isGranted) return true;

    debugPrint('[PermissionService] Camera permission denied: $status');
    return false;
  }

  // ── Combined: BLE + Camera (for the unlock flow) ────────────────────────────

  /// Requests both BLE and camera permissions in one call.
  /// Used before the Face-ID → BLE unlock pipeline.
  static Future<bool> ensureAllPermissions() async {
    final ble = await ensureBlePermissions();
    final camera = await ensureCameraPermission();
    return ble && camera;
  }

  // ── Check without requesting ─────────────────────────────────────────────────

  /// Returns true if all BLE permissions are already granted (no popup).
  static Future<bool> areBlePermissionsGranted() async {
    if (Platform.isAndroid) {
      final scan = await Permission.bluetoothScan.isGranted;
      final connect = await Permission.bluetoothConnect.isGranted;
      final location = await Permission.locationWhenInUse.isGranted;
      return (scan && connect) || location;
    } else if (Platform.isIOS) {
      return await Permission.bluetooth.isGranted;
    }
    return true;
  }

  // ── Open app settings (when permanently denied) ──────────────────────────────

  /// Opens the OS-level app settings page so the user can manually
  /// re-enable a permanently denied permission.
  static Future<bool> openSettings() async {
    return openAppSettings();
  }

  // ── Private: Android ─────────────────────────────────────────────────────────

  static Future<bool> _requestAndroidBlePermissions() async {
    // Android 12+ (API 31+): BLUETOOTH_SCAN + BLUETOOTH_CONNECT
    // Android < 12: ACCESS_FINE_LOCATION is required for BLE scanning.
    // We request all of them; the OS will silently ignore permissions
    // that don't apply to the running API level.

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    for (final entry in statuses.entries) {
      debugPrint(
          '[PermissionService] ${entry.key}: ${entry.value}');

      if (entry.value.isPermanentlyDenied) {
        debugPrint(
            '[PermissionService] ${entry.key} permanently denied — '
            'user must enable it in Settings.');
      }
    }

    // On Android 12+, scan + connect are sufficient.
    // On Android < 12, location is required instead.
    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk =
        statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    final locationOk =
        statuses[Permission.locationWhenInUse]?.isGranted ?? false;

    // Either the new BT permissions work, or fall back to location.
    return (scanOk && connectOk) || locationOk;
  }

  // ── Private: iOS ─────────────────────────────────────────────────────────────

  static Future<bool> _requestIosBlePermissions() async {
    final btStatus = await Permission.bluetooth.request();
    debugPrint('[PermissionService] iOS Bluetooth: $btStatus');

    final locStatus = await Permission.locationWhenInUse.request();
    debugPrint('[PermissionService] iOS Location: $locStatus');

    if (btStatus.isPermanentlyDenied || locStatus.isPermanentlyDenied) {
      debugPrint(
          '[PermissionService] One or more permissions permanently denied — '
          'user must enable them in Settings.');
    }

    return btStatus.isGranted && locStatus.isGranted;
  }
}
