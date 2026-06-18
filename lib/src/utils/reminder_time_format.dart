String formatReminderLeadTime(
  int reminderMinutes, {
  bool abbreviateMinutes = false,
}) {
  if (reminderMinutes == 1) {
    return abbreviateMinutes ? '1 min' : '1 minute';
  }
  if (reminderMinutes < 60) {
    return abbreviateMinutes
        ? '$reminderMinutes min'
        : '$reminderMinutes minutes';
  }
  if (reminderMinutes % 10080 == 0) {
    final weeks = reminderMinutes ~/ 10080;
    return weeks == 1 ? '1 week' : '$weeks weeks';
  }
  if (reminderMinutes % 1440 == 0) {
    final days = reminderMinutes ~/ 1440;
    return days == 1 ? '1 day' : '$days days';
  }
  if (reminderMinutes % 60 == 0) {
    final hours = reminderMinutes ~/ 60;
    return hours == 1 ? '1 hour' : '$hours hours';
  }

  final hours = reminderMinutes / 60;
  return '${hours.toStringAsFixed(1)} hours';
}

String formatReminderOffsetBefore(
  int reminderMinutes, {
  bool abbreviateMinutes = false,
}) {
  if (reminderMinutes == 0) return 'At start';
  return '${formatReminderLeadTime(reminderMinutes, abbreviateMinutes: abbreviateMinutes)} before';
}

String formatReminderMinutes(
  List<int> reminderMinutes, {
  bool abbreviateMinutes = true,
}) {
  if (reminderMinutes.isEmpty) return 'No alert';
  final sorted = reminderMinutes.toSet().toList()..sort();
  return sorted
      .map(
        (minutes) => formatReminderOffsetBefore(
          minutes,
          abbreviateMinutes: abbreviateMinutes,
        ),
      )
      .join(', ');
}
