import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'dart:async' show unawaited;
import '../../repositories/calendar_repository.dart';
import '../../services/calendar_file_open_service.dart';
import '../../services/incoming_calendar_intent_handler.dart';
import '../../services/sync_foreground_service.dart';
import '../../services/timezone_service.dart';
import '../../models/event.dart';
import '../widgets/sync_status_banner.dart';
import 'event_detail_screen.dart';
import 'event_form_screen.dart';
import 'settings_screen.dart';

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen>
    with WidgetsBindingObserver {
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Map<DateTime, List<CalendarEvent>> _eventsByDay = {};
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedDay = _focusedDay;
    // Load events for the initial month so markers appear immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadVisibleEvents());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CalendarFileOpenService.instance.setListener(_importIncomingCalendarText);
    });
    // On a fresh install or after restoring from a recovery phrase the local
    // database has no sync cursor, meaning we have never pulled from the
    // network.  Kick off an automatic sync so remote events appear without the
    // user having to tap the sync button.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoSync());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CalendarFileOpenService.instance.clearListener();
    super.dispose();
  }

  /// Trigger a silent sync when the user backgrounds the app so that any
  /// pending dirty events are uploaded even if they forgot to tap Sync.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _sync(silent: true);
    }
  }

  /// Normalise to midnight for event-day lookup.
  DateTime _normalizeDay(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Load all visible events for the current month into the marker map.
  Future<void> _loadVisibleEvents() async {
    // Extend the query window by ±1 day at both ends so that events whose
    // stored wall-clock time falls outside the month boundary (because they
    // are stored in UTC but displayed in a behind-UTC device timezone) still
    // appear on the correct day.
    final first = DateTime(
      _focusedDay.year,
      _focusedDay.month,
      1,
    ).subtract(const Duration(days: 1));
    final last = DateTime(
      _focusedDay.year,
      _focusedDay.month + 1,
      0,
      23,
      59,
    ).add(const Duration(days: 1));
    final repo = await ref.read(calendarRepositoryProvider.future);
    final events = repo.getEventsInRange(first, last);
    // Await the first emission so we never bucket events with a null timezone.
    String? deviceTz;
    try {
      deviceTz = await ref.read(deviceTimezoneProvider.future);
    } catch (_) {}
    final map = <DateTime, List<CalendarEvent>>{};
    for (final e in events) {
      final day = _normalizeDay(effectiveDisplayStart(e, deviceTz));
      (map[day] ??= []).add(e);
    }
    if (mounted) setState(() => _eventsByDay = map);
  }

  @override
  Widget build(BuildContext context) {
    // Reload markers whenever the device timezone changes (e.g. app resume
    // in a different timezone).
    ref.listen<AsyncValue<String>>(deviceTimezoneProvider, (prev, next) {
      if (next.hasValue && next.value != prev?.value) _loadVisibleEvents();
    });

    final eventsAsync = ref.watch(
      eventsForDayProvider(_selectedDay ?? _focusedDay),
    );
    final calendarLookup = ref.watch(calendarLookupProvider).value ?? const {};
    final dirtyCount = ref
        .watch(appDatabaseProvider)
        .maybeWhen(data: (db) => db.getDirtyEvents().length, orElse: () => 0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SiCal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.today),
            onPressed: () => setState(() {
              _focusedDay = DateTime.now();
              _selectedDay = _focusedDay;
            }),
          ),
          IconButton(
            icon: Badge(
              isLabelVisible: dirtyCount > 0,
              backgroundColor: Colors.amber,
              smallSize: 8,
              child: const Icon(Icons.sync),
            ),
            tooltip: dirtyCount > 0
                ? '$dirtyCount event(s) pending upload — tap to sync'
                : 'Sync',
            onPressed: _sync,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final didChange = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              if (didChange == true) {
                ref.invalidate(eventsForDayProvider);
                _loadVisibleEvents();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Import complete')),
                  );
                }
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncStatusBanner(),
          TableCalendar<CalendarEvent>(
            firstDay: DateTime(2020),
            lastDay: DateTime(2030),
            focusedDay: _focusedDay,
            calendarFormat: _calendarFormat,
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            eventLoader: (day) => _eventsByDay[_normalizeDay(day)] ?? [],
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                _selectedDay = selectedDay;
                _focusedDay = focusedDay;
              });
            },
            onFormatChanged: (format) =>
                setState(() => _calendarFormat = format),
            onPageChanged: (focusedDay) {
              _focusedDay = focusedDay;
              _loadVisibleEvents();
            },
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, events) {
                if (events.isEmpty) return const SizedBox.shrink();
                final colors = <Color>[];
                for (final item in events.cast<CalendarEvent>()) {
                  final color = _calendarColor(
                    calendarLookup[item.calendarId]?.color,
                    fallback: Theme.of(context).colorScheme.primary,
                  );
                  if (!colors.contains(color)) colors.add(color);
                }
                final preview = colors.take(3).toList();
                return Padding(
                  padding: const EdgeInsets.only(top: 30),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final color in preview)
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            calendarStyle: CalendarStyle(
              todayDecoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withAlpha(100),
                shape: BoxShape.circle,
              ),
              selectedDecoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: eventsAsync.when(
              data: (events) => events.isEmpty
                  ? const Center(child: Text('No events'))
                  : ListView.builder(
                      itemCount: events.length,
                      itemBuilder: (context, index) {
                        final event = events[index];
                        return _EventListTile(
                          event: event,
                          onTap: () => _openEventDetail(event),
                        );
                      },
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createEvent(),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _createEvent() async {
    final selectedCalendarId =
        ref.read(selectedCalendarIdProvider) ?? kDefaultCalendarId;
    final result = await Navigator.of(context).push<CalendarEvent>(
      MaterialPageRoute(
        builder: (_) =>
            EventFormScreen(initialDate: _selectedDay ?? _focusedDay),
      ),
    );
    if (result != null) {
      final repo = await ref.read(calendarRepositoryProvider.future);
      repo.createEvent(result.copyWith(calendarId: selectedCalendarId));
      ref.invalidate(eventsForDayProvider);
      _loadVisibleEvents();
    }
  }

  void _openEventDetail(CalendarEvent event) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => EventDetailScreen(event: event)));
    // Refresh after returning — event may have been edited or deleted.
    ref.invalidate(eventsForDayProvider);
    _loadVisibleEvents();
  }

  /// Auto-sync on first launch (no saved cursor means we have never pulled
  /// from the network — covers both fresh installs and phrase restores).
  Future<void> _maybeAutoSync() async {
    final db = await ref.read(appDatabaseProvider.future);
    final syncState = db.getSyncState();
    if (syncState == null || syncState.cursor.isEmpty) {
      await _sync();
    }
  }

  Future<void> _sync({bool silent = false}) async {
    if (_isSyncing) return;
    _isSyncing = true;
    var syncError = false;

    final progress = ref.read(syncProgressProvider.notifier);
    progress.update(phase: SyncPhase.pulling, message: 'Starting sync...');

    // Start a foreground service on Android so the OS doesn't kill the process
    // while the (potentially long) Sia sync is running in the background.
    await SyncForegroundService.start();

    try {
      final engine = await ref.read(syncEngineProvider.future);
      await engine.fullSync(
        onProgress: ({phase, message, current, total}) {
          progress.update(
            phase: phase,
            message: message,
            current: current,
            total: total,
          );
          if (message != null) {
            final hasCount = (current ?? 0) > 0 && (total ?? 0) > 0;
            final notificationText = hasCount
                ? '$message (${current}/${total})'
                : message;
            unawaited(SyncForegroundService.updateProgress(notificationText));
          }
        },
      );
    } catch (e) {
      syncError = true;
      progress.reset();
      if (!silent && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
      }
    } finally {
      await SyncForegroundService.stop();
      _isSyncing = false;
    }

    if (syncError) return;

    progress.reset();
    ref.invalidate(eventsForDayProvider);
    _loadVisibleEvents();
    if (!silent && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sync complete')));
    }
  }

  void _importIncomingCalendarText(String text) {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    ref
        .read(calendarRepositoryProvider.future)
        .then((repository) {
          return handleIncomingCalendarText(
            navigator: navigator,
            messenger: messenger,
            repository: repository,
            text: text,
            onImported: () {
              ref.invalidate(eventsForDayProvider);
              _loadVisibleEvents();
            },
          );
        })
        .catchError((e) {
          if (!messenger.mounted) return;
          messenger.showSnackBar(
            SnackBar(content: Text('Could not import calendar file: $e')),
          );
        });
  }
}

class _EventListTile extends ConsumerWidget {
  final CalendarEvent event;
  final VoidCallback onTap;

  const _EventListTile({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calendarLookup = ref.watch(calendarLookupProvider).value ?? const {};
    DateTime displayStart = event.start;
    DateTime displayEnd = event.end;

    if (!event.allDay && event.timezone != null) {
      final deviceTz = ref.watch(deviceTimezoneProvider).asData?.value;
      if (deviceTz != null && deviceTz != event.timezone) {
        try {
          displayStart = TimezoneService.convertToTimezone(
            event.start,
            event.timezone!,
            deviceTz,
          );
          displayEnd = TimezoneService.convertToTimezone(
            event.end,
            event.timezone!,
            deviceTz,
          );
        } catch (_) {
          // Unknown timezone — fall back to stored wall-clock time.
        }
      }
    }

    final timeFormat = TimeOfDay.fromDateTime(displayStart);
    return ListTile(
      leading: event.allDay
          ? Icon(
              Icons.calendar_today,
              color: _calendarColor(
                calendarLookup[event.calendarId]?.color,
                fallback: Theme.of(context).colorScheme.primary,
              ),
            )
          : Icon(
              Icons.access_time,
              color: _calendarColor(
                calendarLookup[event.calendarId]?.color,
                fallback: Theme.of(context).colorScheme.primary,
              ),
            ),
      title: Text(event.title),
      subtitle: Text(
        event.allDay
            ? 'All day'
            : '${timeFormat.format(context)} – ${TimeOfDay.fromDateTime(displayEnd).format(context)}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (event.isRecurring || event.isVirtualInstance || event.isException)
            Icon(
              Icons.repeat,
              size: 16,
              color: Theme.of(context).colorScheme.outline,
            ),
          if (event.isDirty)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(
                Icons.cloud_upload_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
        ],
      ),
      onTap: onTap,
    );
  }
}

Color _calendarColor(String? hex, {required Color fallback}) {
  if (hex == null || hex.isEmpty) return fallback;
  final cleaned = hex.replaceAll('#', '').trim();
  final normalized = cleaned.length == 6 ? 'FF$cleaned' : cleaned;
  final parsed = int.tryParse(normalized, radix: 16);
  if (parsed == null) return fallback;
  return Color(parsed);
}
