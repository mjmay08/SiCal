import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../database/database.dart';
import '../models/calendar.dart';
import '../models/event.dart';
import '../models/recurrence.dart';
import '../services/event_notification_service.dart';
import '../services/sia_storage_service.dart';
import '../services/sync_engine.dart';
import '../services/timezone_service.dart';

const _uuid = Uuid();

final appDatabaseProvider = FutureProvider<AppDatabase>((ref) async {
  return AppDatabase.getInstance();
});

final siaStorageServiceProvider = Provider<SiaStorageService>((ref) {
  return SiaStorageService();
});

final syncEngineProvider = FutureProvider<SyncEngine>((ref) async {
  final db = await ref.watch(appDatabaseProvider.future);
  final sia = ref.watch(siaStorageServiceProvider);
  return SyncEngine(db, sia);
});

final calendarRepositoryProvider = FutureProvider<CalendarRepository>((
  ref,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return CalendarRepository(db);
});

final defaultEventReminderMinutesProvider = FutureProvider<List<int>>((
  ref,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  return db.getDefaultEventReminderMinutes();
});

final selectedCalendarIdProvider =
    NotifierProvider<SelectedCalendarIdNotifier, String?>(
      SelectedCalendarIdNotifier.new,
    );

class SelectedCalendarIdNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? calendarId) {
    state = calendarId;
  }
}

final calendarsProvider = FutureProvider<List<CalendarInfo>>((ref) async {
  final repo = await ref.watch(calendarRepositoryProvider.future);
  return repo.getCalendars();
});

final visibleCalendarIdsProvider = FutureProvider<List<String>>((ref) async {
  final calendars = await ref.watch(calendarsProvider.future);
  final visible = calendars.where((c) => c.isVisible).map((c) => c.id).toList();
  return visible.isEmpty ? [kDefaultCalendarId] : visible;
});

final calendarLookupProvider = FutureProvider<Map<String, CalendarInfo>>((
  ref,
) async {
  final calendars = await ref.watch(calendarsProvider.future);
  return {for (final calendar in calendars) calendar.id: calendar};
});

DateTime effectiveDisplayStart(CalendarEvent event, String? deviceTz) {
  if (event.allDay || event.timezone == null || deviceTz == null) {
    return event.start;
  }
  if (deviceTz == event.timezone) return event.start;
  try {
    return TimezoneService.convertToTimezone(
      event.start,
      event.timezone!,
      deviceTz,
    );
  } catch (_) {
    return event.start;
  }
}

DateTime effectiveOccurrenceStart(CalendarEvent event, String? deviceTz) {
  final start = event.instanceStart ?? event.start;
  if (event.allDay || event.timezone == null || deviceTz == null) {
    return start;
  }
  if (deviceTz == event.timezone) return start;
  try {
    return TimezoneService.convertToTimezone(start, event.timezone!, deviceTz);
  } catch (_) {
    return start;
  }
}

final eventsForDayProvider =
    FutureProvider.family<List<CalendarEvent>, DateTime>((ref, day) async {
      final repo = await ref.watch(calendarRepositoryProvider.future);
      String? deviceTz;
      try {
        // Ensure timezone-aware events are filtered against the selected day
        // using the same resolved device timezone as month markers.
        deviceTz = await ref.watch(deviceTimezoneProvider.future);
      } catch (_) {}

      final from = DateTime(
        day.year,
        day.month,
        day.day,
      ).subtract(const Duration(days: 1));
      final to = DateTime(
        day.year,
        day.month,
        day.day,
      ).add(const Duration(days: 2));
      final candidates = repo.getEventsInRange(from, to);

      final dayStart = DateTime(day.year, day.month, day.day);
      final dayEnd = dayStart.add(const Duration(days: 1));

      final results =
          candidates.where((e) {
            final start = effectiveOccurrenceStart(e, deviceTz);
            return !start.isBefore(dayStart) && start.isBefore(dayEnd);
          }).toList()..sort(
            (a, b) => effectiveOccurrenceStart(
              a,
              deviceTz,
            ).compareTo(effectiveOccurrenceStart(b, deviceTz)),
          );
      return results;
    });

final selectedDayProvider = NotifierProvider<SelectedDayNotifier, DateTime>(
  SelectedDayNotifier.new,
);

class SelectedDayNotifier extends Notifier<DateTime> {
  @override
  DateTime build() => DateTime.now();
}

class CalendarRepository {
  final AppDatabase _db;

  CalendarRepository(this._db);

  List<CalendarEvent> getEventsForDay(
    DateTime day, {
    Iterable<String>? calendarIds,
  }) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return getEventsInRange(start, end, calendarIds: calendarIds);
  }

  List<CalendarEvent> getEventsInRange(
    DateTime from,
    DateTime to, {
    Iterable<String>? calendarIds,
  }) {
    final regular = _db.getNonRecurringEventsInRange(
      from,
      to,
      calendarIds: calendarIds,
    );

    final masters = _db.getRecurringMastersInRange(
      from,
      to,
      calendarIds: calendarIds,
    );
    final expanded = <CalendarEvent>[];
    for (final master in masters) {
      final exceptions = _db.getExceptionsForMaster(
        master.id,
        calendarId: master.calendarId,
      );
      final exMap = <String, CalendarEvent>{};
      for (final ex in exceptions) {
        if (ex.originalStart != null) exMap[ex.originalStart!] = ex;
      }
      expanded.addAll(
        RecurrenceEngine.expand(master, from, to, exceptions: exMap),
      );
    }

    final all = [...regular, ...expanded];
    all.sort((a, b) => a.start.compareTo(b.start));
    return all;
  }

  List<CalendarEvent> getEventsForPeriod(String period) {
    return _db.getEventsForPeriod(period);
  }

  List<CalendarInfo> getCalendars() => _db.getCalendars();

  List<CalendarInfo> getVisibleCalendars() => _db.getVisibleCalendars();

  CalendarInfo? getCalendarById(String calendarId) =>
      _db.getCalendarById(calendarId);

  CalendarEvent? getEventById(String id) => _db.getEventById(id);

  void upsertCalendar(CalendarInfo calendar) => _db.upsertCalendar(calendar);

  void deleteCalendar(String calendarId) => _db.deleteCalendar(calendarId);

  List<int> getDefaultEventReminderMinutes() =>
      _db.getDefaultEventReminderMinutes();

  void setDefaultEventReminderMinutes(List<int> reminderMinutes) {
    _db.setDefaultEventReminderMinutes(reminderMinutes);
  }

  void refreshNotifications() {
    unawaited(EventNotificationService.rescheduleAll(_db));
  }

  void createEvent(CalendarEvent event, {bool refreshNotifications = true}) {
    _db.upsertEvent(event);
    if (refreshNotifications) this.refreshNotifications();
  }

  void updateEvent(CalendarEvent event, {bool refreshNotifications = true}) {
    final updated = event.copyWith(
      isDirty: true,
      updatedAt: DateTime.now().toUtc(),
    );
    _db.upsertEvent(updated);
    if (refreshNotifications) this.refreshNotifications();
  }

  void deleteEvent(String id, {bool refreshNotifications = true}) {
    _db.deleteEvent(id);
    if (refreshNotifications) this.refreshNotifications();
  }

  void editSingleOccurrence(
    CalendarEvent master,
    DateTime originalInstanceStart,
    CalendarEvent edited,
  ) {
    final exception = edited.copyWith(
      id: _uuid.v4(),
      masterEventId: master.id,
      originalStart: originalInstanceStart.toIso8601String(),
      recurrenceRule: null,
      isDirty: true,
      instanceStart: null,
    );
    _db.upsertEvent(exception);
    refreshNotifications();
  }

  void deleteSingleOccurrence(
    CalendarEvent master,
    DateTime originalInstanceStart,
  ) {
    final exception = master.copyWith(
      id: _uuid.v4(),
      masterEventId: master.id,
      originalStart: originalInstanceStart.toIso8601String(),
      recurrenceRule: null,
      isCancelled: true,
      isDirty: true,
      instanceStart: null,
    );
    _db.upsertEvent(exception);
    refreshNotifications();
  }

  void editThisAndFollowing(
    CalendarEvent master,
    DateTime splitDate,
    CalendarEvent edited,
  ) {
    final rule = RecurrenceRule.decode(master.recurrenceRule!);
    final dayBeforeSplit = DateTime(
      splitDate.year,
      splitDate.month,
      splitDate.day,
    ).subtract(const Duration(days: 1));
    final truncated = rule.copyWith(until: dayBeforeSplit);
    final updatedMaster = master.copyWith(
      recurrenceRule: truncated.encode(),
      isDirty: true,
      instanceStart: null,
    );
    _db.upsertEvent(updatedMaster);

    final newRule = rule.copyWith(until: rule.until);
    final newMaster = edited.copyWith(
      id: _uuid.v4(),
      recurrenceRule: newRule.encode(),
      masterEventId: null,
      originalStart: null,
      isDirty: true,
      instanceStart: null,
    );
    _db.upsertEvent(newMaster);
    refreshNotifications();
  }

  void deleteThisAndFollowing(CalendarEvent master, DateTime splitDate) {
    final rule = RecurrenceRule.decode(master.recurrenceRule!);
    final dayBeforeSplit = DateTime(
      splitDate.year,
      splitDate.month,
      splitDate.day,
    ).subtract(const Duration(days: 1));
    final truncated = rule.copyWith(until: dayBeforeSplit);
    final updatedMaster = master.copyWith(
      recurrenceRule: truncated.encode(),
      isDirty: true,
      instanceStart: null,
    );
    _db.upsertEvent(updatedMaster);
    refreshNotifications();
  }

  void editAllOccurrences(CalendarEvent master, CalendarEvent edited) {
    final updated = edited.copyWith(
      id: master.id,
      recurrenceRule: master.recurrenceRule,
      masterEventId: null,
      originalStart: null,
      isDirty: true,
      instanceStart: null,
    );
    _db.upsertEvent(updated);
    refreshNotifications();
  }

  void deleteAllOccurrences(String masterId) {
    _db.deleteEvent(masterId);
    refreshNotifications();
  }

  CalendarEvent? getMasterEvent(String masterEventId) {
    return _db.getEventById(masterEventId);
  }

  String getCalendarTimezone({String? calendarId}) {
    if (calendarId != null) {
      final calendar = _db.getCalendarById(calendarId);
      if (calendar != null) return calendar.timezone;
    }
    return _db.getManifest()?.timezone ?? 'UTC';
  }
}
