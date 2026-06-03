import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:icalendar_parser/icalendar_parser.dart';

import '../models/event.dart';
import '../models/recurrence.dart';
import '../repositories/calendar_repository.dart';
import 'timezone_service.dart';

class IcsImportResult {
  final int importedCount;
  final int skippedCount;

  const IcsImportResult({
    required this.importedCount,
    required this.skippedCount,
  });
}

class IcsDraftParseResult {
  final List<CalendarEvent> drafts;
  final int skippedCount;

  const IcsDraftParseResult({required this.drafts, required this.skippedCount});
}

class IcsImportService {
  IcsImportService(this._repository);

  final CalendarRepository _repository;

  static bool _customFieldsRegistered = false;

  static const XTypeGroup _icsTypeGroup = XTypeGroup(
    label: 'iCalendar',
    extensions: <String>['ics', 'ical', 'ifb', 'vcs'],
    mimeTypes: <String>['text/calendar', 'application/octet-stream'],
  );

  Future<IcsImportResult?> importFromPicker() async {
    final file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[_icsTypeGroup],
    );
    if (file == null) return null;

    final icsString = await file.readAsString();
    return importFromString(icsString);
  }

  IcsDraftParseResult parseDraftsFromString(String icsString) {
    final parsed = _parseCalendarData(icsString);
    return IcsDraftParseResult(
      drafts: parsed.masters,
      skippedCount: parsed.skippedCount,
    );
  }

  IcsImportResult importFromString(String icsString) {
    final parsed = _parseCalendarData(icsString);
    var importedCount = 0;
    final mastersByUid = <String, CalendarEvent>{};

    for (final imported in parsed.masters) {
      final uid = _uidFromEventId(imported.id);
      if (uid == null) {
        continue;
      }

      _repository.createEvent(imported, refreshNotifications: false);
      mastersByUid[uid] = imported;
      importedCount++;
    }

    for (final exdate in parsed.exdates) {
      final master =
          mastersByUid[exdate.uid] ??
          _repository.getMasterEvent(_eventIdFromUid(exdate.uid));
      if (master == null) {
        continue;
      }

      _repository.createEvent(
        master.copyWith(
          id: _cancelledOccurrenceId(exdate.uid, exdate.originalStart),
          recurrenceRule: null,
          masterEventId: master.id,
          originalStart: exdate.originalStart.toIso8601String(),
          isCancelled: true,
          isDirty: true,
          instanceStart: null,
        ),
        refreshNotifications: false,
      );
      importedCount++;
    }

    for (final override in parsed.overrides) {
      final master =
          mastersByUid[override.uid] ??
          _repository.getMasterEvent(_eventIdFromUid(override.uid));
      if (master == null) {
        continue;
      }

      final calendarTimezone = _repository.getCalendarTimezone();

      if (override.component['status'] == IcsStatus.cancelled) {
        _repository.createEvent(
          master.copyWith(
            id: _cancelledOccurrenceId(override.uid, override.recurrenceId),
            recurrenceRule: null,
            masterEventId: master.id,
            originalStart: override.recurrenceId.toIso8601String(),
            isCancelled: true,
            isDirty: true,
            instanceStart: null,
          ),
          refreshNotifications: false,
        );
        importedCount++;
        continue;
      }

      final imported = _calendarEventFromComponent(
        override.component,
        override.uid,
        calendarTimezone,
      );
      if (imported == null) {
        continue;
      }

      _repository.createEvent(
        imported.copyWith(
          id: _overrideOccurrenceId(override.uid, override.recurrenceId),
          recurrenceRule: null,
          masterEventId: master.id,
          originalStart: override.recurrenceId.toIso8601String(),
          isCancelled: false,
          isDirty: true,
          instanceStart: null,
        ),
        refreshNotifications: false,
      );
      importedCount++;
    }

    if (importedCount > 0) {
      _repository.refreshNotifications();
    }

    return IcsImportResult(
      importedCount: importedCount,
      skippedCount: parsed.skippedCount,
    );
  }

  _ParsedIcsData _parseCalendarData(String icsString) {
    _registerCustomFields();
    final calendar = ICalendar.fromString(icsString);
    final calendarTimezone = _repository.getCalendarTimezone();

    var skippedCount = 0;
    final masters = <CalendarEvent>[];
    final exdates = <_ImportedExdate>[];
    final overrides = <_ImportedOverride>[];

    for (final component in calendar.data) {
      if (component['type'] != 'VEVENT') {
        skippedCount++;
        continue;
      }

      if (component['status'] == IcsStatus.cancelled &&
          component['recurrenceId'] == null) {
        skippedCount++;
        continue;
      }

      final uid = (component['uid'] as String?)?.trim();
      final dtstart = _dateTimeFromField(component['dtstart']);
      if (uid == null || uid.isEmpty || dtstart == null) {
        skippedCount++;
        continue;
      }

      final recurrenceId = _dateTimeFromField(component['recurrenceId']);
      if (recurrenceId != null) {
        overrides.add(
          _ImportedOverride(
            component: component,
            uid: uid,
            recurrenceId: recurrenceId,
          ),
        );
        continue;
      }

      final imported = _calendarEventFromComponent(
        component,
        uid,
        calendarTimezone,
      );
      if (imported == null) {
        skippedCount++;
        continue;
      }

      masters.add(imported);

      final componentExdates = component['exdate'];
      if (componentExdates is List) {
        for (final exdate in componentExdates) {
          final originalStart = _dateTimeFromField(exdate);
          if (originalStart == null) {
            skippedCount++;
            continue;
          }
          exdates.add(_ImportedExdate(uid: uid, originalStart: originalStart));
        }
      }
    }

    return _ParsedIcsData(
      masters: masters,
      overrides: overrides,
      exdates: exdates,
      skippedCount: skippedCount,
    );
  }

  static void _registerCustomFields() {
    if (_customFieldsRegistered) return;

    if (!ICalendar.objects.containsKey('RECURRENCE-ID')) {
      ICalendar.registerField(
        field: 'RECURRENCE-ID',
        function: (value, params, _, lastEvent) {
          lastEvent['recurrenceId'] = IcsDateTime(
            dt: value,
            tzid: params['TZID'],
          );
          return lastEvent;
        },
      );
    }

    if (!ICalendar.objects.containsKey('DURATION')) {
      ICalendar.registerField(
        field: 'DURATION',
        function: (value, params, _, lastEvent) {
          lastEvent['duration'] = value;
          return lastEvent;
        },
      );
    }

    _customFieldsRegistered = true;
  }

  CalendarEvent? _calendarEventFromComponent(
    Map<String, dynamic> component,
    String uid,
    String calendarTimezone,
  ) {
    final startField = _parseIcsField(component['dtstart']);
    if (startField == null) return null;

    final isAllDay = _isAllDayField(component['dtstart']);

    // Determine timezone and adjust start wall-clock time.
    String? eventTimezone;
    DateTime startDt = startField.dt;
    if (!isAllDay) {
      if (startField.tzid != null && startField.tzid!.isNotEmpty) {
        // TZID present: wall-clock time in the specified timezone.
        eventTimezone = startField.tzid;
      } else if (startField.isUtc) {
        // Z suffix: UTC time — convert to calendar default timezone wall-clock.
        eventTimezone = calendarTimezone;
        startDt = TimezoneService.convertUtcToTimezone(
          startField.dt,
          calendarTimezone,
        );
      }
      // else: neither TZID nor Z — floating event, null timezone.
    }

    // Resolve end time.
    DateTime? endDt;
    final endField = _parseIcsField(component['dtend']);
    if (endField != null) {
      if (!isAllDay && startField.isUtc && eventTimezone != null) {
        endDt = TimezoneService.convertUtcToTimezone(
          endField.dt,
          eventTimezone,
        );
      } else {
        endDt = endField.dt;
      }
    }

    // Fall back to DURATION when DTEND is absent (RFC 5545 §3.6.1).
    if (endDt == null) {
      final dur = _parseDuration(component['duration'] as String?);
      if (dur != null) endDt = startDt.add(dur);
    }

    final end = _resolveEnd(start: startDt, end: endDt, isAllDay: isAllDay);
    if (end.isBefore(startDt)) return null;

    final rawDescription = (component['description'] as String?)?.trim() ?? '';
    final rawUrl = (component['url'] as String?)?.trim() ?? '';
    final fullDescription = [
      rawDescription,
      rawUrl,
    ].where((s) => s.isNotEmpty).join('\n');

    return CalendarEvent(
      id: _eventIdFromUid(uid),
      title: ((component['summary'] as String?)?.trim().isNotEmpty ?? false)
          ? (component['summary'] as String).trim()
          : 'Untitled event',
      description: fullDescription,
      start: startDt,
      end: end,
      allDay: isAllDay,
      recurrenceRule: _parseRRule(component['rrule'] as String?),
      reminderMinutes: _repository.getDefaultEventReminderMinutes(),
      location: (component['location'] as String?)?.trim() ?? '',
      timezone: eventTimezone,
      isDirty: true,
    );
  }

  static String _eventIdFromUid(String uid) => 'ics:$uid';

  static String? _uidFromEventId(String eventId) {
    if (!eventId.startsWith('ics:')) return null;
    return eventId.substring(4);
  }

  static String _cancelledOccurrenceId(String uid, DateTime recurrenceId) =>
      'ics:$uid:cancel:${recurrenceId.toIso8601String()}';

  static String _overrideOccurrenceId(String uid, DateTime recurrenceId) =>
      'ics:$uid:override:${recurrenceId.toIso8601String()}';

  static bool _isAllDayField(Object? field) {
    if (field is IcsDateTime) return !field.dt.contains('T');
    if (field is Map<String, dynamic>) {
      final dt = field['dt'];
      return dt is String && !dt.contains('T');
    }
    return false;
  }

  static DateTime _resolveEnd({
    required DateTime start,
    required DateTime? end,
    required bool isAllDay,
  }) {
    if (end != null) {
      if (isAllDay) {
        final adjusted = end.subtract(const Duration(minutes: 1));
        return adjusted.isBefore(start)
            ? DateTime(start.year, start.month, start.day, 23, 59)
            : adjusted;
      }
      return end;
    }

    if (isAllDay) {
      return DateTime(start.year, start.month, start.day, 23, 59);
    }

    return start.add(const Duration(hours: 1));
  }

  static DateTime? _dateTimeFromField(Object? field) {
    return _parseIcsField(field)?.dt;
  }

  /// Parses an ICS datetime field, returning both the wall-clock [DateTime]
  /// and metadata: the [tzid] string if present and whether the value was UTC
  /// (Z suffix).
  static _IcsFieldResult? _parseIcsField(Object? field) {
    if (field is IcsDateTime) {
      final result = _parseIcsDateTimeFull(field.dt);
      if (result == null) return null;
      return _IcsFieldResult(
        dt: result.$1,
        tzid: (field.tzid != null && field.tzid!.isNotEmpty)
            ? field.tzid
            : null,
        isUtc: result.$2,
      );
    }
    if (field is Map<String, dynamic>) {
      final dt = field['dt'];
      final tzid = field['tzid'] as String?;
      if (dt is String) {
        final result = _parseIcsDateTimeFull(dt);
        if (result == null) return null;
        return _IcsFieldResult(
          dt: result.$1,
          tzid: (tzid != null && tzid.isNotEmpty) ? tzid : null,
          isUtc: result.$2,
        );
      }
    }
    return null;
  }

  /// Parse an ICS datetime string and return (wallClockDt, isUtc).
  /// For Z-suffix values, returns the UTC [DateTime] and isUtc=true.
  /// The caller is responsible for any timezone conversion.
  static (DateTime, bool)? _parseIcsDateTimeFull(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    final isUtc = value.endsWith('Z');
    final normalized = isUtc ? value.substring(0, value.length - 1) : value;

    if (!normalized.contains('T')) {
      if (normalized.length != 8) return null;
      final year = int.tryParse(normalized.substring(0, 4));
      final month = int.tryParse(normalized.substring(4, 6));
      final day = int.tryParse(normalized.substring(6, 8));
      if (year == null || month == null || day == null) return null;
      return (DateTime(year, month, day), false);
    }

    final parts = normalized.split('T');
    if (parts.length != 2 || parts[0].length != 8 || parts[1].length < 4) {
      return null;
    }

    final year = int.tryParse(parts[0].substring(0, 4));
    final month = int.tryParse(parts[0].substring(4, 6));
    final day = int.tryParse(parts[0].substring(6, 8));
    final hour = int.tryParse(parts[1].substring(0, 2));
    final minute = int.tryParse(parts[1].substring(2, 4));
    final second = parts[1].length >= 6
        ? int.tryParse(parts[1].substring(4, 6))
        : 0;

    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }

    return isUtc
        ? (DateTime.utc(year, month, day, hour, minute, second), true)
        : (DateTime(year, month, day, hour, minute, second), false);
  }

  /// Legacy wrapper used for RRULE UNTIL parsing. Z-suffix values are
  /// converted to local time (matching prior behavior).
  static DateTime? _parseIcsDateTime(String raw) {
    final result = _parseIcsDateTimeFull(raw);
    if (result == null) return null;
    final (dt, isUtc) = result;
    return isUtc ? dt.toLocal() : dt;
  }

  static String? _parseRRule(String? rrule) {
    if (rrule == null || rrule.trim().isEmpty) return null;

    final segments = <String, String>{};
    for (final segment in rrule.split(';')) {
      final parts = segment.split('=');
      if (parts.length == 2) {
        segments[parts[0].toUpperCase()] = parts[1];
      }
    }

    final freq = _parseFrequency(segments['FREQ']);
    if (freq == null) return null;

    return RecurrenceRule(
      freq: freq,
      interval: int.tryParse(segments['INTERVAL'] ?? '') ?? 1,
      byDay: _parseByDay(segments['BYDAY']),
      byMonthDay: int.tryParse(segments['BYMONTHDAY'] ?? ''),
      until: _parseIcsDateTime(segments['UNTIL'] ?? ''),
      count: int.tryParse(segments['COUNT'] ?? ''),
    ).encode();
  }

  static RecurrenceFrequency? _parseFrequency(String? value) {
    switch (value?.toUpperCase()) {
      case 'DAILY':
        return RecurrenceFrequency.daily;
      case 'WEEKLY':
        return RecurrenceFrequency.weekly;
      case 'MONTHLY':
        return RecurrenceFrequency.monthly;
      case 'YEARLY':
        return RecurrenceFrequency.yearly;
      default:
        return null;
    }
  }

  static List<int>? _parseByDay(String? value) {
    if (value == null || value.isEmpty) return null;

    const weekdayMap = <String, int>{
      'MO': DateTime.monday,
      'TU': DateTime.tuesday,
      'WE': DateTime.wednesday,
      'TH': DateTime.thursday,
      'FR': DateTime.friday,
      'SA': DateTime.saturday,
      'SU': DateTime.sunday,
    };

    final days = value
        .split(',')
        .map(
          (entry) => entry.replaceAll(RegExp(r'^[-+]?\d+'), '').toUpperCase(),
        )
        .map((entry) => weekdayMap[entry])
        .whereType<int>()
        .toList();

    return days.isEmpty ? null : days;
  }

  /// Parses an RFC 5545 DURATION value (e.g. `PT1H30M`, `P1D`, `P1W`) into
  /// a [Duration]. Returns null if the value is absent or malformed.
  static Duration? _parseDuration(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    var s = raw.trim().toUpperCase();
    // Strip optional leading sign (we don't support negative durations).
    if (s.startsWith('+') || s.startsWith('-')) s = s.substring(1);
    if (!s.startsWith('P')) return null;
    s = s.substring(1); // remove 'P'

    // Week-only form: nW
    final weekMatch = RegExp(r'^(\d+)W$').firstMatch(s);
    if (weekMatch != null) {
      final weeks = int.tryParse(weekMatch.group(1)!);
      return weeks != null ? Duration(days: weeks * 7) : null;
    }

    // General form: [nD][T[nH][nM][nS]]
    final tIndex = s.indexOf('T');
    final datePart = tIndex >= 0 ? s.substring(0, tIndex) : s;
    final timePart = tIndex >= 0 ? s.substring(tIndex + 1) : '';

    int days = 0, hours = 0, minutes = 0, seconds = 0;
    final dayMatch = RegExp(r'(\d+)D').firstMatch(datePart);
    if (dayMatch != null) days = int.tryParse(dayMatch.group(1)!) ?? 0;
    final hourMatch = RegExp(r'(\d+)H').firstMatch(timePart);
    if (hourMatch != null) hours = int.tryParse(hourMatch.group(1)!) ?? 0;
    final minMatch = RegExp(r'(\d+)M').firstMatch(timePart);
    if (minMatch != null) minutes = int.tryParse(minMatch.group(1)!) ?? 0;
    final secMatch = RegExp(r'(\d+)S').firstMatch(timePart);
    if (secMatch != null) seconds = int.tryParse(secMatch.group(1)!) ?? 0;

    if (days == 0 && hours == 0 && minutes == 0 && seconds == 0) return null;
    return Duration(
      days: days,
      hours: hours,
      minutes: minutes,
      seconds: seconds,
    );
  }
}

class _ImportedOverride {
  final Map<String, dynamic> component;
  final String uid;
  final DateTime recurrenceId;

  const _ImportedOverride({
    required this.component,
    required this.uid,
    required this.recurrenceId,
  });
}

class _ImportedExdate {
  final String uid;
  final DateTime originalStart;

  const _ImportedExdate({required this.uid, required this.originalStart});
}

class _ParsedIcsData {
  final List<CalendarEvent> masters;
  final List<_ImportedOverride> overrides;
  final List<_ImportedExdate> exdates;
  final int skippedCount;

  const _ParsedIcsData({
    required this.masters,
    required this.overrides,
    required this.exdates,
    required this.skippedCount,
  });
}

/// Result of parsing a single ICS datetime field, including timezone metadata.
class _IcsFieldResult {
  final DateTime dt;
  final String? tzid;
  final bool isUtc;

  const _IcsFieldResult({required this.dt, this.tzid, this.isUtc = false});
}
