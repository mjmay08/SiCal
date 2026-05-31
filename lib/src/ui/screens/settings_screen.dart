import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../bridge/sia_bridge.dart';
import '../../models/calendar.dart';
import '../../models/event.dart';
import '../../repositories/calendar_repository.dart';
import '../../services/auth_service.dart';
import '../../services/ics_import_service.dart';
import '../../services/timezone_service.dart';

const _calendarPalette = <String>[
  '#1ED660',
  '#FF6B6B',
  '#4ECDC4',
  '#3B82F6',
  '#F59E0B',
  '#8B5CF6',
  '#10B981',
];

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SyncStatusTile(),
          const Divider(),
          _SectionHeader('Account'),
          ListTile(
            leading: const Icon(Icons.key),
            title: const Text('Recovery Phrase'),
            subtitle: const Text('SiCal does not store your recovery phrase'),
            onTap: () => _showRecoveryPhraseInfo(context),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Indexer'),
            subtitle: const Text('https://sia.storage'),
            onTap: () {},
          ),
          const Divider(),
          _SectionHeader('Calendar'),
          _CalendarNameTile(),
          _CalendarTimezoneTile(),
          ListTile(
            leading: const Icon(Icons.calendar_view_month),
            title: const Text('Manage Calendars'),
            subtitle: const Text('Add calendars and toggle visibility'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const _ManageCalendarsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Import Calendar File'),
            subtitle: const Text('Supports .ics, .ical, .ifb, and .vcs'),
            onTap: () => _importIcsFile(context, ref),
          ),
          const Divider(),
          _SectionHeader('Data'),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text(
              'Clear Local Data',
              style: TextStyle(color: Colors.red),
            ),
            subtitle: const Text('Remove all cached data from this device'),
            onTap: () => _confirmClearData(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_off, color: Colors.red),
            title: const Text(
              'Delete All Pinned Data',
              style: TextStyle(color: Colors.red),
            ),
            subtitle: const Text('Remove all data from Sia and reset locally'),
            onTap: () => _confirmDeleteAllPinned(context, ref),
          ),
          const Divider(),
          _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('SiCal'),
            subtitle: Text('v1.0.0 — Powered by the Sia decentralized network'),
          ),
        ],
      ),
    );
  }

  void _showRecoveryPhraseInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber, color: Colors.orange, size: 36),
        title: const Text('Recovery Phrase'),
        content: const Text(
          'SiCal never stores your recovery phrase. '
          'Only your App Key is stored securely on this device for reconnecting.\n\n'
          'Keep your recovery phrase backed up offline. Anyone with that phrase '
          'has full access to your calendar data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _importIcsFile(BuildContext context, WidgetRef ref) async {
    try {
      final repository = await ref.read(calendarRepositoryProvider.future);
      final importer = IcsImportService(repository);
      final result = await importer.importFromPicker();
      if (result == null || !context.mounted) return;

      ref.invalidate(eventsForDayProvider);
      Navigator.of(context).pop(result.importedCount > 0);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  void _confirmClearData(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear local data?'),
        content: const Text(
          'This will delete all locally cached events and settings. '
          'Your data on Sia is NOT affected and can be restored with your recovery phrase.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final auth = ref.read(authServiceProvider);
              await auth.clearAll();
              ref.invalidate(authStateProvider);
              if (context.mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAllPinned(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber, color: Colors.red, size: 36),
        title: const Text('Delete ALL data from Sia?'),
        content: const Text(
          'This will permanently delete every pinned object from your Sia account '
          'and clear all local data. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              if (!context.mounted) return;
              _performDeleteAll(context, ref);
            },
            child: const Text(
              'Delete Everything',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _performDeleteAll(BuildContext context, WidgetRef ref) async {
    // Show a progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 24),
            Expanded(child: Text('Deleting all pinned data…')),
          ],
        ),
      ),
    );

    try {
      final deleted = await SiaBridge.deleteAllObjects();
      final db = await ref.read(appDatabaseProvider.future);
      db.clearAllTables();
      ref.invalidate(eventsForDayProvider);

      if (context.mounted) {
        Navigator.pop(context); // dismiss progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted $deleted object(s) from Sia')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // dismiss progress dialog
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _SyncStatusTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbAsync = ref.watch(appDatabaseProvider);
    return dbAsync.when(
      data: (db) {
        final syncState = db.getSyncState();
        final lastSync = syncState?.lastSyncAt;
        final dirtyCount = db.getDirtyEvents().length;
        return ListTile(
          leading: Icon(
            dirtyCount > 0 ? Icons.cloud_upload_outlined : Icons.cloud_done,
            color: dirtyCount > 0
                ? Theme.of(context).colorScheme.error
                : Theme.of(context).colorScheme.primary,
          ),
          title: const Text('Sync Status'),
          subtitle: Text(
            dirtyCount > 0
                ? '$dirtyCount event(s) pending upload'
                : lastSync != null
                ? 'Last synced: ${_formatTime(lastSync)}'
                : 'Not yet synced',
          ),
        );
      },
      loading: () => const ListTile(
        leading: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text('Sync Status'),
        subtitle: Text('Loading...'),
      ),
      error: (e, _) => ListTile(
        leading: const Icon(Icons.error, color: Colors.red),
        title: const Text('Sync Status'),
        subtitle: Text('Error: $e'),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '${local.month}/${local.day}/${local.year} $h:$m';
  }
}

class _CalendarNameTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calendarsAsync = ref.watch(calendarsProvider);
    final selectedId =
        ref.watch(selectedCalendarIdProvider) ?? kDefaultCalendarId;
    return calendarsAsync.when(
      data: (calendars) {
        final selected = calendars.cast<CalendarInfo?>().firstWhere(
          (c) => c?.id == selectedId,
          orElse: () => null,
        );
        return ListTile(
          leading: const Icon(Icons.edit),
          title: const Text('Calendar Name'),
          subtitle: Text(selected?.name ?? 'My Calendar'),
          onTap: selected == null
              ? null
              : () => _editName(context, ref, selected),
        );
      },
      loading: () => const ListTile(title: Text('Calendar Name')),
      error: (_, __) => const ListTile(title: Text('Calendar Name')),
    );
  }

  void _editName(BuildContext context, WidgetRef ref, CalendarInfo calendar) {
    final controller = TextEditingController(text: calendar.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Calendar Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Enter name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                final repo = ref.read(calendarRepositoryProvider).value;
                repo?.upsertCalendar(
                  calendar.copyWith(
                    name: name,
                    updatedAt: DateTime.now().toUtc(),
                  ),
                );
                ref.invalidate(calendarsProvider);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _CalendarTimezoneTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calendarsAsync = ref.watch(calendarsProvider);
    final selectedId =
        ref.watch(selectedCalendarIdProvider) ?? kDefaultCalendarId;
    return calendarsAsync.when(
      data: (calendars) {
        final selected = calendars.cast<CalendarInfo?>().firstWhere(
          (c) => c?.id == selectedId,
          orElse: () => null,
        );
        final current = selected?.timezone ?? 'UTC';
        return ListTile(
          leading: const Icon(Icons.language),
          title: const Text('Calendar Timezone'),
          subtitle: Text(current),
          onTap: selected == null
              ? null
              : () => _pickTimezone(context, ref, selected, current),
        );
      },
      loading: () => const ListTile(title: Text('Calendar Timezone')),
      error: (_, __) => const ListTile(title: Text('Calendar Timezone')),
    );
  }

  Future<void> _pickTimezone(
    BuildContext context,
    WidgetRef ref,
    CalendarInfo calendar,
    String current,
  ) async {
    final allTimezones = TimezoneService.getAllTimezones();
    List<String> filtered = allTimezones;

    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.75,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            builder: (ctx, scrollController) => SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Calendar Timezone',
                          style: Theme.of(ctx).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          decoration: const InputDecoration(
                            hintText: 'Search timezones…',
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (q) {
                            final lower = q.toLowerCase();
                            setModalState(() {
                              filtered = lower.isEmpty
                                  ? allTimezones
                                  : allTimezones
                                        .where(
                                          (tz) =>
                                              tz.toLowerCase().contains(lower),
                                        )
                                        .toList();
                            });
                          },
                          autofocus: true,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: filtered.length,
                      itemBuilder: (ctx, i) {
                        final tz = filtered[i];
                        return ListTile(
                          title: Text(tz),
                          selected: tz == current,
                          onTap: () => Navigator.pop(ctx, tz),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (selected != null && selected != current) {
      final repo = ref.read(calendarRepositoryProvider).value;
      repo?.upsertCalendar(
        calendar.copyWith(
          timezone: selected,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      ref.invalidate(calendarsProvider);
    }
  }
}

class _ManageCalendarsScreen extends ConsumerWidget {
  const _ManageCalendarsScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calendarsAsync = ref.watch(calendarsProvider);
    final selected =
        ref.watch(selectedCalendarIdProvider) ?? kDefaultCalendarId;
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Calendars')),
      body: calendarsAsync.when(
        data: (calendars) => ListView(
          children: [
            for (final calendar in calendars)
              SwitchListTile(
                secondary: CircleAvatar(
                  radius: 9,
                  backgroundColor: _parseHexColor(calendar.color),
                ),
                title: Text(calendar.name),
                subtitle: Text(calendar.timezone),
                value: calendar.isVisible,
                onChanged: (value) {
                  final repo = ref.read(calendarRepositoryProvider).value;
                  repo?.upsertCalendar(
                    calendar.copyWith(
                      isVisible: value,
                      updatedAt: DateTime.now().toUtc(),
                    ),
                  );
                  ref.invalidate(calendarsProvider);
                  ref.invalidate(eventsForDayProvider);
                },
              ),
            const Divider(height: 1),
            for (final calendar in calendars)
              RadioListTile<String>(
                title: Text('Default for new events: ${calendar.name}'),
                value: calendar.id,
                groupValue: selected,
                onChanged: (value) {
                  ref.read(selectedCalendarIdProvider.notifier).set(value);
                },
              ),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addCalendar(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
    );
  }

  Future<void> _addCalendar(BuildContext context, WidgetRef ref) async {
    final nameController = TextEditingController();
    var color =
        _calendarPalette[DateTime.now().millisecond % _calendarPalette.length];
    final selectedTimezone = await TimezoneService.getDeviceTimezone();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('New Calendar'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Calendar name'),
              ),
              const SizedBox(height: 12),
              const Text('Color'),
              Wrap(
                spacing: 8,
                children: [
                  for (final swatch in _calendarPalette)
                    GestureDetector(
                      onTap: () => setDialogState(() => color = swatch),
                      child: CircleAvatar(
                        radius: 12,
                        backgroundColor: _parseHexColor(swatch),
                        child: color == swatch
                            ? const Icon(
                                Icons.check,
                                size: 14,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    final name = nameController.text.trim();
    if (name.isEmpty) return;

    final now = DateTime.now().toUtc();
    final newCalendar = CalendarInfo(
      id: const Uuid().v4(),
      name: name,
      timezone: selectedTimezone,
      color: color,
      isVisible: true,
      sortOrder: DateTime.now().millisecondsSinceEpoch,
      createdAt: now,
      updatedAt: now,
    );

    final repo = ref.read(calendarRepositoryProvider).value;
    repo?.upsertCalendar(newCalendar);
    ref.invalidate(calendarsProvider);
    ref.read(selectedCalendarIdProvider.notifier).set(newCalendar.id);

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added calendar "${newCalendar.name}"')),
      );
    }
  }
}

Color _parseHexColor(String value) {
  final cleaned = value.replaceAll('#', '').trim();
  final normalized = cleaned.length == 6 ? 'FF$cleaned' : cleaned;
  final parsed = int.tryParse(normalized, radix: 16);
  if (parsed == null) return Colors.blueGrey;
  return Color(parsed);
}
