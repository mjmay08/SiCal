import 'package:flutter/material.dart';

class SiCalApp extends StatelessWidget {
  const SiCalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SiCal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1ED660),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(
          child: Text(
            'SiCal',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}
