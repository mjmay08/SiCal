import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sical/src/utils/event_time_range_adjustment.dart';

void main() {
  test('shifts end time by the same delta as the start time', () {
    final adjustedRange = shiftDateTimeRangeStart(
      previousStart: DateTime(2026, 1, 1, 8),
      previousEnd: DateTime(2026, 1, 1, 10),
      nextStart: DateTime(2026, 1, 1, 9),
    );

    expect(
      adjustedRange,
      DateTimeRange(
        start: DateTime(2026, 1, 1, 9),
        end: DateTime(2026, 1, 1, 11),
      ),
    );
  });

  test('shifts the end date when the start change crosses midnight', () {
    final adjustedRange = shiftDateTimeRangeStart(
      previousStart: DateTime(2026, 1, 1, 23),
      previousEnd: DateTime(2026, 1, 2, 1),
      nextStart: DateTime(2026, 1, 2, 0),
    );

    expect(
      adjustedRange,
      DateTimeRange(
        start: DateTime(2026, 1, 2, 0),
        end: DateTime(2026, 1, 2, 2),
      ),
    );
  });
}
