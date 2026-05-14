import 'package:flutter_test/flutter_test.dart';
import 'package:sical/src/models/event.dart';
import 'package:sical/src/models/recurrence.dart';
import 'package:sical/src/repositories/calendar_repository.dart';
import 'package:sical/src/services/ics_import_service.dart';

class FakeCalendarRepository implements CalendarRepository {
  final List<CalendarEvent> savedEvents = <CalendarEvent>[];
  final Map<String, CalendarEvent> masterEvents = <String, CalendarEvent>{};

  @override
  void createEvent(CalendarEvent event) {
    savedEvents.add(event);
    if (event.masterEventId == null) {
      masterEvents[event.id] = event;
    }
  }

  @override
  CalendarEvent? getMasterEvent(String masterEventId) => masterEvents[masterEventId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('IcsImportService parsing', () {
    test('parses a single event draft', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:single-1
SUMMARY:Planning Session
DESCRIPTION:Discuss roadmap
LOCATION:Room 12
DTSTART:20260512T090000
DTEND:20260512T100000
END:VEVENT
END:VCALENDAR
''');

      expect(result.skippedCount, 0);
      expect(result.drafts, hasLength(1));

      final event = result.drafts.single;
      expect(event.title, 'Planning Session');
      expect(event.description, 'Discuss roadmap');
      expect(event.location, 'Room 12');
      expect(event.start, DateTime(2026, 5, 12, 9, 0));
      expect(event.end, DateTime(2026, 5, 12, 10, 0));
      expect(event.allDay, isFalse);
    });

    test('parses all-day and recurrence fields', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:recurring-1
SUMMARY:Yoga
DTSTART:20260512T090000
DTEND:20260512T100000
RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=5
END:VEVENT
BEGIN:VEVENT
UID:all-day-1
SUMMARY:Conference
DTSTART:20260513
DTEND:20260514
END:VEVENT
END:VCALENDAR
''');

      expect(result.skippedCount, 0);
      expect(result.drafts, hasLength(2));

      final recurring = result.drafts.first;
      expect(recurring.title, 'Yoga');
      final rule = RecurrenceRule.decode(recurring.recurrenceRule!);
      expect(rule.freq, RecurrenceFrequency.weekly);
      expect(rule.interval, 2);
      expect(rule.byDay, [DateTime.monday, DateTime.wednesday]);
      expect(rule.count, 5);

      final allDay = result.drafts.last;
      expect(allDay.allDay, isTrue);
      expect(allDay.start, DateTime(2026, 5, 13));
      expect(allDay.end, DateTime(2026, 5, 13, 23, 59));
    });
  });

  group('IcsImportService persistence', () {
    test('persists masters and cancelled exdates', () {
      final repo = FakeCalendarRepository();
      final service = IcsImportService(repo);

      final result = service.importFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:series-1
SUMMARY:Daily Standup
DTSTART:20260512T090000
DTEND:20260512T093000
RRULE:FREQ=DAILY;COUNT=2
EXDATE:20260513T090000
END:VEVENT
END:VCALENDAR
''');

      expect(result.importedCount, 2);
      expect(result.skippedCount, 0);
      expect(repo.savedEvents, hasLength(2));

      final master = repo.savedEvents.first;
      expect(master.title, 'Daily Standup');
      expect(master.recurrenceRule, isNotNull);
      expect(master.masterEventId, isNull);

      final cancelled = repo.savedEvents.last;
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.masterEventId, master.id);
      expect(cancelled.originalStart, '2026-05-13T09:00:00.000');
    });
  });
}