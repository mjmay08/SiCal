import 'package:flutter/material.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'SiCal',
          style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
