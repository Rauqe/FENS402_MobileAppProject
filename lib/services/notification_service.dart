import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'api_service.dart';

class NotificationService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  Future<void> initialize() async {
    try {
      // Request notification permission — may be denied on simulator or
      // if the user has disabled notifications for this app.
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        print('[FCM] Notification permission denied — skipping token setup.');
        return;
      }

      // Get FCM token and send to backend
      final token = await _messaging.getToken();
      if (token != null) {
        await _sendTokenToBackend(token);
      }

      // Send token again when refreshed
      _messaging.onTokenRefresh.listen(_sendTokenToBackend);

      // Handle notifications when app is in foreground
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        print('[FCM] Notification received: ${message.notification?.title}');
      });
    } catch (e) {
      // Notifications not supported (e.g. iOS Simulator) — non-fatal.
      print('[FCM] NotificationService init failed (non-fatal): $e');
    }
  }

  Future<void> _sendTokenToBackend(String token) async {
    try {
      await ApiService.registerFcmToken(token);
      print('[FCM] Token sent to backend: $token');
    } catch (e) {
      print('[FCM] Token not sent: $e');
    }
  }
}