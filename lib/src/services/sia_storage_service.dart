import 'dart:convert';
import 'dart:typed_data';
import '../bridge/sia_bridge.dart' hide SiaObjectEvent;

/// Wraps the Rust bridge with calendar-specific Sia operations.
/// Handles upload/download of manifest and chunk objects.
class SiaStorageService {
  /// Upload a chunk (month of events) packed into shared slabs.
  /// Returns the new object ID.
  Future<String> uploadChunk(String period, String chunkJson) async {
    final metadataJson = jsonEncode({'type': 'chunk', 'period': period});
    final ids = await _uploadPackedSingle(chunkJson, metadataJson);
    return ids;
  }

  /// Upload the manifest packed into shared slabs. Returns the new object ID.
  Future<String> uploadManifest(
    String manifestJson, {
    String? calendarId,
  }) async {
    final metadataJson = jsonEncode({
      'type': 'manifest',
      if (calendarId != null && calendarId.isNotEmpty)
        'calendar_id': calendarId,
    });
    return _uploadPackedSingle(manifestJson, metadataJson);
  }

  /// Upload multiple objects packed into shared slabs. Returns object IDs in
  /// the same order as [items].
  Future<List<String>> uploadPacked(List<PackedUpload> items) async {
    final uploadItems = items
        .map(
          (item) => UploadItem(
            data: Uint8List.fromList(utf8.encode(item.dataJson)),
            metadataJson: item.metadataJson,
          ),
        )
        .toList();
    return SiaBridge.uploadPackedAndPin(uploadItems);
  }

  /// Helper: upload a single small object via packed upload to avoid
  /// allocating a full ~40 MB slab.
  Future<String> _uploadPackedSingle(
    String dataJson,
    String metadataJson,
  ) async {
    final ids = await SiaBridge.uploadPackedAndPin([
      UploadItem(
        data: Uint8List.fromList(utf8.encode(dataJson)),
        metadataJson: metadataJson,
      ),
    ]);
    return ids.first;
  }

  /// Download an object by ID. Returns (dataJson, metadataJson).
  Future<(String, String)> downloadObject(String objectId) async {
    final obj = await SiaBridge.downloadObject(objectId);
    final dataJson = utf8.decode(obj.data);
    return (dataJson, obj.metadataJson);
  }

  /// Delete a Sia object by ID.
  Future<void> deleteObject(String objectId) async {
    await SiaBridge.deleteObject(objectId);
  }

  /// Fetch one page of object events since cursor for incremental sync.
  /// Returns (events, lastEventUpdatedAt, lastEventId, hasMore).
  Future<(List<SiaObjectEvent>, String, String, bool)> listObjects(
    String cursorAfter,
    String cursorId,
  ) async {
    final result = await SiaBridge.listObjects(cursorAfter, cursorId, 100);
    final events = result.events
        .map(
          (e) => SiaObjectEvent(
            objectId: e.objectId,
            deleted: e.deleted,
            metadataJson: e.metadataJson,
          ),
        )
        .toList();

    final lastUpdatedAt = result.events.isNotEmpty
        ? result.events.last.updatedAt
        : cursorAfter;
    final lastId = result.events.isNotEmpty
        ? result.events.last.objectId
        : cursorId;

    return (events, lastUpdatedAt, lastId, result.hasMore);
  }

  /// Update metadata on a pinned object without re-uploading data.
  Future<void> updateMetadata(String objectId, String metadataJson) async {
    await SiaBridge.updateObjectMetadata(objectId, metadataJson);
  }
}

class SiaObjectEvent {
  final String objectId;
  final bool deleted;
  final String? metadataJson;

  const SiaObjectEvent({
    required this.objectId,
    required this.deleted,
    this.metadataJson,
  });
}

/// Describes a single item for packed upload.
class PackedUpload {
  final String dataJson;
  final String metadataJson;

  const PackedUpload({required this.dataJson, required this.metadataJson});
}
