import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../network/api_client.dart';

/// All identity and biometric metadata is private to this Android installation.
class LocalStore {
  LocalStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const defaultServer = 'http://laptop.local:8000';
  Future<String> deviceId() async {
    final old = await _storage.read(key: 'device_id');
    if (old != null && old.isNotEmpty) return old;
    final random = Random.secure();
    final id = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _storage.write(key: 'device_id', value: id);
    return id;
  }

  Future<String> serverUrl() async =>
      await _storage.read(key: 'server_url') ?? defaultServer;
  Future<void> setServerUrl(String value) async {
    await clearAccount();
    await _storage.write(key: 'server_url', value: normalizeServerUrl(value));
  }

  Future<AuthSession?> session() async {
    final value = await _storage.read(key: 'session');
    if (value == null) return null;
    try {
      return AuthSession.fromJson(jsonDecode(value) as Map<String, dynamic>);
    } catch (_) {
      await clearAccount();
      return null;
    }
  }

  Future<void> saveSession(AuthSession value) =>
      _storage.write(key: 'session', value: jsonEncode(value.toJson()));
  Future<void> saveFace({
    required String scope,
    required Map<String, dynamic> face,
  }) => _storage.write(
    key: _faceKey(scope),
    value: jsonEncode({'scope': scope, 'face': face}),
  );
  Future<Map<String, dynamic>?> loadFace(String scope) async {
    final value = await _storage.read(key: _faceKey(scope));
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value) as Map<String, dynamic>;
      if (decoded['scope'] != scope) {
        await clearFace(scope);
        return null;
      }
      return Map<String, dynamic>.from(decoded['face'] as Map);
    } catch (_) {
      await clearFace(scope);
      return null;
    }
  }

  String _faceKey(String scope) => 'face_${sha256.convert(utf8.encode(scope))}';
  Future<void> clearFace(String scope) => _storage.delete(key: _faceKey(scope));
  Future<void> clearAccount() async {
    await _storage.delete(key: 'session');
  }
}
