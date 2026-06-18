import 'package:flutter/material.dart';

DateTimeRange shiftDateTimeRangeStart({
  required DateTime previousStart,
  required DateTime previousEnd,
  required DateTime nextStart,
}) {
  final delta = nextStart.difference(previousStart);
  return DateTimeRange(start: nextStart, end: previousEnd.add(delta));
}
