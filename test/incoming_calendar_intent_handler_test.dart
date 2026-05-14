import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sical/src/models/event.dart';
import 'package:sical/src/repositories/calendar_repository.dart';
import 'package:sical/src/services/incoming_calendar_intent_handler.dart';

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

const _singleEventIcs = '''
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
''';

const _multiEventIcs = '''
BEGIN:VCALENDAR
PRODID:-//SiCal//Test//EN
VERSION:2.0
BEGIN:VEVENT
UID:first-1
SUMMARY:Morning Briefing
DTSTART:20260512T080000
DTEND:20260512T083000
END:VEVENT
BEGIN:VEVENT
UID:second-1
SUMMARY:Design Review
DTSTART:20260512T100000
DTEND:20260512T110000
END:VEVENT
END:VCALENDAR
''';

void main() {
  testWidgets('opens Edit Event with prefilled data for a single incoming event', (
    tester,
  ) async {
    final repo = FakeCalendarRepository();
    late BuildContext hostContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final navigator = Navigator.of(hostContext);
    final messenger = ScaffoldMessenger.of(hostContext);

    final future = handleIncomingCalendarText(
      navigator: navigator,
      messenger: messenger,
      repository: repo,
      text: _singleEventIcs,
    );
    await tester.pumpAndSettle();

    expect(find.text('Edit Event'), findsOneWidget);
    expect(
      tester.widgetList<EditableText>(find.byType(EditableText)).first.controller.text,
      'Planning Session',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await future;

    expect(repo.savedEvents, hasLength(1));
    expect(repo.savedEvents.single.title, 'Planning Session');
    expect(repo.savedEvents.single.location, 'Room 12');
  });

  testWidgets('shows a chooser for multiple incoming events', (tester) async {
    final repo = FakeCalendarRepository();
    late BuildContext hostContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    final navigator = Navigator.of(hostContext);
    final messenger = ScaffoldMessenger.of(hostContext);

    final future = handleIncomingCalendarText(
      navigator: navigator,
      messenger: messenger,
      repository: repo,
      text: _multiEventIcs,
    );
    await tester.pumpAndSettle();

    expect(find.text('Choose Event to Import'), findsOneWidget);
    expect(find.text('Morning Briefing'), findsOneWidget);
    expect(find.text('Design Review'), findsOneWidget);

    await tester.tap(find.text('Design Review'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Event'), findsOneWidget);
    expect(
      tester.widgetList<EditableText>(find.byType(EditableText)).first.controller.text,
      'Design Review',
    );

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await future;

    expect(repo.savedEvents, hasLength(1));
    expect(repo.savedEvents.single.title, 'Design Review');
  });
}