import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/app.dart';
import 'src/bridge/sia_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SiaBridge.init();
  runApp(const ProviderScope(child: SiCalApp()));
}
