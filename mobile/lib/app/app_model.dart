import 'package:flutter/foundation.dart';

import '../network/api_client.dart';
import 'local_store.dart';

class AppModel extends ChangeNotifier {
  AppModel({LocalStore? store}) : store = store ?? LocalStore();
  final LocalStore store;
  String serverUrl = LocalStore.defaultServer;
  String deviceId = '';
  ClassSweepApi? _api;
  ClassSweepApi get api => _api!;
  AuthSession? session;
  StudentAccount? get user => session?.user;
  List<Map<String, dynamic>> sessions = [], records = [];
  bool booting = true, refreshing = false;
  String? bootError, refreshError;
  String get faceScope =>
      '$serverUrl|${user!.id}|$deviceId|${user!.referenceHash}';

  Future<void> initialize() async {
    booting = true;
    bootError = null;
    notifyListeners();
    try {
      serverUrl = await store.serverUrl();
      deviceId = await store.deviceId();
      session = await store.session();
      _api?.close();
      _api = ClassSweepApi(serverUrl, token: session?.token);
      if (session != null) await refresh();
    } catch (error) {
      bootError = friendlyError(error);
    } finally {
      booting = false;
      notifyListeners();
    }
  }

  Future<void> authenticate({
    required bool register,
    required String username,
    required String password,
    required String name,
  }) async {
    final result = await api.authenticate(
      register: register,
      username: username,
      password: password,
      name: name,
      deviceId: deviceId,
    );
    await store.saveSession(result);
    session = result;
    sessions = [];
    records = [];
    refreshError = null;
    notifyListeners();
    await refresh();
  }

  Future<StudentAccount> verifyAccount() async {
    final account = await api.me();
    if (account.deviceId != deviceId) {
      throw const ApiFailure(
        'This account is bound to another phone. Ask your instructor for help.',
      );
    }
    session = AuthSession(token: session!.token, user: account);
    await store.saveSession(session!);
    notifyListeners();
    return account;
  }

  Future<void> refresh() async {
    if (refreshing || session == null) return;
    refreshing = true;
    refreshError = null;
    notifyListeners();
    try {
      await verifyAccount();
      final result = await Future.wait([api.sessions(), api.attendance()]);
      sessions = result[0];
      records = result[1];
    } catch (error) {
      refreshError = friendlyError(error);
      if (error is ApiFailure && error.status == 401) {
        await signOut(revoke: false);
      }
    } finally {
      refreshing = false;
      notifyListeners();
    }
  }

  Future<void> signOut({bool revoke = true}) async {
    if (revoke) {
      try {
        await api.logout();
      } catch (_) {}
    }
    await store.clearAccount();
    api.token = null;
    session = null;
    sessions = [];
    records = [];
    notifyListeners();
  }

  Future<void> changeServer(String value) async {
    final normalized = normalizeServerUrl(value);
    if (normalized == serverUrl) return;
    await store.setServerUrl(normalized);
    _api?.close();
    serverUrl = normalized;
    _api = ClassSweepApi(serverUrl);
    session = null;
    sessions = [];
    records = [];
    refreshError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _api?.close();
    super.dispose();
  }
}

String friendlyError(Object error) {
  if (error is ApiFailure) return error.message;
  if (error is FormatException) return error.message;
  return error
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('Bad state: ', '');
}
