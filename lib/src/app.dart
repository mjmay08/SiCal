import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'repositories/calendar_repository.dart';
import 'services/event_notification_service.dart';
import 'services/auth_service.dart';
import 'ui/screens/calendar_screen.dart';
import 'ui/screens/event_detail_screen.dart';
import 'ui/screens/onboarding_screen.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

class SiCalApp extends StatelessWidget {
  const SiCalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
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

class _StartupGate extends ConsumerStatefulWidget {
  const _StartupGate();

  @override
  ConsumerState<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<_StartupGate> {
  bool _bootstrappedNotifications = false;
  String? _pendingOpenEventId;
  StreamSubscription<String>? _tapSubscription;

  @override
  void initState() {
    super.initState();
    _tapSubscription = EventNotificationService.notificationTapStream.listen((
      eventId,
    ) {
      _pendingOpenEventId = eventId;
      _maybeOpenPendingEvent();
    });
  }

  @override
  void dispose() {
    _tapSubscription?.cancel();
    super.dispose();
  }

  Future<void> _maybeOpenPendingEvent() async {
    final eventId = _pendingOpenEventId;
    if (eventId == null || !mounted) return;

    final connected = ref
        .read(authStateProvider)
        .when(
          data: (isConnected) => isConnected,
          loading: () => false,
          error: (_, __) => false,
        );
    if (!connected) return;

    final repo = await ref.read(calendarRepositoryProvider.future);
    final event = repo.getEventById(eventId);
    if (!mounted || event == null) return;

    _pendingOpenEventId = null;
    final navigator = appNavigatorKey.currentState;
    if (navigator == null || !navigator.mounted) return;

    navigator.push(
      MaterialPageRoute(builder: (_) => EventDetailScreen(event: event)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (isConnected) {
        final launchPayload =
            EventNotificationService.consumePendingTapPayload();
        if (launchPayload != null) {
          _pendingOpenEventId = launchPayload;
        }

        if (isConnected && !_bootstrappedNotifications) {
          _bootstrappedNotifications = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            final db = await ref.read(appDatabaseProvider.future);
            await EventNotificationService.rescheduleAll(db);
            await _maybeOpenPendingEvent();
          });
        } else if (isConnected && _pendingOpenEventId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _maybeOpenPendingEvent();
          });
        }
        return isConnected ? const CalendarScreen() : const OnboardingScreen();
      },
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, __) => const OnboardingScreen(),
    );
  }
}
