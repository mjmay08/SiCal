import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

class _TimezoneLifecycleObserver extends WidgetsBindingObserver {
  final VoidCallback onResumed;
  _TimezoneLifecycleObserver(this.onResumed);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed();
  }
}

/// Provides the device's current IANA timezone string.
/// Re-emits whenever the app resumes from background so that any timezone
/// change made in system settings is reflected immediately on return.
final deviceTimezoneProvider = StreamProvider<String>((ref) {
  late StreamController<String> controller;

  Future<void> emit() async {
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      if (!controller.isClosed) controller.add(timezone);
    } catch (_) {}
  }

  final observer = _TimezoneLifecycleObserver(emit);
  WidgetsBinding.instance.addObserver(observer);
  controller = StreamController<String>(onListen: emit);

  ref.onDispose(() {
    WidgetsBinding.instance.removeObserver(observer);
    controller.close();
  });

  return controller.stream;
});

class TimezoneService {
  static bool _initialized = false;

  /// Initialize the timezone database. Call once at app startup.
  static void initialize() {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    _initialized = true;
  }

  /// Returns the current device IANA timezone string, e.g. "America/New_York".
  static Future<String> getDeviceTimezone() async {
    return FlutterTimezone.getLocalTimezone();
  }

  /// Convert a wall-clock [DateTime] from [fromTz] to [toTz].
  ///
  /// The [wallClock] is treated as a naive local time in [fromTz].
  /// Returns the equivalent wall-clock time in [toTz].
  static DateTime convertToTimezone(
    DateTime wallClock,
    String fromTz,
    String toTz,
  ) {
    initialize();
    final fromLocation = tz.getLocation(fromTz);
    final toLocation = tz.getLocation(toTz);
    final fromTime = tz.TZDateTime(
      fromLocation,
      wallClock.year,
      wallClock.month,
      wallClock.day,
      wallClock.hour,
      wallClock.minute,
      wallClock.second,
    );
    final toTime = tz.TZDateTime.from(fromTime, toLocation);
    return DateTime(
      toTime.year,
      toTime.month,
      toTime.day,
      toTime.hour,
      toTime.minute,
      toTime.second,
    );
  }

  /// Convert a UTC [DateTime] to the wall-clock time in [toTz].
  static DateTime convertUtcToTimezone(DateTime utcTime, String toTz) {
    initialize();
    final toLocation = tz.getLocation(toTz);
    final tz.TZDateTime result = tz.TZDateTime.from(
      utcTime.toUtc(),
      toLocation,
    );
    return DateTime(
      result.year,
      result.month,
      result.day,
      result.hour,
      result.minute,
      result.second,
    );
  }

  /// Convert [wallClock] (in [fromTz]) to the device's local timezone.
  static Future<DateTime> convertToDeviceTimezone(
    DateTime wallClock,
    String fromTz,
  ) async {
    final deviceTz = await getDeviceTimezone();
    return convertToTimezone(wallClock, fromTz, deviceTz);
  }

  /// Returns a timezone abbreviation for a given IANA timezone at [moment].
  ///
  /// E.g. "America/New_York" → "EDT" or "EST".
  static String getTimezoneAbbreviation(String tzId, DateTime moment) {
    try {
      initialize();
      final location = tz.getLocation(tzId);
      final tzTime = tz.TZDateTime(
        location,
        moment.year,
        moment.month,
        moment.day,
        moment.hour,
        moment.minute,
      );
      return tzTime.timeZoneName;
    } catch (_) {
      return tzId;
    }
  }

  /// Returns a sorted list of all IANA timezone identifiers.
  static List<String> getAllTimezones() {
    initialize();
    return tz.timeZoneDatabase.locations.keys.toList()..sort();
  }
}
