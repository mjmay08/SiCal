import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sical/src/models/calendar.dart';
import 'package:sical/src/models/event.dart';
import 'package:sical/src/repositories/calendar_repository.dart';
import 'package:sical/src/ui/screens/event_form_screen.dart';

void main() {
  testWidgets('tapping date and time toggles inline editors', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_buildTestApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('start-date-editor')), findsNothing);
    expect(find.byKey(const Key('start-time-editor')), findsNothing);

    await tester.tap(find.byKey(const Key('start-date-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('start-date-editor')), findsOneWidget);
    expect(find.byType(CalendarDatePicker), findsOneWidget);
    expect(find.byKey(const Key('start-time-editor')), findsNothing);

    await tester.tap(find.byKey(const Key('start-time-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('start-date-editor')), findsNothing);
    expect(find.byKey(const Key('start-time-editor')), findsOneWidget);
    expect(find.text('Hour'), findsOneWidget);
    expect(find.text('Minute'), findsOneWidget);
    expect(find.text('AM/PM'), findsOneWidget);

    await tester.tap(find.byKey(const Key('end-date-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('start-time-editor')), findsNothing);
    expect(find.byKey(const Key('end-date-editor')), findsOneWidget);
  });

  testWidgets('all-day closes any open time wheel', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_buildTestApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('start-time-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('start-time-editor')), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('start-time-editor')), findsNothing);
    expect(find.byKey(const Key('start-time-button')), findsNothing);
  });
}

Widget _buildTestApp() {
  return ProviderScope(
    overrides: [
      calendarsProvider.overrideWith(
        (ref) async => [CalendarInfo.defaultCalendar()],
      ),
    ],
    child: MaterialApp(home: EventFormScreen(existingEvent: _sampleEvent)),
  );
}

final _sampleEvent = CalendarEvent(
  title: 'Team sync',
  start: DateTime(2026, 6, 18, 9, 15),
  end: DateTime(2026, 6, 18, 10, 15),
  reminderMinutes: const [],
);
