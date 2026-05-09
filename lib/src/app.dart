import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/auth_service.dart';
import 'ui/screens/calendar_screen.dart';
import 'ui/screens/onboarding_screen.dart';

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
      home: const _StartupGate(),
    );
  }
}

class _StartupGate extends ConsumerWidget {
  const _StartupGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (isConnected) =>
          isConnected ? const CalendarScreen() : const OnboardingScreen(),
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, __) => const OnboardingScreen(),
    );
  }
}
