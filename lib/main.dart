import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/app.dart';
import 'src/bridge/sia_bridge.dart';
import 'src/services/calendar_file_open_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SiaBridge.init();
  await CalendarFileOpenService.instance.initialize();
  runApp(const ProviderScope(child: SiCalApp()));
}
