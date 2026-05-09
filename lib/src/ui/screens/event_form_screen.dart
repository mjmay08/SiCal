import 'package:flutter/material.dart';
import '../../models/event.dart';
import '../../models/recurrence.dart';

class EventFormScreen extends StatefulWidget {
  final CalendarEvent? existingEvent;
  final DateTime? initialDate;

  const EventFormScreen({super.key, this.existingEvent, this.initialDate});

  @override
  State<EventFormScreen> createState() => _EventFormScreenState();
}

class _EventFormScreenState extends State<EventFormScreen> {
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

    if (event?.recurrenceRule != null && event!.recurrenceRule!.isNotEmpty) {
      try {
        _recurrenceRule = RecurrenceRule.decode(event.recurrenceRule!);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _locationController.dispose();
    super.dispose();
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
              onChanged: (v) => setState(() => _allDay = v),
            ),
            const SizedBox(height: 8),
            _DateTimePicker(
              label: 'Start',
              date: _startDate,
              time: _startTime,
              showTime: !_allDay,
              onDateChanged: (d) => setState(() => _startDate = d),
              onTimeChanged: (t) => setState(() => _startTime = t),
            ),
            const SizedBox(height: 8),
            _DateTimePicker(
              label: 'End',
              date: _endDate,
              time: _endTime,
              showTime: !_allDay,
              onDateChanged: (d) => setState(() => _endDate = d),
              onTimeChanged: (t) => setState(() => _endTime = t),
            ),
            const SizedBox(height: 16),
            if (!_isException) ...[
              _RecurrencePicker(
                rule: _recurrenceRule,
                onChanged: (r) => setState(() => _recurrenceRule = r),
              ),
              const SizedBox(height: 16),
            ],
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
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          start: start,
          end: end,
          allDay: _allDay,
          location: _locationController.text.trim(),
          recurrenceRule: _isException
              ? widget.existingEvent!.recurrenceRule
              : _recurrenceRule?.encode(),
          isDirty: true,
        ) ??
        CalendarEvent(
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          start: start,
          end: end,
          allDay: _allDay,
          location: _locationController.text.trim(),
          recurrenceRule: _recurrenceRule?.encode(),
        );

    Navigator.of(context).pop(event);
  }
}

class _DateTimePicker extends StatelessWidget {
  final String label;
  final DateTime date;
  final TimeOfDay time;
  final bool showTime;
  final ValueChanged<DateTime> onDateChanged;
  final ValueChanged<TimeOfDay> onTimeChanged;

  const _DateTimePicker({
    required this.label,
    required this.date,
    required this.time,
    required this.showTime,
    required this.onDateChanged,
    required this.onTimeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text('$label: ${date.month}/${date.day}/${date.year}'),
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: date,
                firstDate: DateTime(2020),
                lastDate: DateTime(2030),
              );
              if (picked != null) onDateChanged(picked);
            },
          ),
        ),
        if (showTime) ...[
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.access_time, size: 18),
              label: Text(time.format(context)),
              onPressed: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: time,
                );
                if (picked != null) onTimeChanged(picked);
              },
            ),
          ),
        ],
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
