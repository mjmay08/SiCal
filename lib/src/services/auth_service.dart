import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../bridge/sia_bridge.dart';

const _keyAppKey = 'sia_app_key_hex';
const _keyIndexerUrl = 'sia_indexer_url';
const _defaultIndexerUrl = 'https://sia.storage';

// App ID: Generate ONCE and keep stable forever.
// Replace with a real 32-byte hex-encoded App ID before release.
const siaAppId =
    '0000000000000000000000000000000000000000000000000000000000000001';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

final authStateProvider = FutureProvider<bool>((ref) async {
  final auth = ref.read(authServiceProvider);
  return auth.tryReconnect();
});

class AuthService {
  final _storage = const FlutterSecureStorage();

  Future<bool> hasStoredAppKey() async {
    final key = await _storage.read(key: _keyAppKey);
    return key != null && key.isNotEmpty;
  }

  Future<String?> getAppKey() => _storage.read(key: _keyAppKey);

  Future<void> storeAppKey(String appKeyHex) =>
      _storage.write(key: _keyAppKey, value: appKeyHex);

  Future<String> getIndexerUrl() async {
    final url = await _storage.read(key: _keyIndexerUrl);
    return url ?? _defaultIndexerUrl;
  }

  Future<void> storeIndexerUrl(String url) =>
      _storage.write(key: _keyIndexerUrl, value: url);

  Future<void> clearAll() async {
    await _storage.delete(key: _keyAppKey);
    await _storage.delete(key: _keyIndexerUrl);
  }

  /// Attempt to silently reconnect using stored App Key.
  /// Returns true if successful.
  Future<bool> tryReconnect() async {
    final appKey = await getAppKey();
    if (appKey == null) return false;
    try {
      await SiaBridge.connect(appKey);
      return true;
    } catch (_) {
      return false;
    }
  }
}
