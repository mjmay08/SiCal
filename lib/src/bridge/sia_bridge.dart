import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sia_storage/sia_storage.dart';

class SiaBridge {
  SiaBridge._();

  static const _indexerUrl = 'https://sia.storage';
  static final AppMetadata _appMeta = AppMetadata(
    id: Uint8List.fromList(
      _hexToBytes(
        'e3a1f8c6d4b2097531a6e8f4c2d0b7a5e3f1c6d4b209753100000000ca1eda42',
      ),
    ),
    name: 'SiCal',
    description: 'Decentralized calendar powered by the Sia network',
    serviceUrl: 'https://github.com/mjmay08/SiCal',
    logoUrl:
        'https://raw.githubusercontent.com/mjmay08/SiCal/refs/heads/main/assets/icon.png',
  );

  static Builder? _pendingBuilder;
  static Sdk? _sdk;

  static int _shardCurrent = 0;
  static int _shardTotal = 0;

  /// Must be called once at app startup before any other bridge method.
  static Future<void> init() => Sia.ready();

  // ---- Connection / Auth ------------------------------------------------

  static Future<String> requestConnection() async {
    final builder = await _newBuilder();
    await builder.requestConnection();
    return builder.responseUrl();
  }

  static Future<void> waitForApproval() async {
    final builder = _pendingBuilder;
    if (builder == null) {
      throw StateError(
        'no pending onboarding - call requestConnection() first',
      );
    }
    await builder.waitForApproval();
  }

  static Future<String> registerWithPhrase(String recoveryPhrase) async {
    final builder = _pendingBuilder;
    if (builder == null) {
      throw StateError(
        'no pending onboarding - call requestConnection() first',
      );
    }

    final sdk = await builder.register(mnemonic: recoveryPhrase);
    final appKey = sdk.appKey();
    final appKeyHex = _bytesToHex(appKey.export_());

    _sdk = sdk;
    _pendingBuilder = null;

    return appKeyHex;
  }

  static Future<String> generateRecoveryPhrase() =>
      Sia.generateRecoveryPhrase();

  static Future<void> validatePhrase(String phrase) =>
      Sia.validateRecoveryPhrase(phrase);

  static Future<void> connect(String appKeyHex) async {
    final appKey = await Sia.appKey(_hexToBytes(appKeyHex));
    final builder = await _newBuilder();
    final sdk = await builder.connected(appKey: appKey);
    if (sdk == null) {
      throw StateError('invalid or revoked App Key');
    }

    _sdk = sdk;
    _pendingBuilder = null;
  }

  // ---- Object Operations ------------------------------------------------

  static Future<String> uploadAndPin(
    Uint8List data,
    String metadataJson,
  ) async {
    final sdk = _requireSdk();
    final upload = sdk.upload(
      object: PinnedObject(),
      source: Stream.value(data),
    );
    final obj = await upload.result;
    obj.updateMetadata(metadata: utf8.encode(metadataJson));
    await sdk.pinObject(object: obj);
    return obj.id();
  }

  static Future<List<String>> uploadPackedAndPin(List<UploadItem> items) async {
    final sdk = _requireSdk();

    const dataShards = 3;
    const parityShards = 9;

    _shardCurrent = 0;
    _shardTotal = 0;

    final session = sdk.uploadPacked(
      options: const UploadOptions(
        dataShards: dataShards,
        parityShards: parityShards,
      ),
    );
    final sub = session.progress.listen((_) {
      _shardCurrent += 1;
    });

    try {
      for (final item in items) {
        await session.upload.add(Stream.value(item.data));
      }

      final slabCount = session.upload.slabs().toInt();
      _shardTotal = slabCount * (dataShards + parityShards);

      final objects = await session.upload.finalize();
      final ids = <String>[];

      for (var i = 0; i < objects.length; i++) {
        final obj = objects[i];
        if (i < items.length) {
          obj.updateMetadata(metadata: utf8.encode(items[i].metadataJson));
        }
        await sdk.pinObject(object: obj);
        ids.add(obj.id());
      }

      if (_shardTotal == 0) {
        _shardTotal = _shardCurrent;
      }

      return ids;
    } finally {
      await sub.cancel();
    }
  }

  static Future<SiaObject> downloadObject(String objectId) async {
    final sdk = _requireSdk();
    final obj = await sdk.object(key: objectId);

    final bytes = BytesBuilder(copy: false);
    final download = sdk.download(object: obj);
    await for (final chunk in download.data) {
      bytes.add(chunk);
    }
    final data = bytes.takeBytes();

    final metadataJson = utf8.decode(obj.metadata(), allowMalformed: true);

    return SiaObject(
      objectId: objectId,
      data: data,
      metadataJson: metadataJson,
      size: data.length,
    );
  }

  static Future<void> updateObjectMetadata(
    String objectId,
    String metadataJson,
  ) async {
    final sdk = _requireSdk();
    final obj = await sdk.object(key: objectId);
    obj.updateMetadata(metadata: utf8.encode(metadataJson));
    await sdk.updateObjectMetadata(object: obj);
  }

  static Future<void> deleteObject(String objectId) async {
    final sdk = _requireSdk();
    await sdk.deleteObject(key: objectId);
    await sdk.pruneSlabs();
  }

  static Future<SyncResult> listObjects(
    String cursorAfter,
    String cursorId,
    int limit,
  ) async {
    final sdk = _requireSdk();

    final cursor = cursorAfter.isEmpty
        ? null
        : ObjectsCursor(id: cursorId, after: DateTime.parse(cursorAfter));

    final events = await sdk.objectEvents(cursor: cursor, limit: limit);
    final mapped = events
        .map(
          (event) => SiaObjectEvent(
            objectId: event.id,
            deleted: event.deleted,
            metadataJson: event.object == null
                ? null
                : utf8.decode(event.object!.metadata(), allowMalformed: true),
            updatedAt: event.updatedAt.toUtc().toIso8601String(),
          ),
        )
        .toList();

    return SyncResult(events: mapped, hasMore: events.length == limit);
  }

  static Future<String> shareObject(String objectId, int expiresHours) async {
    final sdk = _requireSdk();
    final obj = await sdk.object(key: objectId);
    return sdk.shareObject(
      object: obj,
      validUntil: DateTime.now().toUtc().add(Duration(hours: expiresHours)),
    );
  }

  static Future<int> deleteAllObjects() async {
    final sdk = _requireSdk();
    var deleted = 0;
    ObjectsCursor? cursor;

    while (true) {
      final events = await sdk.objectEvents(cursor: cursor, limit: 100);
      if (events.isEmpty) {
        break;
      }

      for (final event in events) {
        if (!event.deleted) {
          try {
            await sdk.deleteObject(key: event.id);
            deleted += 1;
          } catch (_) {
            // Best effort cleanup; continue deleting remaining objects.
          }
        }
      }

      final last = events.last;
      cursor = ObjectsCursor(id: last.id, after: last.updatedAt);
    }

    await sdk.pruneSlabs();
    return deleted;
  }

  // ---- Progress ---------------------------------------------------------

  static ShardProgressInfo getShardProgress() =>
      ShardProgressInfo(current: _shardCurrent, total: _shardTotal);

  // ---- Internal ---------------------------------------------------------

  static Sdk _requireSdk() {
    final sdk = _sdk;
    if (sdk == null) {
      throw StateError(
        'SDK not connected - call connect() or registerWithPhrase() first',
      );
    }
    return sdk;
  }

  static Future<Builder> _newBuilder() async {
    await init();
    final builder = await Sia.builder(
      indexerUrl: _indexerUrl,
      appMeta: _appMeta,
    );
    _pendingBuilder = builder;
    return builder;
  }

  static List<int> _hexToBytes(String hex) {
    final normalized = hex.trim();
    if (normalized.length % 2 != 0) {
      throw FormatException('hex string must have even length');
    }

    final out = <int>[];
    for (var i = 0; i < normalized.length; i += 2) {
      out.add(int.parse(normalized.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  static String _bytesToHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final byte in bytes) {
      sb.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

class ShardProgressInfo {
  final int current;
  final int total;

  const ShardProgressInfo({required this.current, required this.total});
}

class SiaObject {
  final String objectId;
  final Uint8List data;
  final String metadataJson;
  final int size;

  const SiaObject({
    required this.objectId,
    required this.data,
    required this.metadataJson,
    required this.size,
  });
}

class SiaObjectEvent {
  final String objectId;
  final bool deleted;
  final String? metadataJson;
  final String updatedAt;

  const SiaObjectEvent({
    required this.objectId,
    required this.deleted,
    required this.metadataJson,
    required this.updatedAt,
  });
}

class SyncResult {
  final List<SiaObjectEvent> events;
  final bool hasMore;

  const SyncResult({required this.events, required this.hasMore});
}

class UploadItem {
  final Uint8List data;
  final String metadataJson;

  const UploadItem({required this.data, required this.metadataJson});
}
