import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../bridge/sia_bridge.dart';
import '../../database/database.dart';
import '../../repositories/calendar_repository.dart';
import '../../services/auth_service.dart';
import '../../services/ics_import_service.dart';

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
    final dbAsync = ref.watch(appDatabaseProvider);
    return dbAsync.when(
      data: (db) {
        final manifest = db.getManifest();
        return ListTile(
          leading: const Icon(Icons.edit),
          title: const Text('Calendar Name'),
          subtitle: Text(manifest?.calendarName ?? 'My Calendar'),
          onTap: () =>
              _editName(context, db, manifest?.calendarName ?? 'My Calendar'),
        );
      },
      loading: () => const ListTile(title: Text('Calendar Name')),
      error: (_, __) => const ListTile(title: Text('Calendar Name')),
    );
  }

  void _editName(BuildContext context, AppDatabase db, String current) {
    final controller = TextEditingController(text: current);
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
                db.upsertManifest(calendarName: name);
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
