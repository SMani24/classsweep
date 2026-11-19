import 'package:flutter/foundation.dart';

import '../vision/vision.dart';

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
  String faceScopeFor(String hash) => '$serverUrl|${user!.id}|$deviceId|$hash';

  FaceReference? faceReference;
  bool preparingFace = false;
  String? facePreparationError;
  Future<void>? _faceTask;
  String? _faceKey;
  int _identityVersion = 0;

  void _resetFace() {
    _identityVersion++;
    _faceKey = null;
    faceReference = null;
    facePreparationError = null;
    preparingFace = false;
    _faceTask = null;
  }

  Future<void> ensureFace() {
    final hash = user?.referenceHash;
    if (user?.approved != true || hash == null) return Future.value();
    final scope = faceScopeFor(hash);
    if (_faceKey == scope && _faceTask != null) return _faceTask!;
    if (_faceKey == scope && faceReference != null) return Future.value();
    _resetFace();
    _faceKey = scope;
    final version = _identityVersion;
    final client = api;
    final device = deviceId;
    preparingFace = true;
    _faceTask = _prepareFace(scope, hash, client, device, version);
    notifyListeners();
    return _faceTask!;
  }

  Future<void> _prepareFace(
    String scope,
    String hash,
    ClassSweepApi client,
    String device,
    int version,
  ) async {
    ClassSweepVision? vision;
    bool current() => version == _identityVersion && _faceKey == scope;
    try {
      final saved = await store.loadFace(scope);
      if (!current()) return;
      FaceReference reference;
      if (saved != null) {
        reference = FaceReference.fromJson(saved);
      } else {
        final image = await client.approvedReference(
          expectedHash: hash,
          deviceId: device,
        );
        if (!current()) return;
        vision = ClassSweepVision();
        await vision.start();
        reference = await vision.enrollFace(image);
        final profiles = await store.loadEnrollmentAngles(scope);
        if (!current()) return;
        if (profiles != null) {
          try {
            final angled = FaceReference.fromJson(profiles);
            reference = reference.withProfiles(
              angled.profiles
                  .where(
                    (profile) =>
                        vision!.compareFaces(reference, profile) >=
                        vision.faceCosineThreshold,
                  )
                  .toList(),
            );
          } on FormatException {
            // The approved frontal reference is still usable.
          } on TypeError {
            // An unreadable optional reference is discarded.
          }
        }
        await store.saveFace(scope: scope, face: reference.toJson());
        await store.clearEnrollmentAngles(scope);
      }
      if (!current()) return;
      await client.templateReady(device, hash);
      if (current()) faceReference = reference;
    } catch (error) {
      if (current()) facePreparationError = friendlyError(error);
    } finally {
      try {
        await vision?.dispose();
      } finally {
        if (current()) {
          _faceTask = null;
          preparingFace = false;
          notifyListeners();
        }
      }
    }
  }

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
    bool instructor = false,
    required String username,
    required String password,
    required String name,
  }) async {
    final result = await api.authenticate(
      register: register,
      instructor: instructor,
      username: username,
      password: password,
      name: name,
      deviceId: deviceId,
    );
    await store.saveSession(result);
    _resetFace();
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
      final account = await verifyAccount();
      if (account.isInstructor) return;
      if (account.approved) {
        // The dashboard stays usable while the reference prepares.
        ensureFace();
      } else if (_faceKey != null) {
        _resetFace();
      }
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
    _resetFace();
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
    _resetFace();
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
    _resetFace();
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
