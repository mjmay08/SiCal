import 'dart:convert';

import 'event.dart';

// ---------------------------------------------------------------------------
// Recurrence frequency
// ---------------------------------------------------------------------------

enum RecurrenceFrequency { daily, weekly, monthly, yearly }

// ---------------------------------------------------------------------------
// RecurrenceRule — stored as JSON in CalendarEvent.recurrenceRule
// ---------------------------------------------------------------------------

class RecurrenceRule {
  final RecurrenceFrequency freq;
  final int interval; // every N freq units
  final List<int>? byDay; // 1=Mon..7=Sun (ISO weekday) — for weekly
  final int? byMonthDay; // 1–31 — for monthly
  final List<String>? byDayOrdinals; // e.g. 1TH, -1MO — for monthly
  final DateTime? until; // end date (inclusive)
  final int? count; // max occurrences (null = infinite w/until or 2yr window)

  const RecurrenceRule({
    required this.freq,
    this.interval = 1,
    this.byDay,
    this.byMonthDay,
    this.byDayOrdinals,
    this.until,
    this.count,
  });

  // -----------------------------------------------------------------------
  // Serialisation
  // -----------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
    'freq': freq.name,
    'interval': interval,
    if (byDay != null) 'byDay': byDay,
    if (byMonthDay != null) 'byMonthDay': byMonthDay,
    if (byDayOrdinals != null) 'byDayOrdinals': byDayOrdinals,
    if (until != null) 'until': until!.toIso8601String(),
    if (count != null) 'count': count,
  };

  String encode() => jsonEncode(toJson());

  factory RecurrenceRule.fromJson(Map<String, dynamic> json) {
    return RecurrenceRule(
      freq: RecurrenceFrequency.values.byName(json['freq'] as String),
      interval: json['interval'] as int? ?? 1,
      byDay: (json['byDay'] as List<dynamic>?)?.cast<int>(),
      byMonthDay: json['byMonthDay'] as int?,
      byDayOrdinals: (json['byDayOrdinals'] as List<dynamic>?)?.cast<String>(),
      until: json['until'] != null
          ? DateTime.parse(json['until'] as String)
          : null,
      count: json['count'] as int?,
    );
  }

  factory RecurrenceRule.decode(String data) =>
      RecurrenceRule.fromJson(jsonDecode(data) as Map<String, dynamic>);

  // -----------------------------------------------------------------------
  // Human-readable label
  // -----------------------------------------------------------------------

  String toReadableString() {
    final buf = StringBuffer();
    if (interval == 1) {
      switch (freq) {
        case RecurrenceFrequency.daily:
          buf.write('Daily');
        case RecurrenceFrequency.weekly:
          buf.write('Weekly');
        case RecurrenceFrequency.monthly:
          buf.write('Monthly');
        case RecurrenceFrequency.yearly:
          buf.write('Yearly');
      }
    } else {
      buf.write('Every $interval ');
      switch (freq) {
        case RecurrenceFrequency.daily:
          buf.write('days');
        case RecurrenceFrequency.weekly:
          buf.write('weeks');
        case RecurrenceFrequency.monthly:
          buf.write('months');
        case RecurrenceFrequency.yearly:
          buf.write('years');
      }
    }
    if (byDay != null && byDay!.isNotEmpty) {
      buf.write(' on ${_byDayLabel(byDay!)}');
    }
    if (until != null) {
      buf.write(' until ${until!.month}/${until!.day}/${until!.year}');
    } else if (count != null) {
      buf.write(', $count times');
    }
    return buf.toString();
  }

  static const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static String _byDayLabel(List<int> days) =>
      days.map((d) => _dayNames[(d - 1).clamp(0, 6)]).join(', ');

  // -----------------------------------------------------------------------
  // Copy
  // -----------------------------------------------------------------------

  RecurrenceRule copyWith({
    RecurrenceFrequency? freq,
    int? interval,
    Object? byDay = _sentinel,
    Object? byMonthDay = _sentinel,
    Object? byDayOrdinals = _sentinel,
    Object? until = _sentinel,
    Object? count = _sentinel,
  }) => RecurrenceRule(
    freq: freq ?? this.freq,
    interval: interval ?? this.interval,
    byDay: byDay == _sentinel ? this.byDay : byDay as List<int>?,
    byMonthDay: byMonthDay == _sentinel ? this.byMonthDay : byMonthDay as int?,
    byDayOrdinals: byDayOrdinals == _sentinel
        ? this.byDayOrdinals
        : byDayOrdinals as List<String>?,
    until: until == _sentinel ? this.until : until as DateTime?,
    count: count == _sentinel ? this.count : count as int?,
  );
}

const _sentinel = Object();

// ---------------------------------------------------------------------------
// RecurrenceEngine — expands a master event into virtual instances
// ---------------------------------------------------------------------------

class RecurrenceEngine {
  RecurrenceEngine._();

  /// Maximum look-ahead window when neither `until` nor `count` is set.
  static const _maxWindow = Duration(days: 365 * 2);

  /// Expand [master] into virtual instances that fall within [from]..[to].
  ///
  /// [exceptions] are persisted overrides / cancellations keyed by the
  /// ISO-8601 string of the original instance start they replace.
  static List<CalendarEvent> expand(
    CalendarEvent master,
    DateTime from,
    DateTime to, {
    Map<String, CalendarEvent> exceptions = const {},
  }) {
    if (master.recurrenceRule == null) return [];

    final rule = RecurrenceRule.decode(master.recurrenceRule!);
    final duration = master.end.difference(master.start);
    final results = <CalendarEvent>[];

    final effectiveEnd = _effectiveEnd(rule, master.start, to);
    var occurrence = 0;

    for (final instanceStart in _dates(rule, master.start, effectiveEnd)) {
      occurrence++;
      if (rule.count != null && occurrence > rule.count!) break;

      final instanceEnd = instanceStart.add(duration);

      // Skip if entirely outside the query window.
      if (instanceEnd.isBefore(from) || instanceStart.isAfter(to)) continue;

      final key = instanceStart.toIso8601String();
      final exception = exceptions[key];

      if (exception != null) {
        if (exception.isCancelled) continue; // deleted occurrence
        // Use exception with instanceStart tag.
        results.add(exception.copyWith(instanceStart: instanceStart));
      } else {
        // Virtual instance derived from master.
        results.add(
          master.copyWith(
            start: instanceStart,
            end: instanceEnd,
            isDirty: false,
            instanceStart: instanceStart,
          ),
        );
      }
    }

    return results;
  }

  // -----------------------------------------------------------------------
  // Private helpers
  // -----------------------------------------------------------------------

  static DateTime _effectiveEnd(
    RecurrenceRule rule,
    DateTime masterStart,
    DateTime queryEnd,
  ) {
    final maxEnd = masterStart.add(_maxWindow);
    DateTime end = queryEnd.isAfter(maxEnd) ? maxEnd : queryEnd;
    if (rule.until != null) {
      // Extend until to end-of-day so instances on the until date are included
      // regardless of their time-of-day.
      final untilEod = DateTime(
        rule.until!.year,
        rule.until!.month,
        rule.until!.day,
        23,
        59,
        59,
      );
      if (untilEod.isBefore(end)) end = untilEod;
    }
    return end;
  }

  /// Generates raw occurrence start dates (unfiltered).
  static Iterable<DateTime> _dates(
    RecurrenceRule rule,
    DateTime start,
    DateTime end,
  ) sync* {
    switch (rule.freq) {
      case RecurrenceFrequency.daily:
        yield* _dailyDates(start, end, rule.interval);
      case RecurrenceFrequency.weekly:
        yield* _weeklyDates(start, end, rule.interval, rule.byDay);
      case RecurrenceFrequency.monthly:
        yield* _monthlyDates(
          start,
          end,
          rule.interval,
          rule.byMonthDay,
          rule.byDayOrdinals,
        );
      case RecurrenceFrequency.yearly:
        yield* _yearlyDates(start, end, rule.interval);
    }
  }

  static Iterable<DateTime> _dailyDates(
    DateTime start,
    DateTime end,
    int interval,
  ) sync* {
    var d = start;
    while (!d.isAfter(end)) {
      yield d;
      d = d.add(Duration(days: interval));
    }
  }

  static Iterable<DateTime> _weeklyDates(
    DateTime start,
    DateTime end,
    int interval,
    List<int>? byDay,
  ) sync* {
    if (byDay == null || byDay.isEmpty) {
      // Treat as same weekday as start.
      var d = start;
      while (!d.isAfter(end)) {
        yield d;
        d = d.add(Duration(days: 7 * interval));
      }
      return;
    }

    // Walk week by week; within each week emit requested days.
    final sortedDays = [...byDay]..sort();
    // Find start of the week (Monday) of the master start.
    var weekStart = start.subtract(Duration(days: start.weekday - 1));

    while (!weekStart.isAfter(end)) {
      for (final day in sortedDays) {
        final d = DateTime(
          weekStart.year,
          weekStart.month,
          weekStart.day + (day - 1),
          start.hour,
          start.minute,
          start.second,
        );
        if (d.isBefore(start)) continue;
        if (d.isAfter(end)) return;
        yield d;
      }
      weekStart = weekStart.add(Duration(days: 7 * interval));
    }
  }

  static Iterable<DateTime> _monthlyDates(
    DateTime start,
    DateTime end,
    int interval,
    int? byMonthDay,
    List<String>? byDayOrdinals,
  ) sync* {
    var year = start.year;
    var month = start.month;

    while (true) {
      final monthDates = <DateTime>[];

      if (byDayOrdinals != null && byDayOrdinals.isNotEmpty) {
        monthDates.addAll(
          _datesForMonthlyByDayOrdinals(start, year, month, byDayOrdinals),
        );
      } else {
        final day = byMonthDay ?? start.day;
        final daysInMonth = DateTime(year, month + 1, 0).day;
        final clampedDay = day > daysInMonth ? daysInMonth : day;
        monthDates.add(
          DateTime(
            year,
            month,
            clampedDay,
            start.hour,
            start.minute,
            start.second,
          ),
        );
      }

      if (monthDates.isEmpty) {
        month += interval;
        while (month > 12) {
          month -= 12;
          year++;
        }
        continue;
      }

      monthDates.sort();
      DateTime? lastYielded;
      for (final d in monthDates) {
        if (d.isAfter(end)) return;
        if (d.isBefore(start)) continue;
        if (lastYielded != null && d.isAtSameMomentAs(lastYielded)) continue;
        yield d;
        lastYielded = d;
      }

      month += interval;
      while (month > 12) {
        month -= 12;
        year++;
      }
    }
  }

  static List<DateTime> _datesForMonthlyByDayOrdinals(
    DateTime template,
    int year,
    int month,
    List<String> byDayOrdinals,
  ) {
    const weekdayMap = <String, int>{
      'MO': DateTime.monday,
      'TU': DateTime.tuesday,
      'WE': DateTime.wednesday,
      'TH': DateTime.thursday,
      'FR': DateTime.friday,
      'SA': DateTime.saturday,
      'SU': DateTime.sunday,
    };

    final dates = <DateTime>[];
    final daysInMonth = DateTime(year, month + 1, 0).day;

    for (final token in byDayOrdinals) {
      final m = RegExp(
        r'^([+-]?\d+)(MO|TU|WE|TH|FR|SA|SU)$',
      ).firstMatch(token.toUpperCase());
      if (m == null) continue;

      final ordinal = int.tryParse(m.group(1)!);
      final weekday = weekdayMap[m.group(2)!];
      if (ordinal == null || weekday == null || ordinal == 0) continue;

      int? day;
      if (ordinal > 0) {
        final firstOfMonth = DateTime(year, month, 1);
        final offset = (weekday - firstOfMonth.weekday + 7) % 7;
        final candidate = 1 + offset + ((ordinal - 1) * 7);
        if (candidate <= daysInMonth) day = candidate;
      } else {
        final lastOfMonth = DateTime(year, month, daysInMonth);
        final offsetFromEnd = (lastOfMonth.weekday - weekday + 7) % 7;
        final candidate = daysInMonth - offsetFromEnd + ((ordinal + 1) * 7);
        if (candidate >= 1) day = candidate;
      }

      if (day == null) continue;
      dates.add(
        DateTime(
          year,
          month,
          day,
          template.hour,
          template.minute,
          template.second,
        ),
      );
    }

    return dates;
  }

  static Iterable<DateTime> _yearlyDates(
    DateTime start,
    DateTime end,
    int interval,
  ) sync* {
    var year = start.year;
    while (true) {
      final daysInMonth = DateTime(year, start.month + 1, 0).day;
      final clampedDay = start.day > daysInMonth ? daysInMonth : start.day;
      final d = DateTime(
        year,
        start.month,
        clampedDay,
        start.hour,
        start.minute,
        start.second,
      );

      if (d.isAfter(end)) break;
      if (!d.isBefore(start)) yield d;

      year += interval;
    }
  }
}
