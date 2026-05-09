import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import '../../repositories/calendar_repository.dart';
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

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Map<DateTime, List<CalendarEvent>> _eventsByDay = {};

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    // Load events for the initial month so markers appear immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadVisibleEvents());
  }

  /// Normalise to midnight for event-day lookup.
  DateTime _normalizeDay(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Load all visible events for the current month into the marker map.
  Future<void> _loadVisibleEvents() async {
    final first = DateTime(_focusedDay.year, _focusedDay.month, 1);
    final last = DateTime(_focusedDay.year, _focusedDay.month + 1, 0, 23, 59);
    final repo = await ref.read(calendarRepositoryProvider.future);
    final events = repo.getEventsInRange(first, last);
    final map = <DateTime, List<CalendarEvent>>{};
    for (final e in events) {
      final day = _normalizeDay(e.start);
      (map[day] ??= []).add(e);
    }
    if (mounted) setState(() => _eventsByDay = map);
  }

  @override
  Widget build(BuildContext context) {
    final eventsAsync = ref.watch(
      eventsForDayProvider(_selectedDay ?? _focusedDay),
    );

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
            icon: const Icon(Icons.sync),
            tooltip: 'Sync',
            onPressed: _sync,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
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
    final result = await Navigator.of(context).push<CalendarEvent>(
      MaterialPageRoute(
        builder: (_) =>
            EventFormScreen(initialDate: _selectedDay ?? _focusedDay),
      ),
    );
    if (result != null) {
      final repo = await ref.read(calendarRepositoryProvider.future);
      repo.createEvent(result);
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

  Future<void> _sync() async {
    final progress = ref.read(syncProgressProvider.notifier);
    progress.update(phase: SyncPhase.pulling, message: 'Starting sync...');
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
        },
      );
    } catch (e) {
      progress.reset();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
        return;
      }
    }
    progress.reset();
    ref.invalidate(eventsForDayProvider);
    _loadVisibleEvents();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sync complete')));
    }
  }
}

class _EventListTile extends StatelessWidget {
  final CalendarEvent event;
  final VoidCallback onTap;

  const _EventListTile({required this.event, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final timeFormat = TimeOfDay.fromDateTime(event.start);
    return ListTile(
      leading: event.allDay
          ? const Icon(Icons.calendar_today)
          : const Icon(Icons.access_time),
      title: Text(event.title),
      subtitle: Text(
        event.allDay
            ? 'All day'
            : '${timeFormat.format(context)} – ${TimeOfDay.fromDateTime(event.end).format(context)}',
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
