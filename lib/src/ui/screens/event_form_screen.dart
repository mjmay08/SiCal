import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/calendar.dart';
import '../../models/event.dart';
import '../../models/recurrence.dart';
import '../../repositories/calendar_repository.dart';
import '../../services/timezone_service.dart';
import '../../utils/event_time_range_adjustment.dart';
import '../widgets/reminder_minutes_picker.dart';

class EventFormScreen extends ConsumerStatefulWidget {
  final CalendarEvent? existingEvent;
  final DateTime? initialDate;

  const EventFormScreen({super.key, this.existingEvent, this.initialDate});

  @override
  ConsumerState<EventFormScreen> createState() => _EventFormScreenState();
}

class _EventFormScreenState extends ConsumerState<EventFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  late TextEditingController _locationController;
  late DateTime _startDate;
  late TimeOfDay _startTime;
  late DateTime _endDate;
  late TimeOfDay _endTime;
  late bool _allDay;
  RecurrenceRule? _recurrenceRule;
  String? _timezone;
  String _calendarId = kDefaultCalendarId;
  List<int>? _reminderMinutes;
  _DateTimeEditorTarget? _activeEditor;

  bool get _isEditing => widget.existingEvent != null;

  /// Hide recurrence picker when editing an exception (single-instance edit).
  bool get _isException => widget.existingEvent?.isException == true;

  @override
  void initState() {
    super.initState();
    final event = widget.existingEvent;
    final now = widget.initialDate ?? DateTime.now();

    _titleController = TextEditingController(text: event?.title ?? '');
    _descriptionController = TextEditingController(
      text: event?.description ?? '',
    );
    _locationController = TextEditingController(text: event?.location ?? '');

    _startDate = event?.start ?? now;
    _startTime = TimeOfDay.fromDateTime(event?.start ?? now);
    _endDate = event?.end ?? now.add(const Duration(hours: 1));
    _endTime = TimeOfDay.fromDateTime(
      event?.end ?? now.add(const Duration(hours: 1)),
    );
    _allDay = event?.allDay ?? false;
    _timezone = event?.timezone;
    _reminderMinutes = event?.reminderMinutes;
    String? selectedCalendarId;
    try {
      selectedCalendarId = ref.read(selectedCalendarIdProvider);
    } catch (_) {
      selectedCalendarId = null;
    }
    _calendarId = event?.calendarId ?? selectedCalendarId ?? kDefaultCalendarId;

    if (event?.recurrenceRule != null && event!.recurrenceRule!.isNotEmpty) {
      try {
        _recurrenceRule = RecurrenceRule.decode(event.recurrenceRule!);
      } catch (_) {}
    }

    // For new timed events, default to device timezone.
    if (event == null && !_allDay) {
      TimezoneService.getDeviceTimezone().then((tz) {
        if (mounted) setState(() => _timezone = tz);
      });
    }

    _loadDefaultRemindersIfNeeded();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _loadDefaultRemindersIfNeeded() async {
    if (_isEditing || _reminderMinutes != null) return;
    final repository = await ref.read(calendarRepositoryProvider.future);
    if (!mounted || _reminderMinutes != null) return;
    setState(
      () => _reminderMinutes = repository.getDefaultEventReminderMinutes(),
    );
  }

  DateTime _selectedStartDateTime({DateTime? date, TimeOfDay? time}) {
    final selectedDate = date ?? _startDate;
    final selectedTime = time ?? _startTime;
    return DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      _allDay ? 0 : selectedTime.hour,
      _allDay ? 0 : selectedTime.minute,
    );
  }

  DateTime _selectedEndDateTime() {
    return DateTime(
      _endDate.year,
      _endDate.month,
      _endDate.day,
      _allDay ? 23 : _endTime.hour,
      _allDay ? 59 : _endTime.minute,
    );
  }

  void _updateStartDateTime({DateTime? date, TimeOfDay? time}) {
    final previousStart = _selectedStartDateTime();
    final previousEnd = _selectedEndDateTime();
    final nextStart = _selectedStartDateTime(date: date, time: time);
    final adjustedRange = shiftDateTimeRangeStart(
      previousStart: previousStart,
      previousEnd: previousEnd,
      nextStart: nextStart,
    );

    setState(() {
      _startDate = adjustedRange.start;
      _startTime = TimeOfDay.fromDateTime(adjustedRange.start);
      _endDate = adjustedRange.end;
      _endTime = TimeOfDay.fromDateTime(adjustedRange.end);
    });
  }

  void _toggleEditor(_DateTimeEditorTarget editor) {
    setState(() {
      _activeEditor = _activeEditor == editor ? null : editor;
    });
  }

  void _handleAllDayChanged(bool value) {
    setState(() {
      _allDay = value;
      if (value && _activeEditor?.isTime == true) {
        _activeEditor = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Event' : 'New Event'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Title is required' : null,
              autofocus: !_isEditing,
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('All day'),
              value: _allDay,
              onChanged: _handleAllDayChanged,
            ),
            const SizedBox(height: 8),
            _DateTimePicker(
              label: 'Start',
              date: _startDate,
              time: _startTime,
              showTime: !_allDay,
              isDateEditorVisible:
                  _activeEditor == _DateTimeEditorTarget.startDate,
              isTimeEditorVisible:
                  _activeEditor == _DateTimeEditorTarget.startTime,
              onDateChanged: (d) => _updateStartDateTime(date: d),
              onTimeChanged: (t) => _updateStartDateTime(time: t),
              onDateTap: () => _toggleEditor(_DateTimeEditorTarget.startDate),
              onTimeTap: () => _toggleEditor(_DateTimeEditorTarget.startTime),
            ),
            const SizedBox(height: 8),
            _DateTimePicker(
              label: 'End',
              date: _endDate,
              time: _endTime,
              showTime: !_allDay,
              isDateEditorVisible:
                  _activeEditor == _DateTimeEditorTarget.endDate,
              isTimeEditorVisible:
                  _activeEditor == _DateTimeEditorTarget.endTime,
              onDateChanged: (d) => setState(() => _endDate = d),
              onTimeChanged: (t) => setState(() => _endTime = t),
              onDateTap: () => _toggleEditor(_DateTimeEditorTarget.endDate),
              onTimeTap: () => _toggleEditor(_DateTimeEditorTarget.endTime),
            ),
            if (!_allDay) ...[
              const SizedBox(height: 8),
              _TimezoneTile(
                timezone: _timezone,
                onChanged: (tz) => setState(() => _timezone = tz),
              ),
            ],
            const SizedBox(height: 8),
            _CalendarPickerTile(
              selectedCalendarId: _calendarId,
              onChanged: (id) => setState(() => _calendarId = id),
            ),
            const SizedBox(height: 16),
            if (!_isException) ...[
              _RecurrencePicker(
                rule: _recurrenceRule,
                onChanged: (r) => setState(() => _recurrenceRule = r),
              ),
              const SizedBox(height: 16),
            ],
            ReminderMinutesPickerTile(
              reminderMinutes: _reminderMinutes ?? const [],
              title: 'Alerts',
              subtitle: 'Remind me',
              onChanged: (minutes) =>
                  setState(() => _reminderMinutes = minutes),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _locationController,
              decoration: const InputDecoration(
                labelText: 'Location',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.location_on),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final start = DateTime(
      _startDate.year,
      _startDate.month,
      _startDate.day,
      _allDay ? 0 : _startTime.hour,
      _allDay ? 0 : _startTime.minute,
    );

    final end = DateTime(
      _endDate.year,
      _endDate.month,
      _endDate.day,
      _allDay ? 23 : _endTime.hour,
      _allDay ? 59 : _endTime.minute,
    );

    if (end.isBefore(start)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must be after start time')),
      );
      return;
    }

    final event =
        widget.existingEvent?.copyWith(
          calendarId: _calendarId,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          start: start,
          end: end,
          allDay: _allDay,
          location: _locationController.text.trim(),
          recurrenceRule: _isException
              ? widget.existingEvent!.recurrenceRule
              : _recurrenceRule?.encode(),
          timezone: _allDay ? null : _timezone,
          reminderMinutes: _reminderMinutes ?? const [],
          isDirty: true,
        ) ??
        CalendarEvent(
          calendarId: _calendarId,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          start: start,
          end: end,
          allDay: _allDay,
          location: _locationController.text.trim(),
          recurrenceRule: _recurrenceRule?.encode(),
          timezone: _allDay ? null : _timezone,
          reminderMinutes: _reminderMinutes ?? const [],
        );

    Navigator.of(context).pop(event);
  }
}

enum _DateTimeEditorTarget { startDate, startTime, endDate, endTime }

extension on _DateTimeEditorTarget {
  bool get isTime =>
      this == _DateTimeEditorTarget.startTime ||
      this == _DateTimeEditorTarget.endTime;
}

class _CalendarPickerTile extends ConsumerWidget {
  final String selectedCalendarId;
  final ValueChanged<String> onChanged;

  const _CalendarPickerTile({
    required this.selectedCalendarId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AsyncValue<List<CalendarInfo>>? calendarsAsync;
    try {
      calendarsAsync = ref.watch(calendarsProvider);
    } catch (_) {
      calendarsAsync = null;
    }

    if (calendarsAsync == null) {
      return const ListTile(
        leading: Icon(Icons.calendar_month),
        title: Text('Default calendar'),
        subtitle: Text('Calendar'),
        contentPadding: EdgeInsets.zero,
      );
    }

    return calendarsAsync.when(
      data: (calendars) {
        final visibleCalendars = calendars.where((c) => c.isVisible).toList();
        if (visibleCalendars.isEmpty) {
          return const ListTile(
            leading: Icon(Icons.calendar_month),
            title: Text('Calendar'),
            subtitle: Text('Default'),
            contentPadding: EdgeInsets.zero,
          );
        }

        final selected = visibleCalendars.cast<CalendarInfo?>().firstWhere(
          (c) => c?.id == selectedCalendarId,
          orElse: () => visibleCalendars.first,
        )!;

        return ListTile(
          leading: const Icon(Icons.calendar_month),
          title: Text(selected.name),
          subtitle: const Text('Calendar'),
          contentPadding: EdgeInsets.zero,
          trailing: DropdownButton<String>(
            value: selected.id,
            underline: const SizedBox.shrink(),
            items: [
              for (final calendar in visibleCalendars)
                DropdownMenuItem(
                  value: calendar.id,
                  child: Text(calendar.name),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              onChanged(value);
            },
          ),
        );
      },
      loading: () => const ListTile(
        leading: Icon(Icons.calendar_month),
        title: Text('Calendar'),
        subtitle: Text('Loading...'),
        contentPadding: EdgeInsets.zero,
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

// ---------------------------------------------------------------------------
// Timezone picker
// ---------------------------------------------------------------------------

class _TimezoneTile extends StatelessWidget {
  final String? timezone;
  final ValueChanged<String?> onChanged;

  const _TimezoneTile({required this.timezone, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.language),
      title: Text(timezone ?? 'No timezone (floating)'),
      subtitle: const Text('Timezone'),
      trailing: const Icon(Icons.chevron_right),
      contentPadding: EdgeInsets.zero,
      onTap: () => _showPicker(context),
    );
  }

  void _showPicker(BuildContext context) async {
    final result = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TimezonePickerSheet(current: timezone),
    );
    // null means dismissed; _floatingTimezone means "no timezone / floating"
    if (result == _floatingTimezone) {
      onChanged(null);
    } else if (result != null) {
      onChanged(result);
    }
  }
}

/// Sentinel returned when the user selects "No timezone (floating)".
const _floatingTimezone = '__floating__';

class _TimezonePickerSheet extends StatefulWidget {
  final String? current;
  const _TimezonePickerSheet({this.current});

  @override
  State<_TimezonePickerSheet> createState() => _TimezonePickerSheetState();
}

class _TimezonePickerSheetState extends State<_TimezonePickerSheet> {
  late final List<String> _allTimezones;
  List<String> _filtered = [];
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _allTimezones = TimezoneService.getAllTimezones();
    _filtered = _allTimezones;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearch(String query) {
    final lower = query.toLowerCase();
    setState(() {
      _filtered = lower.isEmpty
          ? _allTimezones
          : _allTimezones
                .where((tz) => tz.toLowerCase().contains(lower))
                .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Select Timezone',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: 'Search timezones…',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: _onSearch,
                    autofocus: true,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: _filtered.length + 1, // +1 for floating option
                itemBuilder: (ctx, index) {
                  if (index == 0) {
                    return ListTile(
                      title: const Text('No timezone (floating)'),
                      selected: widget.current == null,
                      onTap: () => Navigator.pop(ctx, _floatingTimezone),
                    );
                  }
                  final tz = _filtered[index - 1];
                  return ListTile(
                    title: Text(tz),
                    selected: tz == widget.current,
                    onTap: () => Navigator.pop(ctx, tz),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateTimePicker extends StatelessWidget {
  final String label;
  final DateTime date;
  final TimeOfDay time;
  final bool showTime;
  final bool isDateEditorVisible;
  final bool isTimeEditorVisible;
  final ValueChanged<DateTime> onDateChanged;
  final ValueChanged<TimeOfDay> onTimeChanged;
  final VoidCallback onDateTap;
  final VoidCallback onTimeTap;

  const _DateTimePicker({
    required this.label,
    required this.date,
    required this.time,
    required this.showTime,
    required this.isDateEditorVisible,
    required this.isTimeEditorVisible,
    required this.onDateChanged,
    required this.onTimeChanged,
    required this.onDateTap,
    required this.onTimeTap,
  });

  @override
  Widget build(BuildContext context) {
    final editorDecoration = BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: OutlinedButton.icon(
                key: Key('${label.toLowerCase()}-date-button'),
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text('$label: ${date.month}/${date.day}/${date.year}'),
                onPressed: onDateTap,
              ),
            ),
            if (showTime) ...[
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: OutlinedButton.icon(
                  key: Key('${label.toLowerCase()}-time-button'),
                  icon: const Icon(Icons.access_time, size: 18),
                  label: Text(time.format(context)),
                  onPressed: onTimeTap,
                ),
              ),
            ],
          ],
        ),
        if (isDateEditorVisible) ...[
          const SizedBox(height: 12),
          Container(
            key: Key('${label.toLowerCase()}-date-editor'),
            decoration: editorDecoration,
            padding: const EdgeInsets.all(12),
            child: CalendarDatePicker(
              initialDate: date,
              firstDate: DateTime(2020),
              lastDate: DateTime(2030),
              onDateChanged: onDateChanged,
            ),
          ),
        ],
        if (showTime && isTimeEditorVisible) ...[
          const SizedBox(height: 12),
          Container(
            key: Key('${label.toLowerCase()}-time-editor'),
            decoration: editorDecoration,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: _InlineTimePicker(
              label: label,
              time: time,
              onChanged: onTimeChanged,
            ),
          ),
        ],
      ],
    );
  }
}

class _InlineTimePicker extends StatefulWidget {
  final String label;
  final TimeOfDay time;
  final ValueChanged<TimeOfDay> onChanged;

  const _InlineTimePicker({
    required this.label,
    required this.time,
    required this.onChanged,
  });

  @override
  State<_InlineTimePicker> createState() => _InlineTimePickerState();
}

class _InlineTimePickerState extends State<_InlineTimePicker> {
  static const _itemExtent = 40.0;

  late FixedExtentScrollController _hourController;
  late FixedExtentScrollController _minuteController;
  late FixedExtentScrollController _periodController;
  late int _selectedHourIndex;
  late int _selectedMinute;
  late bool _selectedIsAm;

  @override
  void initState() {
    super.initState();
    _syncSelectionFromTime(widget.time);
    _hourController = FixedExtentScrollController(
      initialItem: _selectedHourIndex,
    );
    _minuteController = FixedExtentScrollController(
      initialItem: _selectedMinute,
    );
    _periodController = FixedExtentScrollController(
      initialItem: _selectedIsAm ? 0 : 1,
    );
  }

  @override
  void didUpdateWidget(covariant _InlineTimePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_currentSelectedTime != widget.time) {
      _syncSelectionFromTime(widget.time);
      _hourController.jumpToItem(_selectedHourIndex);
      _minuteController.jumpToItem(_selectedMinute);
      _periodController.jumpToItem(_selectedIsAm ? 0 : 1);
    }
  }

  @override
  void dispose() {
    _hourController.dispose();
    _minuteController.dispose();
    _periodController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${widget.label} time', style: textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          height: 176,
          child: Row(
            children: [
              Expanded(
                child: _WheelColumn(
                  label: 'Hour',
                  pickerKey: Key('${widget.label.toLowerCase()}-hour-wheel'),
                  controller: _hourController,
                  itemExtent: _itemExtent,
                  itemCount: 12,
                  itemLabelBuilder: (index) => '${index + 1}',
                  onSelectedItemChanged: (index) =>
                      _updateTime(hourIndex: index),
                ),
              ),
              Expanded(
                child: _WheelColumn(
                  label: 'Minute',
                  pickerKey: Key('${widget.label.toLowerCase()}-minute-wheel'),
                  controller: _minuteController,
                  itemExtent: _itemExtent,
                  itemCount: 60,
                  itemLabelBuilder: (index) => index.toString().padLeft(2, '0'),
                  onSelectedItemChanged: (index) => _updateTime(minute: index),
                ),
              ),
              Expanded(
                child: _WheelColumn(
                  label: 'AM/PM',
                  pickerKey: Key('${widget.label.toLowerCase()}-period-wheel'),
                  controller: _periodController,
                  itemExtent: _itemExtent,
                  itemCount: 2,
                  itemLabelBuilder: (index) => index == 0 ? 'AM' : 'PM',
                  onSelectedItemChanged: (index) =>
                      _updateTime(isAm: index == 0),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _updateTime({int? hourIndex, int? minute, bool? isAm}) {
    _selectedHourIndex = hourIndex ?? _selectedHourIndex;
    _selectedMinute = minute ?? _selectedMinute;
    _selectedIsAm = isAm ?? _selectedIsAm;
    widget.onChanged(_currentSelectedTime);
  }

  int _hourIndex(TimeOfDay time) {
    final hourOfPeriod = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    return hourOfPeriod - 1;
  }

  TimeOfDay get _currentSelectedTime {
    final hourOfPeriod = _selectedHourIndex + 1;
    final normalizedHour = hourOfPeriod % 12;
    final nextHour = _selectedIsAm ? normalizedHour : normalizedHour + 12;
    return TimeOfDay(hour: nextHour, minute: _selectedMinute);
  }

  void _syncSelectionFromTime(TimeOfDay time) {
    _selectedHourIndex = _hourIndex(time);
    _selectedMinute = time.minute;
    _selectedIsAm = time.period == DayPeriod.am;
  }
}

class _WheelColumn extends StatelessWidget {
  final String label;
  final Key pickerKey;
  final FixedExtentScrollController controller;
  final double itemExtent;
  final int itemCount;
  final String Function(int index) itemLabelBuilder;
  final ValueChanged<int> onSelectedItemChanged;

  const _WheelColumn({
    required this.label,
    required this.pickerKey,
    required this.controller,
    required this.itemExtent,
    required this.itemCount,
    required this.itemLabelBuilder,
    required this.onSelectedItemChanged,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Column(
      children: [
        Text(label, style: textTheme.labelLarge),
        const SizedBox(height: 8),
        Expanded(
          child: CupertinoPicker.builder(
            key: pickerKey,
            scrollController: controller,
            itemExtent: itemExtent,
            useMagnifier: true,
            magnification: 1.05,
            onSelectedItemChanged: onSelectedItemChanged,
            childCount: itemCount,
            itemBuilder: (context, index) {
              return Center(
                child: Text(
                  itemLabelBuilder(index),
                  style: textTheme.titleMedium,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Recurrence picker
// ---------------------------------------------------------------------------

class _RecurrencePicker extends StatelessWidget {
  final RecurrenceRule? rule;
  final ValueChanged<RecurrenceRule?> onChanged;

  const _RecurrencePicker({required this.rule, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // Determine currently selected preset (or "Custom" if rule doesn't match).
    final currentLabel = _labelForRule(rule);

    return ListTile(
      leading: const Icon(Icons.repeat),
      title: Text(currentLabel),
      subtitle: rule != null && _isCustom(rule!)
          ? Text(rule!.toReadableString())
          : null,
      trailing: const Icon(Icons.chevron_right),
      contentPadding: EdgeInsets.zero,
      onTap: () => _showPicker(context),
    );
  }

  String _labelForRule(RecurrenceRule? r) {
    if (r == null) return 'Does not repeat';
    if (r.interval == 1 &&
        r.byDay == null &&
        r.byMonthDay == null &&
        r.until == null &&
        r.count == null) {
      switch (r.freq) {
        case RecurrenceFrequency.daily:
          return 'Daily';
        case RecurrenceFrequency.weekly:
          return 'Weekly';
        case RecurrenceFrequency.monthly:
          return 'Monthly';
        case RecurrenceFrequency.yearly:
          return 'Yearly';
      }
    }
    return 'Custom';
  }

  bool _isCustom(RecurrenceRule r) =>
      r.interval != 1 ||
      r.byDay != null ||
      r.byMonthDay != null ||
      r.until != null ||
      r.count != null;

  void _showPicker(BuildContext context) async {
    final result = await showModalBottomSheet<RecurrenceRule?>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _RecurrencePickerSheet(current: rule),
    );
    // result is null when bottom sheet is dismissed without selection.
    // A _noRecurrence sentinel is used to distinguish "no repeat" from dismiss.
    if (result == _noRecurrence) {
      onChanged(null);
    } else if (result != null) {
      onChanged(result);
    }
  }
}

/// Sentinel to indicate "does not repeat" was explicitly chosen.
final _noRecurrence = RecurrenceRule(
  freq: RecurrenceFrequency.daily,
  interval: -1,
);

class _RecurrencePickerSheet extends StatefulWidget {
  final RecurrenceRule? current;
  const _RecurrencePickerSheet({this.current});

  @override
  State<_RecurrencePickerSheet> createState() => _RecurrencePickerSheetState();
}

class _RecurrencePickerSheetState extends State<_RecurrencePickerSheet> {
  late RecurrenceFrequency? _freq;
  late int _interval;
  late List<int> _byDay;
  DateTime? _until;

  @override
  void initState() {
    super.initState();
    _freq = widget.current?.freq;
    _interval = widget.current?.interval ?? 1;
    _byDay = widget.current?.byDay ?? [];
    _until = widget.current?.until;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: _freq != null ? 0.85 : 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, scrollController) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            controller: scrollController,
            shrinkWrap: true,
            children: [
              Text('Repeat', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              // Preset options.
              ..._presetTiles(),
              const Divider(),
              // Custom options (visible when a frequency is selected).
              if (_freq != null) ...[
                _intervalRow(),
                if (_freq == RecurrenceFrequency.weekly) _dayChips(),
                _untilRow(context),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _done,
                    child: const Text('Done'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _presetTiles() {
    // Index: 0 = does not repeat, 1..4 = daily/weekly/monthly/yearly
    final options = [null, ...RecurrenceFrequency.values];
    final labels = [
      'Does not repeat',
      ...RecurrenceFrequency.values.map(_freqLabel),
    ];
    final selectedIndex = _freq == null ? 0 : options.indexOf(_freq);

    return [
      for (var i = 0; i < options.length; i++)
        ListTile(
          leading: Icon(
            selectedIndex == i
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            color: selectedIndex == i
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          title: Text(labels[i]),
          onTap: () {
            if (options[i] == null) {
              Navigator.pop(context, _noRecurrence);
            } else {
              setState(() {
                _freq = options[i];
                _interval = 1;
                _byDay = [];
              });
            }
          },
        ),
    ];
  }

  Widget _intervalRow() {
    return Row(
      children: [
        const Text('Every'),
        const SizedBox(width: 8),
        SizedBox(
          width: 60,
          child: TextFormField(
            initialValue: '$_interval',
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(isDense: true),
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n != null && n > 0) _interval = n;
            },
          ),
        ),
        const SizedBox(width: 8),
        Text(_freqUnit(_freq!)),
      ],
    );
  }

  Widget _dayChips() {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 6,
        children: List.generate(7, (i) {
          final isoDay = i + 1; // 1=Mon .. 7=Sun
          final selected = _byDay.contains(isoDay);
          return FilterChip(
            label: Text(days[i]),
            selected: selected,
            onSelected: (sel) {
              setState(() {
                if (sel) {
                  _byDay.add(isoDay);
                } else {
                  _byDay.remove(isoDay);
                }
              });
            },
          );
        }),
      ),
    );
  }

  Widget _untilRow(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('End date'),
      trailing: TextButton(
        child: Text(
          _until != null
              ? '${_until!.month}/${_until!.day}/${_until!.year}'
              : 'Never',
        ),
        onPressed: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: _until ?? DateTime.now().add(const Duration(days: 30)),
            firstDate: DateTime.now(),
            lastDate: DateTime(2030),
          );
          setState(() => _until = picked);
        },
      ),
    );
  }

  void _done() {
    if (_freq == null) {
      Navigator.pop(context, _noRecurrence);
      return;
    }
    Navigator.pop(
      context,
      RecurrenceRule(
        freq: _freq!,
        interval: _interval,
        byDay: (_freq == RecurrenceFrequency.weekly && _byDay.isNotEmpty)
            ? _byDay
            : null,
        until: _until,
      ),
    );
  }

  String _freqLabel(RecurrenceFrequency f) => switch (f) {
    RecurrenceFrequency.daily => 'Daily',
    RecurrenceFrequency.weekly => 'Weekly',
    RecurrenceFrequency.monthly => 'Monthly',
    RecurrenceFrequency.yearly => 'Yearly',
  };

  String _freqUnit(RecurrenceFrequency f) => switch (f) {
    RecurrenceFrequency.daily => _interval == 1 ? 'day' : 'days',
    RecurrenceFrequency.weekly => _interval == 1 ? 'week' : 'weeks',
    RecurrenceFrequency.monthly => _interval == 1 ? 'month' : 'months',
    RecurrenceFrequency.yearly => _interval == 1 ? 'year' : 'years',
  };
}
