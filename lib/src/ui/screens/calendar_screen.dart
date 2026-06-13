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
  static const StartingDayOfWeek _weekStartsOn = StartingDayOfWeek.sunday;
  static const double _markerRowHeight = 12;
  static const double _markerRowGap = 1;
  static const int _markerMaxRows = 4;
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

  DateTime _occurrenceStartDay(CalendarEvent event, String? deviceTz) {
    return _normalizeDay(effectiveOccurrenceStart(event, deviceTz));
  }

  DateTime _occurrenceEndDay(CalendarEvent event, String? deviceTz) {
    return _normalizeDay(effectiveOccurrenceEnd(event, deviceTz));
  }

  DateTime _startOfCalendarWeek(DateTime day) {
    final normalized = _normalizeDay(day);
    final daysFromWeekStart = _weekStartsOn == StartingDayOfWeek.sunday
        ? normalized.weekday % DateTime.daysPerWeek
        : normalized.weekday - DateTime.monday;
    return normalized.subtract(Duration(days: daysFromWeekStart));
  }

  String _occurrenceKey(CalendarEvent event) {
    return '${event.id}|${(event.instanceStart ?? event.start).toIso8601String()}';
  }

  _WeekAllDayLanes _computeWeekAllDayLanes(DateTime day, String? deviceTz) {
    final weekStart = _startOfCalendarWeek(day);
    final weekEnd = weekStart.add(
      const Duration(days: DateTime.daysPerWeek - 1),
    );

    final allDayByKey = <String, CalendarEvent>{};
    for (
      var cursor = weekStart;
      !cursor.isAfter(weekEnd);
      cursor = cursor.add(const Duration(days: 1))
    ) {
      final items =
          _eventsByDay[_normalizeDay(cursor)] ?? const <CalendarEvent>[];
      for (final event in items) {
        if (!event.allDay) continue;
        allDayByKey.putIfAbsent(_occurrenceKey(event), () => event);
      }
    }

    final ranges =
        allDayByKey.entries
            .map((entry) {
              final start = _occurrenceStartDay(entry.value, deviceTz);
              final end = _occurrenceEndDay(entry.value, deviceTz);
              final segmentStart = start.isAfter(weekStart) ? start : weekStart;
              final segmentEnd = end.isBefore(weekEnd) ? end : weekEnd;
              return _AllDayRange(
                key: entry.key,
                event: entry.value,
                start: segmentStart,
                end: segmentEnd,
              );
            })
            .where((range) => !range.end.isBefore(range.start))
            .toList()
          ..sort((a, b) {
            final startCmp = a.start.compareTo(b.start);
            if (startCmp != 0) return startCmp;
            final endCmp = a.end.compareTo(b.end);
            if (endCmp != 0) return endCmp;
            return a.event.title.compareTo(b.event.title);
          });

    final laneEnds = <DateTime>[];
    final lanes = <String, int>{};
    for (final range in ranges) {
      var lane = -1;
      for (var i = 0; i < laneEnds.length; i++) {
        if (laneEnds[i].isBefore(range.start)) {
          lane = i;
          break;
        }
      }
      if (lane == -1) {
        lane = laneEnds.length;
        laneEnds.add(range.end);
      } else {
        laneEnds[lane] = range.end;
      }
      lanes[range.key] = lane;
    }

    return _WeekAllDayLanes(lanes: lanes, totalLanes: laneEnds.length);
  }

  Widget _buildAllDayMarker(
    BuildContext context, {
    required BoxConstraints constraints,
    required DateTime day,
    required CalendarEvent event,
    required Color color,
    required String? deviceTz,
  }) {
    final startDay = _occurrenceStartDay(event, deviceTz);
    final endDay = _occurrenceEndDay(event, deviceTz);
    final weekStart = _startOfCalendarWeek(day);
    final weekEnd = weekStart.add(
      const Duration(days: DateTime.daysPerWeek - 1),
    );

    final segmentStart = startDay.isAfter(weekStart) ? startDay : weekStart;
    final segmentEnd = endDay.isBefore(weekEnd) ? endDay : weekEnd;
    final isSegmentStart = isSameDay(day, segmentStart);
    final spanDays = segmentEnd.difference(segmentStart).inDays + 1;

    final fillColor = color.withAlpha(90);
    final textColor =
        ThemeData.estimateBrightnessForColor(fillColor) == Brightness.dark
        ? Colors.white
        : Colors.black87;

    if (!isSegmentStart) {
      // Keep row height for lane alignment while avoiding a duplicate bar.
      return const SizedBox(height: _markerRowHeight);
    }

    return SizedBox(
      height: _markerRowHeight,
      child: OverflowBox(
        minWidth: constraints.maxWidth,
        maxWidth: constraints.maxWidth * spanDays,
        alignment: Alignment.centerLeft,
        child: Container(
          width: constraints.maxWidth * spanDays,
          height: _markerRowHeight,
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: BorderRadius.circular(3),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 3),
          alignment: Alignment.centerLeft,
          child: Text(
            event.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 9,
              height: 1,
              color: textColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDayCell(
    BuildContext context,
    DateTime day, {
    bool isSelected = false,
    bool isToday = false,
    bool isOutside = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final borderColor = isSelected ? scheme.primary : Colors.transparent;
    final textColor = isOutside
        ? scheme.outline
        : (isSelected ? scheme.onSurface : null);

    return Container(
      margin: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: isToday ? scheme.primary.withAlpha(80) : Colors.transparent,
        border: Border.all(color: borderColor, width: isSelected ? 1.8 : 1),
      ),
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        '${day.day}',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: textColor,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }

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
    final firstDay = _normalizeDay(first);
    final lastDay = _normalizeDay(last);
    final map = <DateTime, List<CalendarEvent>>{};
    for (final e in events) {
      final startDay = _occurrenceStartDay(e, deviceTz);
      if (!e.allDay) {
        (map[startDay] ??= []).add(e);
        continue;
      }

      final endDay = _occurrenceEndDay(e, deviceTz);
      final clampedStart = startDay.isBefore(firstDay) ? firstDay : startDay;
      final clampedEnd = endDay.isAfter(lastDay) ? lastDay : endDay;
      if (clampedEnd.isBefore(clampedStart)) continue;

      for (
        var d = clampedStart;
        !d.isAfter(clampedEnd);
        d = d.add(const Duration(days: 1))
      ) {
        (map[d] ??= []).add(e);
      }
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
    final deviceTz = ref.watch(deviceTimezoneProvider).asData?.value;
    final selectedDayKey = _normalizeDay(_selectedDay ?? _focusedDay);
    final markerDayEvents =
        (_eventsByDay[selectedDayKey] ?? const <CalendarEvent>[]).toList()
          ..sort(
            (a, b) => effectiveDisplayStart(
              a,
              deviceTz,
            ).compareTo(effectiveDisplayStart(b, deviceTz)),
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
            startingDayOfWeek: _weekStartsOn,
            rowHeight: 76,
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
              selectedBuilder: (context, day, focusedDay) =>
                  _buildDayCell(context, day, isSelected: true),
              todayBuilder: (context, day, focusedDay) =>
                  _buildDayCell(context, day, isToday: true),
              defaultBuilder: (context, day, focusedDay) =>
                  _buildDayCell(context, day),
              outsideBuilder: (context, day, focusedDay) =>
                  _buildDayCell(context, day, isOutside: true),
              markerBuilder: (context, day, events) {
                if (events.isEmpty) return const SizedBox.shrink();
                final dayEvents = events.cast<CalendarEvent>().toList()
                  ..sort((a, b) {
                    if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
                    return effectiveOccurrenceStart(
                      a,
                      deviceTz,
                    ).compareTo(effectiveOccurrenceStart(b, deviceTz));
                  });
                final weekLanes = _computeWeekAllDayLanes(day, deviceTz);
                final allDayByLane = <int, CalendarEvent>{};
                for (final event in dayEvents.where((event) => event.allDay)) {
                  final lane = weekLanes.lanes[_occurrenceKey(event)];
                  if (lane != null) allDayByLane[lane] = event;
                }
                final allDayRowsForDay = allDayByLane.isEmpty
                    ? 0
                    : (allDayByLane.keys.reduce((a, b) => a > b ? a : b) + 1);
                final timedEvents = dayEvents
                    .where((event) => !event.allDay)
                    .toList();
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(3, 22, 3, 3),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final rowCount = _markerMaxRows;
                        final markerHeight =
                            rowCount * _markerRowHeight +
                            (rowCount - 1) * _markerRowGap;

                        final rowWidgets = <Widget>[];
                        final rowEventKeys = <String?>[];

                        void addRow(Widget widget, {String? eventKey}) {
                          if (rowWidgets.length >= rowCount) return;
                          rowWidgets.add(widget);
                          rowEventKeys.add(eventKey);
                        }

                        Widget buildRow(CalendarEvent item) {
                          if (item.allDay) {
                            return _buildAllDayMarker(
                              context,
                              constraints: constraints,
                              day: day,
                              event: item,
                              color: _calendarColor(
                                calendarLookup[item.calendarId]?.color,
                                fallback: Theme.of(context).colorScheme.primary,
                              ),
                              deviceTz: deviceTz,
                            );
                          }
                          return SizedBox(
                            height: _markerRowHeight,
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    fontSize: 9,
                                    height: 1.05,
                                    color: _calendarColor(
                                      calendarLookup[item.calendarId]?.color,
                                      fallback: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                            ),
                          );
                        }

                        for (
                          var lane = 0;
                          lane < allDayRowsForDay && lane < rowCount;
                          lane++
                        ) {
                          final event = allDayByLane[lane];
                          if (event != null) {
                            addRow(
                              buildRow(event),
                              eventKey: _occurrenceKey(event),
                            );
                          } else {
                            addRow(const SizedBox(height: _markerRowHeight));
                          }
                        }

                        for (final event in timedEvents) {
                          if (rowWidgets.length >= rowCount) break;
                          addRow(
                            buildRow(event),
                            eventKey: _occurrenceKey(event),
                          );
                        }

                        while (rowWidgets.length < rowCount) {
                          addRow(const SizedBox(height: _markerRowHeight));
                        }

                        final visibleKeys = rowEventKeys
                            .whereType<String>()
                            .toSet();
                        var hiddenCount = dayEvents.length - visibleKeys.length;
                        if (hiddenCount > 0) {
                          final moreRowIndex = rowCount - 1;
                          final replacedKey = rowEventKeys[moreRowIndex];
                          if (replacedKey != null) {
                            visibleKeys.remove(replacedKey);
                          }
                          hiddenCount = dayEvents.length - visibleKeys.length;
                          rowWidgets[moreRowIndex] = SizedBox(
                            height: _markerRowHeight,
                            child: Text(
                              '+$hiddenCount more',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    fontSize: 8,
                                    height: 1.0,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
                                  ),
                            ),
                          );
                          rowEventKeys[moreRowIndex] = null;
                        }

                        return SizedBox(
                          height: markerHeight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var row = 0; row < rowCount; row++) ...[
                                rowWidgets[row],
                                if (row != rowCount - 1)
                                  const SizedBox(height: _markerRowGap),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
            calendarStyle: CalendarStyle(
              cellMargin: const EdgeInsets.all(1.5),
              cellPadding: const EdgeInsets.all(2),
              selectedTextStyle: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: eventsAsync.when(
              data: (events) {
                final byKey = <String, CalendarEvent>{
                  for (final e in events)
                    '${e.id}|${(e.instanceStart ?? e.start).toIso8601String()}':
                        e,
                };
                for (final e in markerDayEvents) {
                  final key =
                      '${e.id}|${(e.instanceStart ?? e.start).toIso8601String()}';
                  byKey.putIfAbsent(key, () => e);
                }
                final displayEvents = byKey.values.toList()
                  ..sort(
                    (a, b) => effectiveOccurrenceStart(
                      a,
                      deviceTz,
                    ).compareTo(effectiveOccurrenceStart(b, deviceTz)),
                  );
                return displayEvents.isEmpty
                    ? const Center(child: Text('No events'))
                    : ListView.builder(
                        itemCount: displayEvents.length,
                        itemBuilder: (context, index) {
                          final event = displayEvents[index];
                          return _EventListTile(
                            event: event,
                            onTap: () => _openEventDetail(event),
                          );
                        },
                      );
              },
              loading: () => markerDayEvents.isNotEmpty
                  ? ListView.builder(
                      itemCount: markerDayEvents.length,
                      itemBuilder: (context, index) {
                        final event = markerDayEvents[index];
                        return _EventListTile(
                          event: event,
                          onTap: () => _openEventDetail(event),
                        );
                      },
                    )
                  : const Center(child: CircularProgressIndicator()),
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
                ? '$message ($current/$total)'
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

class _AllDayRange {
  final String key;
  final CalendarEvent event;
  final DateTime start;
  final DateTime end;

  const _AllDayRange({
    required this.key,
    required this.event,
    required this.start,
    required this.end,
  });
}

class _WeekAllDayLanes {
  final Map<String, int> lanes;
  final int totalLanes;

  const _WeekAllDayLanes({required this.lanes, required this.totalLanes});
}

Color _calendarColor(String? hex, {required Color fallback}) {
  if (hex == null || hex.isEmpty) return fallback;
  final cleaned = hex.replaceAll('#', '').trim();
  final normalized = cleaned.length == 6 ? 'FF$cleaned' : cleaned;
  final parsed = int.tryParse(normalized, radix: 16);
  if (parsed == null) return fallback;
  return Color(parsed);
}
