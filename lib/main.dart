import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'src/app.dart';
import 'src/bridge/sia_bridge.dart';
import 'src/services/calendar_file_open_service.dart';
import 'src/services/sync_foreground_service.dart';
import 'src/services/timezone_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Required for two-way communication between the foreground task's
  // background isolate and the main isolate (even though we only use the
  // service to keep the process alive).
  FlutterForegroundTask.initCommunicationPort();
  SyncForegroundService.init();
  TimezoneService.initialize();
  await SiaBridge.init();
  await CalendarFileOpenService.instance.initialize();
  await SyncForegroundService.startIosBackgroundSyncScheduler();
  runApp(const ProviderScope(child: SiCalApp()));
}
