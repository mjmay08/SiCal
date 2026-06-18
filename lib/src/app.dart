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
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF12A150),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF12A150),
      brightness: Brightness.dark,
    );

    ThemeData buildTheme(ColorScheme scheme) {
      final base = ThemeData(colorScheme: scheme, useMaterial3: true);

      return base.copyWith(
        scaffoldBackgroundColor: scheme.surface,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        appBarTheme: AppBarTheme(
          backgroundColor: scheme.surface,
          foregroundColor: scheme.onSurface,
          elevation: 0,
          centerTitle: false,
          scrolledUnderElevation: 0,
          titleTextStyle: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.1,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerLow,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: scheme.primary, width: 1.6),
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: scheme.outlineVariant.withAlpha(140)),
          ),
          color: scheme.surfaceContainerLow,
          margin: EdgeInsets.zero,
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: scheme.inverseSurface,
          contentTextStyle: TextStyle(color: scheme.onInverseSurface),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        chipTheme: base.chipTheme.copyWith(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          elevation: 1,
          foregroundColor: scheme.onPrimary,
          backgroundColor: scheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant.withAlpha(170),
          thickness: 1,
          space: 1,
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
            TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          },
        ),
      );
    }

    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'SiCal',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        return SafeArea(
          top: false,
          left: false,
          right: false,
          bottom: true,
          child: child,
        );
      },
      theme: buildTheme(lightScheme),
      darkTheme: buildTheme(darkScheme),
      themeMode: ThemeMode.system,
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
  bool _handledMissingAppKey = false;
  bool _handlingMissingAppKey = false;
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

  Future<void> _maybeClearLocalCacheForMissingAppKey() async {
    if (_handledMissingAppKey || _handlingMissingAppKey) return;
    _handlingMissingAppKey = true;
    try {
      final auth = ref.read(authServiceProvider);
      final hasStoredAppKey = await auth.hasStoredAppKey();
      if (!hasStoredAppKey) {
        final db = await ref.read(appDatabaseProvider.future);
        db.clearAllTables();
        await EventNotificationService.clearAll();
        ref.invalidate(eventsForDayProvider);
      }
      _handledMissingAppKey = true;
    } finally {
      _handlingMissingAppKey = false;
    }
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

        if (!isConnected && !_handledMissingAppKey && !_handlingMissingAppKey) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _maybeClearLocalCacheForMissingAppKey();
          });
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
