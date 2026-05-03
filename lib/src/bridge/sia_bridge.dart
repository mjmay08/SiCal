import 'dart:typed_data';

import 'package:sical/src/rust/api.dart' as rust;
import 'package:sical/src/rust/frb_generated.dart';

// Re-export generated types so existing consumers keep working.
export 'package:sical/src/rust/api.dart'
    show ShardProgressInfo, SiaObject, SiaObjectEvent, SyncResult, UploadItem;

// ---------------------------------------------------------------------------
// Bridge — thin wrapper that delegates to flutter_rust_bridge generated code.
// ---------------------------------------------------------------------------

class SiaBridge {
  SiaBridge._();

  /// Must be called once at app startup before any other bridge method.
  static Future<void> init() => RustLib.init();

  // ---- Connection / Auth ------------------------------------------------

  static Future<String> requestConnection() => rust.requestConnection();

  static Future<String> registerWithPhrase(String recoveryPhrase) =>
      rust.registerWithPhrase(recoveryPhrase: recoveryPhrase);

  static String generateRecoveryPhrase() => rust.generateRecoveryPhrase();

  static void validatePhrase(String phrase) =>
      rust.validatePhrase(phrase: phrase);

  static Future<void> connect(String appKeyHex) =>
      rust.connect(appKeyHex: appKeyHex);

  // ---- Object Operations ------------------------------------------------

  static Future<String> uploadAndPin(Uint8List data, String metadataJson) =>
      rust.uploadAndPin(data: data, metadataJson: metadataJson);

  static Future<List<String>> uploadPackedAndPin(List<rust.UploadItem> items) =>
      rust.uploadPackedAndPin(items: items);

  static Future<rust.SiaObject> downloadObject(String objectId) =>
      rust.downloadObject(objectId: objectId);

  static Future<void> updateObjectMetadata(
    String objectId,
    String metadataJson,
  ) =>
      rust.updateObjectMetadata(objectId: objectId, metadataJson: metadataJson);

  static Future<void> deleteObject(String objectId) =>
      rust.deleteObject(objectId: objectId);

  static Future<rust.SyncResult> listObjects(
    String cursorAfter,
    String cursorId,
    int limit,
  ) => rust.listObjects(
    cursorAfter: cursorAfter,
    cursorId: cursorId,
    limit: limit,
  );

  static Future<String> shareObject(String objectId, int expiresHours) =>
      rust.shareObject(objectId: objectId, expiresHours: expiresHours);

  static Future<int> deleteAllObjects() => rust.deleteAllObjects();

  // ---- Progress --------------------------------------------------------

  static rust.ShardProgressInfo getShardProgress() => rust.getShardProgress();
}
