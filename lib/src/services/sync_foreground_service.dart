import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Top-level entry point for the background isolate spawned by the foreground
/// service. Annotated with @pragma so the Dart VM keeps it alive in release
/// builds. The task handler itself does nothing — the service is used purely
/// to keep the host process alive while the sync runs in the main isolate.
@pragma('vm:entry-point')
void startSyncForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_SyncTaskHandler());
}

class _SyncTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Wraps [FlutterForegroundTask] with sync-specific helpers.
///
/// On iOS this is a no-op — background execution is handled by the OS
/// lifecycle and there is no foreground-service concept.
class SyncForegroundService {
  SyncForegroundService._();

  // Serialize platform notification updates so rapid shard ticks do not race
  // and overwrite each other out of order.
  static Future<void> _updateChain = Future<void>.value();
  static String _lastText = '';

  /// Call once at app startup (before [runApp]) to configure the service.
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'sia_sync',
        channelName: 'Sia Network Sync',
        channelDescription:
            'Shown while the app is syncing with the Sia network.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No periodic callback needed — sync runs in the main isolate.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Start the foreground service and show a persistent notification.
  ///
  /// Safe to call when the service is already running — returns immediately.
  static Future<void> start() async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) return;

    // Request notification permission on Android 13+ (API 33+). If the user
    // denies it, we still proceed — worst case the sync runs without a
    // visible notification and Android may kill the process sooner.
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    await FlutterForegroundTask.startService(
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Syncing with Sia',
      notificationText: 'Starting…',
      callback: startSyncForegroundTaskCallback,
    );
    _lastText = 'Starting…';
  }

  /// Update the notification text with the latest progress message.
  static Future<void> updateProgress(String text) async {
    if (!Platform.isAndroid) return;
    if (text == _lastText) return;
    _lastText = text;

    _updateChain = _updateChain.then((_) async {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(notificationText: text);
    });

    try {
      await _updateChain;
    } catch (_) {
      // Keep sync resilient if a notification update fails transiently.
    }
  }

  /// Stop the foreground service and dismiss its notification.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      // Let in-flight notification updates drain first so stop requests don't
      // race with pending updateService calls.
      await _updateChain.timeout(const Duration(seconds: 2));
    } catch (_) {}

    try {
      if (!await FlutterForegroundTask.isRunningService) return;

      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure &&
          await FlutterForegroundTask.isRunningService) {
        // One retry handles transient platform-side failures.
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {
      // Keep app flow resilient even if stopping the notification fails.
    } finally {
      _lastText = '';
      _updateChain = Future<void>.value();
    }
  }
}
