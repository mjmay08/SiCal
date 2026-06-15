import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import '../bridge/sia_bridge.dart' show SiaBridge;
import '../database/database.dart';
import '../models/chunk.dart';
import '../models/event.dart';
import 'event_notification_service.dart';
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
  final line = '[$ts] [SYNC_TRACE] $msg';
  dev.log(line, name: 'SyncEngine');
  print('[SyncEngine] $line');
}

/// Coordinates pushing local changes to Sia and pulling remote changes.
class SyncEngine {
  static const Duration _packedUploadTimeout = Duration(minutes: 10);
  static const Duration _manifestUploadTimeout = Duration(minutes: 10);

  final AppDatabase _db;
  final SiaStorageService _sia;

  SyncEngine(this._db, this._sia);

  /// Full sync: pull remote changes, then push local dirty changes.
  Future<void> fullSync({ProgressCallback? onProgress}) async {
    final fullSyncWatch = Stopwatch()..start();
    _log('fullSync START');

    final calendars = _db.getCalendars();
    final targetIds = calendars.isEmpty
        ? <String>[kDefaultCalendarId]
        : calendars.map((c) => c.id).toList();

    for (var i = 0; i < targetIds.length; i++) {
      final calendarId = targetIds[i];
      final calendarWatch = Stopwatch()..start();
      String? name;
      for (final c in calendars) {
        if (c.id == calendarId) {
          name = c.name;
          break;
        }
      }
      onProgress?.call(
        phase: SyncPhase.pulling,
        message:
            'Syncing ${name ?? 'Calendar'} (${i + 1}/${targetIds.length})...',
      );
      await pullChanges(calendarId: calendarId, onProgress: onProgress);
      await pushChanges(calendarId: calendarId, onProgress: onProgress);
      calendarWatch.stop();
      _log(
        'fullSync calendar DONE [$calendarId] in ${calendarWatch.elapsedMilliseconds}ms',
      );
    }

    unawaited(EventNotificationService.rescheduleAll(_db));

    onProgress?.call(phase: SyncPhase.done, message: 'Sync complete');
    fullSyncWatch.stop();
    _log('fullSync DONE in ${fullSyncWatch.elapsedMilliseconds}ms');
  }

  /// Pull changes from Sia using the cursor-based event stream.
  Future<void> pullChanges({
    required String calendarId,
    ProgressCallback? onProgress,
  }) async {
    _log('pullChanges START [$calendarId]');
    onProgress?.call(
      phase: SyncPhase.pulling,
      message: 'Checking for remote changes...',
    );
    final syncState = _db.getSyncState(calendarId: calendarId);
    var cursorAfter = syncState?.cursor ?? '';
    var cursorId = syncState?.cursorId ?? '';

    var hasMore = true;
    var totalProcessed = 0;
    while (hasMore) {
      _log(
        'pullChanges listObjects(cursor=${cursorAfter.isEmpty ? "<empty>" : cursorAfter})',
      );
      final (events, newCursorAfter, newCursorId, more) = await _sia
          .listObjects(cursorAfter, cursorId);
      _log('pullChanges got ${events.length} event(s), hasMore=$more');

      for (var i = 0; i < events.length; i++) {
        final event = events[i];
        totalProcessed++;
        onProgress?.call(
          phase: SyncPhase.pulling,
          message: 'Downloading remote changes...',
          current: totalProcessed,
          total: 0,
        );
        if (event.deleted) {
          _handleDeletedEvent(event, calendarId: calendarId);
        } else {
          await _handlePinnedEvent(event, fallbackCalendarId: calendarId);
        }
      }

      cursorAfter = newCursorAfter;
      cursorId = newCursorId;
      _db.updateSyncCursor(cursorAfter, cursorId, calendarId: calendarId);

      // Stop if there are no more pages, or if an empty page was returned
      // (guard against an infinite loop on a misbehaving server).
      hasMore = more && events.isNotEmpty;
    }
    _log('pullChanges DONE [$calendarId] — $totalProcessed event(s) total');
  }

  /// Push local dirty changes to Sia.
  ///
  /// Re-uploads ALL chunks (not just dirty ones) plus the manifest into a
  /// single packed upload so they share one slab (~40 MB).  Then deletes every
  /// old object so the previous slab(s) can be pruned, keeping total storage
  /// at one slab regardless of how many chunks exist.
  Future<void> pushChanges({
    required String calendarId,
    ProgressCallback? onProgress,
  }) async {
    final dirtyPeriods = _db.getDirtyPeriods(calendarIds: [calendarId]);
    if (dirtyPeriods.isEmpty) {
      _log('pushChanges [$calendarId] — no dirty periods, skipping');
      return;
    }
    _log(
      'pushChanges START [$calendarId] — ${dirtyPeriods.length} dirty period(s): $dirtyPeriods',
    );

    final manifest = _db.getManifest(calendarId: calendarId);

    // Collect ALL old object IDs (every chunk + manifest) so we can delete
    // them after uploading the new slab.
    final oldIdsToDelete = <String>[];
    final oldManifestId = manifest?.objectId;
    if (oldManifestId != null && oldManifestId.isNotEmpty) {
      oldIdsToDelete.add(oldManifestId);
    }

    // Build the full chunk map from the database.
    final allPeriods = _db.getAllChunkPeriods(calendarId: calendarId).toSet();
    // Also include dirty periods that may not have a chunk row yet.
    allPeriods.addAll(dirtyPeriods);

    // Identify deleted periods (all live events have been soft-deleted).
    // Do NOT mark events clean yet — that only happens after the upload
    // succeeds, so an interrupted sync can be retried on next launch.
    final deletedPeriods = <String>[];
    for (final period in dirtyPeriods) {
      final events = _db.getAllEventsForPeriod(
        period,
        calendarIds: [calendarId],
      );
      if (events.isEmpty) {
        deletedPeriods.add(period);
        _db.deleteChunk(period, calendarId: calendarId);
      }
    }

    // Remove deleted periods from the set of periods to upload.
    allPeriods.removeAll(deletedPeriods);

    // Build uploads for EVERY live chunk + manifest.
    final uploads = <PackedUpload>[];
    final uploadPeriods = <String>[];

    for (final period in allPeriods) {
      final events = _db.getAllEventsForPeriod(
        period,
        calendarIds: [calendarId],
      );
      if (events.isEmpty) continue; // safety: skip empty periods

      final chunk = Chunk(period: period, events: events);
      final metadataJson =
          '{"type":"chunk","period":"$period","calendar_id":"$calendarId"}';
      uploads.add(
        PackedUpload(dataJson: chunk.encode(), metadataJson: metadataJson),
      );
      uploadPeriods.add(period);

      // Schedule old chunk object for deletion.
      final existing = _db.getChunk(period, calendarId: calendarId);
      final oldOid = existing?['object_id'] as String?;
      if (oldOid != null && oldOid.isNotEmpty) {
        oldIdsToDelete.add(oldOid);
      }
    }

    _log(
      'pushChanges uploading ${uploads.length} item(s) packed (${uploadPeriods.length} chunk(s))',
    );

    // Pass 1: Upload all chunks in a single packed slab.
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

    final packedUploadWatch = Stopwatch()..start();
    List<String> ids;
    try {
      _log(
        'pushChanges packed upload START [$calendarId] items=${uploads.length}',
      );
      ids = uploads.isNotEmpty
          ? await _sia.uploadPacked(uploads).timeout(_packedUploadTimeout)
          : <String>[];
      packedUploadWatch.stop();
      _log(
        'pushChanges packed upload DONE [$calendarId] in ${packedUploadWatch.elapsedMilliseconds}ms',
      );
    } on TimeoutException {
      packedUploadWatch.stop();
      _log(
        'pushChanges packed upload TIMEOUT [$calendarId] after ${packedUploadWatch.elapsedMilliseconds}ms',
      );
      rethrow;
    } finally {
      shardTimer?.cancel();
    }

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
      _db.upsertChunk(period, newObjectId, 0, calendarId: calendarId);
    }

    // Pass 2: Upload manifest with the chunk map embedded in its data.
    // This avoids storing the chunk map in Sia object metadata, which has a
    // 1024-byte limit that is easily exceeded with many months of events.
    onProgress?.call(
      phase: SyncPhase.updatingMetadata,
      message: 'Uploading manifest...',
    );
    final manifestData = jsonEncode({
      'calendar_name': manifest?.calendarName ?? 'My Calendar',
      'timezone': manifest?.timezone ?? 'UTC',
      'color': manifest?.color ?? '#1ED660',
      'calendar_id': calendarId,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'chunks': chunks,
    });
    _log(
      'pushChanges uploading manifest (data=${manifestData.length} bytes, ${chunks.length} chunk(s))',
    );
    final manifestUploadWatch = Stopwatch()..start();
    late final String manifestObjectId;
    try {
      _log('pushChanges manifest upload START [$calendarId]');
      manifestObjectId = await _sia
          .uploadManifest(manifestData, calendarId: calendarId)
          .timeout(_manifestUploadTimeout);
      manifestUploadWatch.stop();
      _log(
        'pushChanges manifest upload DONE [$calendarId] in ${manifestUploadWatch.elapsedMilliseconds}ms',
      );
    } on TimeoutException {
      manifestUploadWatch.stop();
      _log(
        'pushChanges manifest upload TIMEOUT [$calendarId] after ${manifestUploadWatch.elapsedMilliseconds}ms',
      );
      rethrow;
    }
    _log(
      'pushChanges manifest uploaded → ${manifestObjectId.substring(0, 12)}…',
    );

    _db.upsertManifest(calendarId: calendarId, objectId: manifestObjectId);

    // Upload succeeded — now safe to mark dirty periods as clean.
    // This physically removes soft-deleted rows and clears the is_dirty flag.
    // Doing this after the upload means an interrupted sync is retried cleanly.
    for (final period in dirtyPeriods) {
      _db.markEventsClean(period, calendarId: calendarId);
    }

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
    _log('pushChanges DONE [$calendarId]');
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  Future<void> _handlePinnedEvent(
    SiaObjectEvent event, {
    required String fallbackCalendarId,
  }) async {
    if (event.metadataJson == null) return;

    final meta = jsonDecode(event.metadataJson!) as Map<String, dynamic>;
    final type = meta['type'] as String?;
    final calendarId = meta['calendar_id'] as String? ?? fallbackCalendarId;

    if (type == 'chunk') {
      final period = meta['period'] as String;
      final (dataJson, _) = await _sia.downloadObject(event.objectId);
      final chunk = Chunk.decode(dataJson);

      for (final calEvent in chunk.events) {
        _db.upsertRemoteEvent(
          calEvent.copyWith(calendarId: calendarId, isDirty: false),
        );
      }
      _db.upsertChunk(period, event.objectId, 0, calendarId: calendarId);
    } else if (type == 'manifest') {
      final (dataJson, _) = await _sia.downloadObject(event.objectId);
      // Calendar settings are in the object data.
      final settings = jsonDecode(dataJson) as Map<String, dynamic>;
      final manifestCalendarId =
          settings['calendar_id'] as String? ?? calendarId;
      // Chunk map is stored in the manifest data (new format) or Sia metadata
      // (old format, kept for backward compatibility).
      final chunkMap =
          (settings['chunks'] ?? meta['chunks']) as Map<String, dynamic>?;

      _db.upsertManifest(
        calendarId: manifestCalendarId,
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
          final existing = _db.getChunk(period, calendarId: manifestCalendarId);
          final existingId = existing?['object_id'] as String?;
          if (existingId != chunkObjectId) {
            try {
              final (chunkDataJson, _) = await _sia.downloadObject(
                chunkObjectId,
              );
              final chunk = Chunk.decode(chunkDataJson);
              for (final calEvent in chunk.events) {
                _db.upsertRemoteEvent(
                  calEvent.copyWith(
                    calendarId: manifestCalendarId,
                    isDirty: false,
                  ),
                );
              }
              _db.upsertChunk(
                period,
                chunkObjectId,
                0,
                calendarId: manifestCalendarId,
              );
            } catch (_) {
              // chunk may have been deleted; skip
            }
          }
        }
      }
    }
  }

  void _handleDeletedEvent(SiaObjectEvent event, {required String calendarId}) {
    // Deleted events from Sia — for MVP, full-sync re-downloads manifest.
  }
}
