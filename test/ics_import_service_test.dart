import 'package:flutter_test/flutter_test.dart';
import 'package:sical/src/models/event.dart';
import 'package:sical/src/models/recurrence.dart';
import 'package:sical/src/repositories/calendar_repository.dart';
import 'package:sical/src/services/ics_import_service.dart';

class FakeCalendarRepository implements CalendarRepository {
  final List<CalendarEvent> savedEvents = <CalendarEvent>[];
  final Map<String, CalendarEvent> masterEvents = <String, CalendarEvent>{};
  final String calendarTimezone;

  FakeCalendarRepository({this.calendarTimezone = 'UTC'});

  @override
  void createEvent(CalendarEvent event) {
    savedEvents.add(event);
    if (event.masterEventId == null) {
      masterEvents[event.id] = event;
    }
  }

  @override
  CalendarEvent? getMasterEvent(String masterEventId) =>
      masterEvents[masterEventId];

  @override
  String getCalendarTimezone() => calendarTimezone;

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

  group('IcsImportService DURATION support', () {
    test('uses DURATION when DTEND is absent (PT1H30M)', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:dur-1
SUMMARY:Short Meeting
DTSTART:20260521T100000
DURATION:PT1H30M
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      expect(event.start, DateTime(2026, 5, 21, 10, 0));
      expect(event.end, DateTime(2026, 5, 21, 11, 30));
    });

    test('uses DURATION P1D for a one-day timed event', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:dur-2
SUMMARY:Full Day Session
DTSTART:20260521T080000
DURATION:P1D
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      expect(event.start, DateTime(2026, 5, 21, 8, 0));
      expect(event.end, DateTime(2026, 5, 22, 8, 0));
    });

    test('uses DURATION P1W (week)', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:dur-3
SUMMARY:Week-long Project
DTSTART:20260521T090000
DURATION:P1W
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      expect(event.start, DateTime(2026, 5, 21, 9, 0));
      expect(event.end, DateTime(2026, 5, 28, 9, 0));
    });

    test('prefers DTEND over DURATION when both are present', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:dur-4
SUMMARY:Explicit End
DTSTART:20260521T100000
DTEND:20260521T110000
DURATION:P1D
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      expect(event.end, DateTime(2026, 5, 21, 11, 0));
    });
  });

  group('IcsImportService URL support', () {
    test('appends URL to description when both are present', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:url-1
SUMMARY:Online Conference
DESCRIPTION:Annual summit
DTSTART:20260521T090000
DTEND:20260521T170000
URL:https://example.com/conference
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      expect(
        event.description,
        'Annual summit\nhttps://example.com/conference',
      );
    });

    test('uses URL as description when description is absent', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:url-2
SUMMARY:Link Only
DTSTART:20260521T090000
DTEND:20260521T100000
URL:https://example.com/meeting
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      expect(event.description, 'https://example.com/meeting');
    });

    test('description only when URL is absent', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:url-3
SUMMARY:No URL
DESCRIPTION:Just a description
DTSTART:20260521T090000
DTEND:20260521T100000
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      expect(event.description, 'Just a description');
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

  group('IcsImportService timezone handling', () {
    test('DTSTART with TZID stores timezone and wall-clock time', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:tz-1
SUMMARY:Morning Meeting
DTSTART;TZID=America/New_York:20260521T100000
DTEND;TZID=America/New_York:20260521T110000
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      // Wall-clock time should be stored as-is (10:00 AM Eastern).
      expect(event.start, DateTime(2026, 5, 21, 10, 0));
      expect(event.end, DateTime(2026, 5, 21, 11, 0));
      // Timezone should be set to the TZID from the ICS file.
      expect(event.timezone, 'America/New_York');
    });

    test('DTSTART with Z suffix converts to calendar default timezone', () {
      // Calendar default is America/Los_Angeles (UTC-7 in May = PDT).
      final service = IcsImportService(
        FakeCalendarRepository(calendarTimezone: 'America/Los_Angeles'),
      );

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:utc-1
SUMMARY:UTC Event
DTSTART:20260521T150000Z
DTEND:20260521T160000Z
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      // 15:00 UTC = 08:00 PDT (America/Los_Angeles, UTC-7 in summer).
      expect(event.start, DateTime(2026, 5, 21, 8, 0));
      expect(event.end, DateTime(2026, 5, 21, 9, 0));
      expect(event.timezone, 'America/Los_Angeles');
    });

    test('DTSTART without TZID or Z suffix is floating (null timezone)', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:float-1
SUMMARY:Floating Event
DTSTART:20260521T090000
DTEND:20260521T100000
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      expect(event.start, DateTime(2026, 5, 21, 9, 0));
      expect(event.timezone, isNull);
    });

    test('All-day events always have null timezone', () {
      final service = IcsImportService(FakeCalendarRepository());

      final result = service.parseDraftsFromString('''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:allday-1
SUMMARY:All Day
DTSTART:20260521
DTEND:20260522
END:VEVENT
END:VCALENDAR
''');

      expect(result.drafts, hasLength(1));
      final event = result.drafts.single;
      expect(event.allDay, isTrue);
      expect(event.timezone, isNull);
    });
  });

  group('CalendarEvent timezone serialization', () {
    test('toJson includes timezone field', () {
      final event = CalendarEvent(
        title: 'Test',
        start: DateTime(2026, 5, 21, 10, 0),
        end: DateTime(2026, 5, 21, 11, 0),
        timezone: 'Europe/London',
      );
      final json = event.toJson();
      expect(json['timezone'], 'Europe/London');
    });

    test('fromJson restores timezone field', () {
      final event = CalendarEvent(
        title: 'Test',
        start: DateTime(2026, 5, 21, 10, 0),
        end: DateTime(2026, 5, 21, 11, 0),
        timezone: 'Asia/Tokyo',
      );
      final restored = CalendarEvent.fromJson(event.toJson());
      expect(restored.timezone, 'Asia/Tokyo');
    });

    test('fromJson treats missing timezone key as null (floating)', () {
      final event = CalendarEvent(
        title: 'Legacy',
        start: DateTime(2026, 5, 21, 10, 0),
        end: DateTime(2026, 5, 21, 11, 0),
      );
      final json = event.toJson()..remove('timezone');
      final restored = CalendarEvent.fromJson(json);
      expect(restored.timezone, isNull);
    });

    test('copyWith preserves timezone when not provided', () {
      final event = CalendarEvent(
        title: 'Test',
        start: DateTime(2026, 5, 21, 10, 0),
        end: DateTime(2026, 5, 21, 11, 0),
        timezone: 'America/Chicago',
      );
      final copy = event.copyWith(title: 'Updated');
      expect(copy.timezone, 'America/Chicago');
    });

    test('copyWith can clear timezone to null', () {
      final event = CalendarEvent(
        title: 'Test',
        start: DateTime(2026, 5, 21, 10, 0),
        end: DateTime(2026, 5, 21, 11, 0),
        timezone: 'America/Chicago',
      );
      final copy = event.copyWith(timezone: null);
      expect(copy.timezone, isNull);
    });
  });
}
