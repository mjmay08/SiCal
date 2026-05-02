import 'package:flutter/material.dart';
import 'src/app.dart';
import 'src/bridge/sia_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SiaBridge.init();
  runApp(const SiCalApp());
}
