import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Callback when a barcode is detected.
typedef OnBarcodeScanned = void Function(String barcode);

/// Bottom sheet with a live camera barcode scanner.
///
/// Each detected barcode triggers [onScanned] once (debounced).
/// The sheet stays open so the caregiver can scan multiple pills.
class BarcodeScannerSheet extends StatefulWidget {
  final OnBarcodeScanned onScanned;
  final int scannedCount;
  final bool loading;

  const BarcodeScannerSheet({
    super.key,
    required this.onScanned,
    this.scannedCount = 0,
    this.loading = false,
  });

  @override
  State<BarcodeScannerSheet> createState() => _BarcodeScannerSheetState();
}

class _BarcodeScannerSheetState extends State<BarcodeScannerSheet> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  String? _lastBarcode;
  DateTime _lastScanTime = DateTime(2000);

  void _onDetect(BarcodeCapture capture) {
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final code = barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    // Debounce: ignore same barcode within 2 seconds
    final now = DateTime.now();
    if (code == _lastBarcode &&
        now.difference(_lastScanTime).inMilliseconds < 2000) {
      return;
    }

    _lastBarcode = code;
    _lastScanTime = now;
    widget.onScanned(code);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Camera preview
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 220,
            width: double.infinity,
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Scan count indicator
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.medication_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.scannedCount} pills scanned',
                style: theme.textTheme.titleMedium,
              ),
              if (widget.loading) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
        if (_lastBarcode != null) ...[
          const SizedBox(height: 8),
          Text(
            'Last: $_lastBarcode',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ],
    );
  }
}
