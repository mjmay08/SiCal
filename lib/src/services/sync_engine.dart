import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import '../bridge/sia_bridge.dart' show SiaBridge;
import '../database/database.dart';
import '../models/chunk.dart';
import '../ui/widgets/sync_status_banner.dart';
import 'sia_storage_service.dart';

typedef ProgressCallback =
    void Function({
      SyncPhase? phase,
      String? message,
      int? current,
      int? total,
    });

void _log(String msg) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  dev.log('[$ts] $msg', name: 'SyncEngine');
}

/// Coordinates pushing local changes to Sia and pulling remote changes.
class SyncEngine {
  final AppDatabase _db;
  final SiaStorageService _sia;

  SyncEngine(this._db, this._sia);

  /// Full sync: pull remote changes, then push local dirty changes.
  Future<void> fullSync({ProgressCallback? onProgress}) async {
    _log('fullSync START');
    await pullChanges(onProgress: onProgress);
    await pushChanges(onProgress: onProgress);
    onProgress?.call(phase: SyncPhase.done, message: 'Sync complete');
    _log('fullSync DONE');
  }

  /// Pull changes from Sia using the cursor-based event stream.
  Future<void> pullChanges({ProgressCallback? onProgress}) async {
    _log('pullChanges START');
    onProgress?.call(
      phase: SyncPhase.pulling,
      message: 'Checking for remote changes...',
    );
    final syncState = _db.getSyncState();
    var cursorAfter = syncState?.cursor ?? '';
    var cursorId = syncState?.cursorId ?? '';

    _log(
      'pullChanges listObjects(cursor=${cursorAfter.isEmpty ? "<empty>" : cursorAfter})',
    );
    final (events, newCursorAfter, newCursorId) = await _sia.listObjects(
      cursorAfter,
      cursorId,
    );
    _log('pullChanges got ${events.length} event(s)');

    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      onProgress?.call(
        phase: SyncPhase.pulling,
        message: 'Downloading remote changes...',
        current: i + 1,
        total: events.length,
      );
      if (event.deleted) {
        _handleDeletedEvent(event);
      } else {
        await _handlePinnedEvent(event);
      }
    }

    _db.updateSyncCursor(newCursorAfter, newCursorId);
    _log('pullChanges DONE');
  }

  /// Push local dirty changes to Sia.
  ///
  /// Re-uploads ALL chunks (not just dirty ones) plus the manifest into a
  /// single packed upload so they share one slab (~40 MB).  Then deletes every
  /// old object so the previous slab(s) can be pruned, keeping total storage
  /// at one slab regardless of how many chunks exist.
  Future<void> pushChanges({ProgressCallback? onProgress}) async {
    final dirtyPeriods = _db.getDirtyPeriods();
    if (dirtyPeriods.isEmpty) {
      _log('pushChanges — no dirty periods, skipping');
      return;
    }
    _log(
      'pushChanges START — ${dirtyPeriods.length} dirty period(s): $dirtyPeriods',
    );

    final manifest = _db.getManifest();

    // Collect ALL old object IDs (every chunk + manifest) so we can delete
    // them after uploading the new slab.
    final oldIdsToDelete = <String>[];
    final oldManifestId = manifest?.objectId;
    if (oldManifestId != null && oldManifestId.isNotEmpty) {
      oldIdsToDelete.add(oldManifestId);
    }

    // Build the full chunk map from the database.
    final allPeriods = _db.getAllChunkPeriods().toSet();
    // Also include dirty periods that may not have a chunk row yet.
    allPeriods.addAll(dirtyPeriods);

    // Mark dirty events clean & handle deleted periods.
    final deletedPeriods = <String>[];
    for (final period in dirtyPeriods) {
      final events = _db.getAllEventsForPeriod(period);
      if (events.isEmpty) {
        deletedPeriods.add(period);
        _db.deleteChunk(period);
      }
      _db.markEventsClean(period);
    }

    // Remove deleted periods from the set of periods to upload.
    allPeriods.removeAll(deletedPeriods);

    // Build uploads for EVERY live chunk + manifest.
    final uploads = <PackedUpload>[];
    final uploadPeriods = <String>[];

    for (final period in allPeriods) {
      final events = _db.getAllEventsForPeriod(period);
      if (events.isEmpty) continue; // safety: skip empty periods

      final chunk = Chunk(period: period, events: events);
      final metadataJson = '{"type":"chunk","period":"$period"}';
      uploads.add(
        PackedUpload(dataJson: chunk.encode(), metadataJson: metadataJson),
      );
      uploadPeriods.add(period);

      // Schedule old chunk object for deletion.
      final existing = _db.getChunk(period);
      final oldOid = existing?['object_id'] as String?;
      if (oldOid != null && oldOid.isNotEmpty) {
        oldIdsToDelete.add(oldOid);
      }
    }

    // Add manifest as the last upload item (calendar settings only).
    final manifestData = jsonEncode({
      'calendar_name': manifest?.calendarName ?? 'My Calendar',
      'timezone': manifest?.timezone ?? 'UTC',
      'color': manifest?.color ?? '#1ED660',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    uploads.add(
      PackedUpload(dataJson: manifestData, metadataJson: '{"type":"manifest"}'),
    );
    final manifestIndex = uploads.length - 1;
    _log(
      'pushChanges uploading ${uploads.length} item(s) packed (${uploadPeriods.length} chunk(s) + 1 manifest)',
    );

    // Single packed upload — all chunks + manifest share one slab.
    // Poll shard-level progress from Rust every 200ms for granular UI updates.
    onProgress?.call(
      phase: SyncPhase.uploading,
      message: 'Uploading to Sia network...',
      current: 0,
      total: 0,
    );

    Timer? shardTimer;
    if (onProgress != null) {
      shardTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        final sp = SiaBridge.getShardProgress();
        if (sp.total > 0) {
          onProgress.call(
            phase: SyncPhase.uploading,
            message: 'Uploading shard ${sp.current}/${sp.total}...',
            current: sp.current,
            total: sp.total,
          );
        }
      });
    }

    final ids = await _sia.uploadPacked(uploads);
    shardTimer?.cancel();

    // Send final shard progress.
    final finalSp = SiaBridge.getShardProgress();
    onProgress?.call(
      phase: SyncPhase.uploading,
      message: 'Upload complete (${finalSp.total} shards)',
      current: finalSp.total,
      total: finalSp.total,
    );
    _log('pushChanges packed upload done — got ${ids.length} ID(s)');

    // Map new chunk IDs back to periods.
    final chunks = <String, String>{};
    for (var i = 0; i < uploadPeriods.length; i++) {
      final period = uploadPeriods[i];
      final newObjectId = ids[i];
      chunks[period] = newObjectId;
      _db.upsertChunk(period, newObjectId, 0);
    }

    // Update manifest metadata with the real chunk map.
    final manifestObjectId = ids[manifestIndex];
    final chunkMapMeta = jsonEncode({'type': 'manifest', 'chunks': chunks});
    _log(
      'pushChanges updating manifest metadata (${chunkMapMeta.length} bytes)',
    );
    onProgress?.call(
      phase: SyncPhase.updatingMetadata,
      message: 'Updating metadata...',
    );
    await _sia.updateMetadata(manifestObjectId, chunkMapMeta);
    _log('pushChanges metadata updated');

    _db.upsertManifest(objectId: manifestObjectId);

    // Delete ALL old objects so the previous slab(s) can be fully pruned.
    if (oldIdsToDelete.isNotEmpty) {
      _log('pushChanges deleting ${oldIdsToDelete.length} old object(s)');
    }
    for (var i = 0; i < oldIdsToDelete.length; i++) {
      final oldId = oldIdsToDelete[i];
      onProgress?.call(
        phase: SyncPhase.cleaning,
        message: 'Cleaning up old data...',
        current: i + 1,
        total: oldIdsToDelete.length,
      );
      try {
        await _sia.deleteObject(oldId);
        _log('pushChanges deleted ${oldId.substring(0, 12)}…');
      } catch (e) {
        _log('pushChanges delete ${oldId.substring(0, 12)}… failed: $e');
      }
    }
    _log('pushChanges DONE');
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  Future<void> _handlePinnedEvent(SiaObjectEvent event) async {
    if (event.metadataJson == null) return;

    final meta = jsonDecode(event.metadataJson!) as Map<String, dynamic>;
    final type = meta['type'] as String?;

    if (type == 'chunk') {
      final period = meta['period'] as String;
      final (dataJson, _) = await _sia.downloadObject(event.objectId);
      final chunk = Chunk.decode(dataJson);

      for (final calEvent in chunk.events) {
        _db.upsertEvent(calEvent.copyWith(isDirty: false));
      }
      _db.upsertChunk(period, event.objectId, 0);
    } else if (type == 'manifest') {
      final (dataJson, _) = await _sia.downloadObject(event.objectId);
      // Calendar settings are in the object data.
      final settings = jsonDecode(dataJson) as Map<String, dynamic>;
      // Chunk map is in the Sia metadata.
      final chunkMap = meta['chunks'] as Map<String, dynamic>?;

      _db.upsertManifest(
        objectId: event.objectId,
        calendarName:
            settings['calendar_name'] as String? ??
            settings['calendarName'] as String?,
        timezone: settings['timezone'] as String?,
        color: settings['color'] as String?,
      );

      // If chunk map present in metadata, sync those chunks too.
      if (chunkMap != null) {
        for (final entry in chunkMap.entries) {
          final period = entry.key;
          final chunkObjectId = entry.value as String;
          // Download and upsert each chunk we don't already have.
          final existing = _db.getChunk(period);
          final existingId = existing?['object_id'] as String?;
          if (existingId != chunkObjectId) {
            try {
              final (chunkDataJson, _) = await _sia.downloadObject(
                chunkObjectId,
              );
              final chunk = Chunk.decode(chunkDataJson);
              for (final calEvent in chunk.events) {
                _db.upsertEvent(calEvent.copyWith(isDirty: false));
              }
              _db.upsertChunk(period, chunkObjectId, 0);
            } catch (_) {
              // chunk may have been deleted; skip
            }
          }
        }
      }
    }
  }

  void _handleDeletedEvent(SiaObjectEvent event) {
    // Deleted events from Sia — for MVP, full-sync re-downloads manifest.
  }
}
