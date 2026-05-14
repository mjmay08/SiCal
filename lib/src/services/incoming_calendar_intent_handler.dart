import 'package:flutter/material.dart';

import '../models/event.dart';
import '../repositories/calendar_repository.dart';
import '../ui/screens/event_form_screen.dart';
import 'ics_import_service.dart';

Future<void> handleIncomingCalendarText({
  required NavigatorState navigator,
  required ScaffoldMessengerState messenger,
  required CalendarRepository repository,
  required String text,
  VoidCallback? onImported,
}) async {
  final importer = IcsImportService(repository);
  final parsed = importer.parseDraftsFromString(text);

  if (parsed.drafts.isEmpty) {
    if (!messenger.mounted) return;
    final message = parsed.skippedCount > 0
        ? 'No importable events found. Skipped ${parsed.skippedCount} item(s).'
        : 'No importable events found.';
    messenger.showSnackBar(SnackBar(content: Text(message)));
    return;
  }

  final selectedDraft = parsed.drafts.length == 1
      ? parsed.drafts.first
      : await _pickIncomingDraft(navigator.context, parsed.drafts);
  if (selectedDraft == null || !navigator.mounted) return;

  final saved = await navigator.push<CalendarEvent>(
    MaterialPageRoute(
      builder: (_) => EventFormScreen(existingEvent: selectedDraft),
    ),
  );
  if (saved == null) return;

  repository.createEvent(saved);
  onImported?.call();

  if (!messenger.mounted) return;
  var message = 'Imported 1 item';
  if (parsed.drafts.length > 1) {
    final remaining = parsed.drafts.length - 1;
    message += ' ($remaining not imported)';
  }
  if (parsed.skippedCount > 0) {
    message += ', skipped ${parsed.skippedCount}';
  }
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

Future<CalendarEvent?> _pickIncomingDraft(
  BuildContext context,
  List<CalendarEvent> drafts,
) {
  return showDialog<CalendarEvent>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Choose Event to Import'),
      content: SizedBox(
        width: 420,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: drafts.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final event = drafts[index];
            return ListTile(
              title: Text(event.title),
              subtitle: Text(_incomingDraftSubtitle(context, event)),
              onTap: () => Navigator.of(ctx).pop(event),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

String _incomingDraftSubtitle(BuildContext context, CalendarEvent event) {
  final start = event.start.toLocal();
  final end = event.end.toLocal();
  if (event.allDay) {
    return '${start.month}/${start.day}/${start.year} • All day';
  }

  final startTime = TimeOfDay.fromDateTime(start).format(context);
  final endTime = TimeOfDay.fromDateTime(end).format(context);
  return '${start.month}/${start.day}/${start.year} • $startTime - $endTime';
}