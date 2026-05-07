import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../database/database.dart';
import '../models/event.dart';
import '../models/recurrence.dart';
import '../services/sia_storage_service.dart';
import '../services/sync_engine.dart';

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

final eventsForDayProvider =
    FutureProvider.family<List<CalendarEvent>, DateTime>((ref, day) async {
      final repo = await ref.watch(calendarRepositoryProvider.future);
      return repo.getEventsForDay(day);
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

  /// Get all events (including expanded recurring instances) for [day].
  List<CalendarEvent> getEventsForDay(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return getEventsInRange(start, end);
  }

  /// Get all events (including expanded recurring instances) in [from]..[to].
  List<CalendarEvent> getEventsInRange(DateTime from, DateTime to) {
    // 1. Non-recurring, non-exception events in range.
    final regular = _db.getNonRecurringEventsInRange(from, to);

    // 2. Expand recurring masters.
    final masters = _db.getRecurringMastersInRange(from, to);
    final expanded = <CalendarEvent>[];
    for (final master in masters) {
      final exceptions = _db.getExceptionsForMaster(master.id);
      final exMap = <String, CalendarEvent>{};
      for (final ex in exceptions) {
        if (ex.originalStart != null) exMap[ex.originalStart!] = ex;
      }
      expanded.addAll(
        RecurrenceEngine.expand(master, from, to, exceptions: exMap),
      );
    }

    // 3. Merge and sort by start time.
    final all = [...regular, ...expanded];
    all.sort((a, b) => a.start.compareTo(b.start));
    return all;
  }

  List<CalendarEvent> getEventsForPeriod(String period) {
    return _db.getEventsForPeriod(period);
  }

  void createEvent(CalendarEvent event) {
    _db.upsertEvent(event);
  }

  void updateEvent(CalendarEvent event) {
    final updated = event.copyWith(
      isDirty: true,
      updatedAt: DateTime.now().toUtc(),
    );
    _db.upsertEvent(updated);
  }

  void deleteEvent(String id) {
    _db.deleteEvent(id);
  }

  // -----------------------------------------------------------------------
  // Recurring event operations
  // -----------------------------------------------------------------------

  /// Edit a single occurrence of a recurring series.
  /// Creates an exception event that overrides the virtual instance.
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
  }

  /// Delete a single occurrence by creating a cancelled exception.
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
  }

  /// Edit this and all following occurrences.
  /// Splits the series: truncates the old master at [splitDate], creates a
  /// new master for the rest.
  void editThisAndFollowing(
    CalendarEvent master,
    DateTime splitDate,
    CalendarEvent edited,
  ) {
    // Truncate original master — set UNTIL to the day before the split so the
    // old series does not generate an instance on the split date.
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

    // Create new master starting from the edited occurrence.
    final newRule = rule.copyWith(
      until: rule.until, // preserve original end
    );
    final newMaster = edited.copyWith(
      id: _uuid.v4(),
      recurrenceRule: newRule.encode(),
      masterEventId: null,
      originalStart: null,
      isDirty: true,
      instanceStart: null,
    );
    _db.upsertEvent(newMaster);
  }

  /// Delete this and all following occurrences.
  /// Truncates the series at [splitDate].
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
  }

  /// Edit all occurrences — updates the master event directly.
  void editAllOccurrences(CalendarEvent master, CalendarEvent edited) {
    // Preserve the master's recurrenceRule and id.
    final updated = edited.copyWith(
      id: master.id,
      recurrenceRule: master.recurrenceRule,
      masterEventId: null,
      originalStart: null,
      isDirty: true,
      instanceStart: null,
    );
    _db.upsertEvent(updated);
  }

  /// Delete all occurrences — removes master and all exceptions.
  void deleteAllOccurrences(String masterId) {
    _db.deleteEvent(masterId); // cascades to exceptions
  }

  /// Look up the persisted master event for a virtual instance.
  CalendarEvent? getMasterEvent(String masterEventId) {
    return _db.getEventById(masterEventId);
  }
}
