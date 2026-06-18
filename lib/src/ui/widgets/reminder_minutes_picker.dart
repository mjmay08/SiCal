import 'package:flutter/material.dart';
import '../../utils/reminder_time_format.dart';

class ReminderMinutesPickerTile extends StatelessWidget {
  final List<int> reminderMinutes;
  final String title;
  final String subtitle;
  final ValueChanged<List<int>> onChanged;

  const ReminderMinutesPickerTile({
    super.key,
    required this.reminderMinutes,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.notifications_active_outlined),
      title: Text(title),
      subtitle: Text('$subtitle: ${formatReminderMinutes(reminderMinutes)}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final result = await showModalBottomSheet<List<int>>(
          context: context,
          isScrollControlled: true,
          builder: (_) => ReminderMinutesPickerSheet(
            title: title,
            initialReminderMinutes: reminderMinutes,
          ),
        );
        if (result != null) onChanged(result);
      },
    );
  }
}

class ReminderMinutesPickerSheet extends StatefulWidget {
  final String title;
  final List<int> initialReminderMinutes;

  const ReminderMinutesPickerSheet({
    super.key,
    required this.title,
    required this.initialReminderMinutes,
  });

  @override
  State<ReminderMinutesPickerSheet> createState() =>
      _ReminderMinutesPickerSheetState();
}

class _ReminderMinutesPickerSheetState
    extends State<ReminderMinutesPickerSheet> {
  static const _presets = <int>[0, 5, 10, 15, 30, 60, 1440];
  late final Set<int> _selected = widget.initialReminderMinutes.toSet();
  static const int _minCustomValue = 1;
  static const int _maxCustomValue = 200;
  int _customValue = 1;
  _ReminderUnit _customUnit = _ReminderUnit.minutes;
  final FixedExtentScrollController _valueWheelController =
      FixedExtentScrollController(initialItem: 0);
  late final FixedExtentScrollController _unitWheelController =
      FixedExtentScrollController(
        initialItem: _ReminderUnit.values.indexOf(_customUnit),
      );

  @override
  void dispose() {
    _valueWheelController.dispose();
    _unitWheelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final minutes in _presets)
                  FilterChip(
                    label: Text(
                      minutes == 0
                          ? 'At start'
                          : formatReminderLeadTime(minutes),
                    ),
                    selected: _selected.contains(minutes),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _selected.add(minutes);
                        } else {
                          _selected.remove(minutes);
                        }
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Custom alert', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  IgnorePointer(
                    child: Container(
                      height: 36,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: ListWheelScrollView.useDelegate(
                          controller: _valueWheelController,
                          itemExtent: 36,
                          perspective: 0.003,
                          physics: const FixedExtentScrollPhysics(),
                          onSelectedItemChanged: (index) {
                            setState(
                              () => _customValue = _minCustomValue + index,
                            );
                          },
                          childDelegate: ListWheelChildBuilderDelegate(
                            childCount: _maxCustomValue - _minCustomValue + 1,
                            builder: (context, index) {
                              final value = _minCustomValue + index;
                              final isSelected = value == _customValue;
                              return Center(
                                child: Text(
                                  '$value',
                                  style: TextStyle(
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: isSelected
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onPrimaryContainer
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListWheelScrollView.useDelegate(
                          controller: _unitWheelController,
                          itemExtent: 36,
                          perspective: 0.003,
                          physics: const FixedExtentScrollPhysics(),
                          onSelectedItemChanged: (index) {
                            setState(
                              () => _customUnit = _ReminderUnit.values[index],
                            );
                          },
                          childDelegate: ListWheelChildBuilderDelegate(
                            childCount: _ReminderUnit.values.length,
                            builder: (context, index) {
                              final unit = _ReminderUnit.values[index];
                              final isSelected = unit == _customUnit;
                              return Center(
                                child: Text(
                                  unit.label,
                                  style: TextStyle(
                                    fontWeight: isSelected
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: isSelected
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.onPrimaryContainer
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Selected custom: ${_formatValueWithUnit(_customValue, _customUnit)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _addCustom,
                child: const Text('Add custom'),
              ),
            ),
            const SizedBox(height: 16),
            if (_selected.isNotEmpty) ...[
              Text('Selected', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final minutes in _selected.toList()..sort())
                    InputChip(
                      label: Text(
                        formatReminderOffsetBefore(
                          minutes,
                          abbreviateMinutes: true,
                        ),
                      ),
                      onDeleted: () =>
                          setState(() => _selected.remove(minutes)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() => _selected.clear()),
                  child: const Text('No alert'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(context, _selected.toList()..sort()),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _addCustom() {
    final minutes = _customValue * _customUnit.factorMinutes;
    setState(() {
      _selected.add(minutes);
    });
  }
}

enum _ReminderUnit {
  minutes('minutes', 1),
  hours('hours', 60),
  days('days', 1440),
  weeks('weeks', 10080);

  final String label;
  final int factorMinutes;
  const _ReminderUnit(this.label, this.factorMinutes);
}

String _formatValueWithUnit(int value, _ReminderUnit unit) {
  final singular = unit.label.substring(0, unit.label.length - 1);
  return '$value ${value == 1 ? singular : unit.label}';
}
