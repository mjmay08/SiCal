import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../database/database.dart';
import '../models/event.dart';
import '../repositories/calendar_repository.dart';
import '../utils/reminder_time_format.dart';
import 'timezone_service.dart';

class EventNotificationService {
  EventNotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final StreamController<String> _tapController =
      StreamController<String>.broadcast();
  static Future<void>? _initFuture;
  static Future<void> _refreshChain = Future<void>.value();
  static String? _pendingTapPayload;

  static Stream<String> get notificationTapStream => _tapController.stream;

  static String? consumePendingTapPayload() {
    final payload = _pendingTapPayload;
    _pendingTapPayload = null;
    return payload;
  }

  static Future<void> initialize() {
    _initFuture ??= _initialize();
    return _initFuture!;
  }

  static Future<void> clearAll() async {
    await initialize();
    await _plugin.cancelAll();
  }

  static Future<void> rescheduleAll(AppDatabase db) {
    _refreshChain = _refreshChain.then((_) => _rescheduleAll(db));
    return _refreshChain;
  }

  static Future<void> _initialize() async {
    TimezoneService.initialize();
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/launcher_icon'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        _pendingTapPayload = payload;
        _tapController.add(payload);
      },
    );

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    final launchPayload = launchDetails?.notificationResponse?.payload;
    if ((launchDetails?.didNotificationLaunchApp ?? false) &&
        launchPayload != null &&
        launchPayload.isNotEmpty) {
      _pendingTapPayload = launchPayload;
    }
  }

  static Future<void> _rescheduleAll(AppDatabase db) async {
    try {
      await initialize();
      await _requestPermissions();
      await _plugin.cancelAll();

      final repository = CalendarRepository(db);
      final visibleCalendars = repository.getVisibleCalendars();
      final calendarIds = visibleCalendars.isEmpty
          ? <String>[kDefaultCalendarId]
          : visibleCalendars.map((calendar) => calendar.id).toList();

      final now = DateTime.now();
      final events = repository.getEventsInRange(
        now,
        now.add(const Duration(days: 365)),
        calendarIds: calendarIds,
      );

      final deviceTimezone = await TimezoneService.getDeviceTimezone();
      final deviceLocation = tz.getLocation(deviceTimezone);
      final nowZoned = tz.TZDateTime.now(deviceLocation);
      final immediateGraceStart = nowZoned.subtract(const Duration(minutes: 1));

      for (final event in events) {
        if (event.isCancelled || event.reminderMinutes.isEmpty) continue;

        final eventStart = _notificationStart(event, deviceTimezone);
        final scheduledStart = tz.TZDateTime(
          deviceLocation,
          eventStart.year,
          eventStart.month,
          eventStart.day,
          eventStart.hour,
          eventStart.minute,
          eventStart.second,
        );

        for (final reminderMinutes in event.reminderMinutes) {
          if (reminderMinutes < 0) continue;
          final notificationTime = scheduledStart.subtract(
            Duration(minutes: reminderMinutes),
          );
          final id = _notificationId(event, eventStart, reminderMinutes);
          if (!notificationTime.isAfter(nowZoned)) {
            // "At start" often lands exactly on current time. Trigger once
            // immediately when we're within a short grace window.
            if (reminderMinutes == 0 &&
                notificationTime.isAfter(immediateGraceStart)) {
              try {
                await _plugin.show(
                  id,
                  event.title,
                  _buildBody(event, reminderMinutes),
                  const NotificationDetails(
                    android: AndroidNotificationDetails(
                      'sia_event_alerts',
                      'Event Alerts',
                      channelDescription:
                          'Notifications for upcoming calendar events.',
                      importance: Importance.high,
                      priority: Priority.high,
                    ),
                    iOS: DarwinNotificationDetails(),
                  ),
                  payload: event.id,
                );
              } catch (_) {
                // Keep scheduling resilient if one immediate alert fails.
              }
            }
            continue;
          }

          try {
            await _plugin.zonedSchedule(
              id,
              event.title,
              _buildBody(event, reminderMinutes),
              notificationTime,
              const NotificationDetails(
                android: AndroidNotificationDetails(
                  'sia_event_alerts',
                  'Event Alerts',
                  channelDescription:
                      'Notifications for upcoming calendar events.',
                  importance: Importance.high,
                  priority: Priority.high,
                ),
                iOS: DarwinNotificationDetails(),
              ),
              payload: event.id,
              androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
              uiLocalNotificationDateInterpretation:
                  UILocalNotificationDateInterpretation.absoluteTime,
            );
          } catch (_) {
            // Fallback where exact scheduling is unavailable.
            try {
              await _plugin.zonedSchedule(
                id,
                event.title,
                _buildBody(event, reminderMinutes),
                notificationTime,
                const NotificationDetails(
                  android: AndroidNotificationDetails(
                    'sia_event_alerts',
                    'Event Alerts',
                    channelDescription:
                        'Notifications for upcoming calendar events.',
                    importance: Importance.high,
                    priority: Priority.high,
                  ),
                  iOS: DarwinNotificationDetails(),
                ),
                payload: event.id,
                androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
                uiLocalNotificationDateInterpretation:
                    UILocalNotificationDateInterpretation.absoluteTime,
              );
            } catch (_) {
              // Ignore per-item failure and continue with remaining reminders.
            }
          }
        }
      }
    } catch (_) {
      // Best-effort scheduling keeps the calendar usable if notification
      // setup is temporarily unavailable on the platform.
    }
  }

  static Future<void> _requestPermissions() async {
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImpl?.requestNotificationsPermission();
    await androidImpl?.requestExactAlarmsPermission();

    final darwinImpl = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    await darwinImpl?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static DateTime _notificationStart(
    CalendarEvent event,
    String deviceTimezone,
  ) {
    final occurrenceStart = event.instanceStart ?? event.start;
    if (event.allDay || event.timezone == null) return occurrenceStart;
    return TimezoneService.convertToTimezone(
      occurrenceStart,
      event.timezone!,
      deviceTimezone,
    );
  }

  static String _buildBody(CalendarEvent event, int reminderMinutes) {
    if (reminderMinutes == 0) {
      if (event.location.isEmpty) return 'Starts now';
      return 'Starts now at ${event.location}';
    }

    final when = formatReminderLeadTime(reminderMinutes);
    if (event.location.isEmpty) return 'Starts in $when';
    return 'Starts in $when at ${event.location}';
  }

  static int _notificationId(
    CalendarEvent event,
    DateTime occurrenceStart,
    int reminderMinutes,
  ) {
    return _fnv1a32(
          '${event.id}|${occurrenceStart.toIso8601String()}|$reminderMinutes',
        ) &
        0x7fffffff;
  }

  static int _fnv1a32(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}
