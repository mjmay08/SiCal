import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/event.dart';
import '../../models/recurrence.dart';
import '../../repositories/calendar_repository.dart';
import '../../services/timezone_service.dart';
import 'event_form_screen.dart';

class EventDetailScreen extends ConsumerStatefulWidget {
  final CalendarEvent event;

  const EventDetailScreen({super.key, required this.event});

  @override
  ConsumerState<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends ConsumerState<EventDetailScreen> {
  DateTime? _displayStart;
  DateTime? _displayEnd;
  String? _deviceTz;

  CalendarEvent get event => widget.event;

  @override
  void initState() {
    super.initState();
    _initDisplayTimes();
  }

  Future<void> _initDisplayTimes() async {
    if (event.timezone == null || event.allDay) return;
    try {
      final tz = await TimezoneService.getDeviceTimezone();
      final start = TimezoneService.convertToTimezone(
        event.start,
        event.timezone!,
        tz,
      );
      final end = TimezoneService.convertToTimezone(
        event.end,
        event.timezone!,
        tz,
      );
      if (mounted) {
        setState(() {
          _displayStart = start;
          _displayEnd = end;
          _deviceTz = tz;
        });
      }
    } catch (_) {
      // Conversion failed — fall back to stored wall-clock time.
    }
  }

  @override
  Widget build(BuildContext context) {
    final calendarLookup = ref.watch(calendarLookupProvider).value ?? const {};
    final calendar = calendarLookup[event.calendarId];
    final start = _displayStart ?? event.start;
    final end = _displayEnd ?? event.end;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Event'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () => _editEvent(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => _deleteEvent(context, ref),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              event.title,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            _InfoRow(
              icon: Icons.access_time,
              label: event.allDay
                  ? 'All day'
                  : '${_formatDateTime(start)} \u2013 ${_formatDateTime(end)}',
            ),
            if (!event.allDay && event.timezone != null) ...[
              _InfoRow(icon: Icons.language, label: _timezoneLabel(start)),
            ],
            _InfoRow(
              icon: Icons.calendar_month,
              label: calendar?.name ?? 'Calendar',
            ),
            if (event.location.isNotEmpty)
              _InfoRow(
                icon: Icons.location_on,
                label: event.location,
                onTap: _isUrl(event.location)
                    ? () => launchUrl(
                        Uri.parse(event.location),
                        mode: LaunchMode.externalApplication,
                      )
                    : null,
              ),
            if (_hasRecurrence)
              _InfoRow(icon: Icons.repeat, label: _recurrenceLabel),
            if (event.description.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Description',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(event.description),
            ],
            if (event.reminderMinutes.isNotEmpty) ...[
              const SizedBox(height: 16),
              _InfoRow(
                icon: Icons.notifications,
                label: event.reminderMinutes
                    .map((m) => '${m}min before')
                    .join(', '),
              ),
            ],
            const Spacer(),
            if (event.isDirty)
              Chip(
                avatar: const Icon(Icons.cloud_upload_outlined, size: 16),
                label: const Text('Pending sync'),
              ),
          ],
        ),
      ),
    );
  }

  /// Whether this event is part of a recurring series.
  bool get _hasRecurrence =>
      event.isRecurring || event.isException || event.isVirtualInstance;

  String get _recurrenceLabel {
    // Try to decode the rule from the master or event itself.
    final ruleStr = event.recurrenceRule;
    if (ruleStr != null && ruleStr.isNotEmpty) {
      try {
        return RecurrenceRule.decode(ruleStr).toReadableString();
      } catch (_) {}
    }
    return 'Recurring';
  }

  void _editEvent(BuildContext context, WidgetRef ref) async {
    if (_hasRecurrence) {
      await _editRecurringEvent(context, ref);
    } else {
      await _editSingleEvent(context, ref);
    }
  }

  Future<void> _editSingleEvent(BuildContext context, WidgetRef ref) async {
    final result = await Navigator.of(context).push<CalendarEvent>(
      MaterialPageRoute(builder: (_) => EventFormScreen(existingEvent: event)),
    );
    if (result != null && context.mounted) {
      final repo = await ref.read(calendarRepositoryProvider.future);
      repo.updateEvent(result);
      ref.invalidate(eventsForDayProvider);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _editRecurringEvent(BuildContext context, WidgetRef ref) async {
    final choice = await _showRecurrenceActionDialog(context, 'Edit');
    if (choice == null || !context.mounted) return;

    final repo = await ref.read(calendarRepositoryProvider.future);

    // Find the persisted master event. Virtual instances share the master's
    // id but have modified start/end — always look up from DB to get the
    // original master with its true start date.
    CalendarEvent? master;
    if (event.masterEventId != null) {
      master = repo.getMasterEvent(event.masterEventId!);
    } else {
      // Virtual instance or the master itself — look up by id.
      master = repo.getMasterEvent(event.id);
    }
    if (master == null) {
      // Fallback to single edit.
      if (context.mounted) await _editSingleEvent(context, ref);
      return;
    }
    final resolvedMaster = master;

    final instanceStart = event.instanceStart ?? event.start;

    switch (choice) {
      case _RecurrenceAction.thisEvent:
        // Open form for this instance; save as exception.
        final edited = await Navigator.of(context).push<CalendarEvent>(
          MaterialPageRoute(
            builder: (_) => EventFormScreen(
              existingEvent: event.copyWith(
                masterEventId: resolvedMaster.id,
                originalStart: instanceStart.toIso8601String(),
              ),
            ),
          ),
        );
        if (edited != null) {
          repo.editSingleOccurrence(resolvedMaster, instanceStart, edited);
        }
      case _RecurrenceAction.thisAndFollowing:
        final edited = await Navigator.of(context).push<CalendarEvent>(
          MaterialPageRoute(
            builder: (_) => EventFormScreen(existingEvent: event),
          ),
        );
        if (edited != null) {
          repo.editThisAndFollowing(resolvedMaster, instanceStart, edited);
        }
      case _RecurrenceAction.allEvents:
        final edited = await Navigator.of(context).push<CalendarEvent>(
          MaterialPageRoute(
            builder: (_) => EventFormScreen(existingEvent: resolvedMaster),
          ),
        );
        if (edited != null) {
          repo.editAllOccurrences(resolvedMaster, edited);
        }
    }

    ref.invalidate(eventsForDayProvider);
    if (context.mounted) Navigator.of(context).pop();
  }

  void _deleteEvent(BuildContext context, WidgetRef ref) async {
    if (_hasRecurrence) {
      await _deleteRecurringEvent(context, ref);
    } else {
      await _deleteSingleEvent(context, ref);
    }
  }

  Future<void> _deleteSingleEvent(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete event?'),
        content: Text('Delete "${event.title}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final repo = await ref.read(calendarRepositoryProvider.future);
      repo.deleteEvent(event.id);
      ref.invalidate(eventsForDayProvider);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _deleteRecurringEvent(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final choice = await _showRecurrenceActionDialog(context, 'Delete');
    if (choice == null || !context.mounted) return;

    final repo = await ref.read(calendarRepositoryProvider.future);
    CalendarEvent? master;
    if (event.masterEventId != null) {
      master = repo.getMasterEvent(event.masterEventId!);
    } else {
      master = repo.getMasterEvent(event.id);
    }
    if (master == null) {
      if (context.mounted) await _deleteSingleEvent(context, ref);
      return;
    }
    final resolvedMaster = master;

    final instanceStart = event.instanceStart ?? event.start;

    switch (choice) {
      case _RecurrenceAction.thisEvent:
        repo.deleteSingleOccurrence(resolvedMaster, instanceStart);
      case _RecurrenceAction.thisAndFollowing:
        repo.deleteThisAndFollowing(resolvedMaster, instanceStart);
      case _RecurrenceAction.allEvents:
        repo.deleteAllOccurrences(resolvedMaster.id);
    }

    ref.invalidate(eventsForDayProvider);
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<_RecurrenceAction?> _showRecurrenceActionDialog(
    BuildContext context,
    String verb,
  ) {
    return showDialog<_RecurrenceAction>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('$verb recurring event'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _RecurrenceAction.thisEvent),
            child: const Text('This event'),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(ctx, _RecurrenceAction.thisAndFollowing),
            child: const Text('This and following events'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, _RecurrenceAction.allEvents),
            child: const Text('All events'),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '${dt.month}/${dt.day}/${dt.year} $hour:$min';
  }

  /// Returns a label for the timezone row, e.g. "America/New_York (EDT)"
  /// or just the timezone name if the abbreviation can't be computed.
  String _timezoneLabel(DateTime displayTime) {
    final tz = event.timezone!;
    final abbr = TimezoneService.getTimezoneAbbreviation(tz, displayTime);
    // If we converted to device tz, show both home and display tz.
    if (_deviceTz != null && _deviceTz != tz) {
      final deviceAbbr = TimezoneService.getTimezoneAbbreviation(
        _deviceTz!,
        displayTime,
      );
      return '$tz ($abbr) · shown in $_deviceTz ($deviceAbbr)';
    }
    return '$tz ($abbr)';
  }
}

bool _isUrl(String value) =>
    value.startsWith('http://') || value.startsWith('https://');

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _InfoRow({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final labelWidget = onTap != null
        ? GestureDetector(
            onTap: onTap,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          )
        : Text(label);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 12),
          Expanded(child: labelWidget),
        ],
      ),
    );
  }
}

enum _RecurrenceAction { thisEvent, thisAndFollowing, allEvents }
