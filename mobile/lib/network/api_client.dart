import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class ApiFailure implements Exception {
  const ApiFailure(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

String normalizeServerUrl(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException(
      'Use a server address such as http://192.168.1.20:8000, without a path.',
    );
  }
  return uri.replace(path: '').toString();
}

class StudentAccount {
  StudentAccount(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get username => json['username'] as String;
  String get name => json['display_name'] as String;
  String get deviceId => json['device_id'] as String;
  String get status => json['enrollment_status'] as String;
  String? get referenceHash => json['reference_sha256'] as String?;
  bool get isInstructor => json['role'] == 'instructor';
  bool get approved => status == 'approved' && referenceHash != null;
}

class AuthSession {
  AuthSession({required this.token, required this.user});
  final String token;
  final StudentAccount user;
  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    token: json['token'] as String,
    user: StudentAccount(Map<String, dynamic>.from(json['user'] as Map)),
  );
  Map<String, dynamic> toJson() => {'token': token, 'user': user.json};
}

class ClassSweepApi {
  ClassSweepApi(String serverUrl, {http.Client? client, this.token})
    : baseUrl = normalizeServerUrl(serverUrl),
      _client = client ?? http.Client();
  final String baseUrl;
  final http.Client _client;
  String? token;
  static const timeout = Duration(seconds: 25);

  Uri _uri(String path) => Uri.parse('$baseUrl$path');
  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<http.Response> _send(
    http.BaseRequest request, {
    Duration requestTimeout = timeout,
    bool acceptSeeOther = false,
  }) async {
    try {
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(requestTimeout);
      if ((response.statusCode < 200 || response.statusCode >= 300) &&
          !(acceptSeeOther && response.statusCode == 303)) {
        var message = 'Server request failed (${response.statusCode}).';
        try {
          final data = jsonDecode(response.body);
          final detail = data is Map ? data['detail'] : null;
          if (detail is String) message = detail;
          if (detail is List) {
            message = detail.whereType<Map>().map((e) => e['msg']).join('; ');
          }
        } catch (_) {
          /* Non-JSON error responses must not expose HTML. */
        }
        if (response.statusCode == 401) message = 'Your sign-in expired or credentials were incorrect. Sign in again.';
        throw ApiFailure(message, status: response.statusCode);
      }
      return response;
    } on TimeoutException {
      throw const ApiFailure(
        'The server took too long. Check the address and connection, then retry.',
      );
    } on SocketException {
      throw const ApiFailure(
        'Cannot reach the laptop. Check that both devices use the same Wi-Fi and the server is running. If .local does not work, use the IP address printed by the server.',
      );
    } on http.ClientException {
      throw const ApiFailure(
        'Connection failed. Check Wi-Fi, the server address, and whether the server is running.',
      );
    }
  }

  /// Tests the selected address without sending account credentials or saving it.
  Future<void> testConnection() async {
    final request = http.Request('GET', _uri('/health'));
    request.headers['Accept'] = 'application/json';
    final response = await _send(
      request,
      requestTimeout: const Duration(seconds: 6),
    );
    try {
      final data = jsonDecode(response.body);
      if (data is Map &&
          data['status'] == 'ok' &&
          data['service'] == 'classsweep') {
        return;
      }
    } catch (_) {
      /* A reachable web page is not necessarily ClassSweep. */
    }
    throw const ApiFailure(
      'This address responded, but it is not a compatible ClassSweep server.',
    );
  }

  Future<dynamic> _json(
    String method,
    String path, [
    Map<String, dynamic>? body,
    Map<String, String>? extraHeaders,
  ]) async {
    final request = http.Request(method, _uri(path));
    request.headers.addAll({..._headers, ...?extraHeaders});
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _send(request);
    if (response.body.isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw const ApiFailure(
        'The server returned an unreadable response. Check the server version.',
      );
    }
  }

  Future<AuthSession> authenticate({
    required bool register,
    bool instructor = false,
    required String username,
    required String password,
    required String name,
    required String deviceId,
  }) async {
    final data = await _json(
      'POST',
      instructor
          ? '/api/instructor/login'
          : register
          ? '/api/register'
          : '/api/login',
      {
        'username': username,
        'password': password,
        if (register) 'display_name': name,
        'device_id': deviceId,
      },
    );
    final session = AuthSession.fromJson(
      Map<String, dynamic>.from(data as Map),
    );
    if (session.user.deviceId != deviceId) {
      throw const ApiFailure(
        'This account is bound to another device. Ask your instructor to reset the device binding.',
      );
    }
    token = session.token;
    return session;
  }

  Future<StudentAccount> me() async => StudentAccount(
    Map<String, dynamic>.from(await _json('GET', '/api/me') as Map),
  );
  Future<void> logout() async {
    await _json('POST', '/api/logout');
  }

  Future<void> uploadEnrollment(Uint8List jpeg, String deviceId) async {
    final request = http.MultipartRequest('POST', _uri('/api/enrollment'));
    request.headers.addAll(_headers);
    request.fields['device_id'] = deviceId;
    request.files.add(
      http.MultipartFile.fromBytes(
        'image',
        jpeg,
        filename: 'enrollment.jpg',
        contentType: http.MediaType('image', 'jpeg'),
      ),
    );
    await _send(request);
  }

  Future<void> templateReady(String deviceId, String hash) async {
    await _json('POST', '/api/enrollment/template-ready', {
      'device_id': deviceId,
      'reference_sha256': hash,
    });
  }

  Future<Uint8List> approvedReference({
    required String expectedHash,
    required String deviceId,
  }) async {
    final request = http.Request('GET', _uri('/api/enrollment/reference'));
    request.headers.addAll(_headers);
    final response = await _send(request);
    final bytes = response.bodyBytes;
    if (response.headers['x-device-id'] != deviceId ||
        response.headers['x-reference-sha256'] != expectedHash ||
        sha256.convert(bytes).toString() != expectedHash) {
      throw const ApiFailure(
        'The approved reference does not match this account or device. Refresh enrollment and retry.',
      );
    }
    return bytes;
  }

  Future<List<Map<String, dynamic>>> sessions() async =>
      _list(await _json('GET', '/api/sessions'));
  Future<List<Map<String, dynamic>>> attendance() async =>
      _list(await _json('GET', '/api/attendance'));
  Future<Map<String, dynamic>> session(String id) async =>
      Map<String, dynamic>.from(
        await _json('GET', '/api/sessions/${Uri.encodeComponent(id)}') as Map,
      );

  Future<Map<String, dynamic>> createInstructorSession(
    Map<String, dynamic> body,
  ) async => Map<String, dynamic>.from(
    await _json('POST', '/admin/sessions', body) as Map,
  );

  Future<List<Map<String, dynamic>>> instructorSessions() async =>
      _list(await _json('GET', '/admin/sessions'));

  Future<Map<String, dynamic>> disableSessionGps(String id) async =>
      Map<String, dynamic>.from(
        await _json(
          'POST',
          '/admin/sessions/${Uri.encodeComponent(id)}/gps/disable',
          {},
        ) as Map,
      );

  Future<void> closeInstructorSession(String id) async {
    final request = http.Request(
      'POST',
      _uri('/admin/sessions/${Uri.encodeComponent(id)}/close'),
    )..followRedirects = false;
    request.headers.addAll(_headers);
    // The existing close endpoint sends browsers back to the dashboard.
    await _send(request, acceptSeeOther: true);
  }

  List<Map<String, dynamic>> _list(dynamic data) =>
      (data as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  Future<Map<String, dynamic>> classroom(
    String referenceId,
  ) async => Map<String, dynamic>.from(
    await _json(
      'GET',
      '/api/classroom?reference_id=${Uri.encodeQueryComponent(referenceId)}',
    ) as Map,
  );
  Future<Map<String, dynamic>> beginAttempt(Map<String, dynamic> body) async =>
      Map<String, dynamic>.from(
        await _json('POST', '/api/attempts', body) as Map,
      );
  Future<Map<String, dynamic>> submit(Map<String, dynamic> body) async =>
      Map<String, dynamic>.from(
        await _json('POST', '/api/attendance', body) as Map,
      );

  Future<void> calibrate(Map<String, dynamic> scene) async {
    await _json('POST', '/api/admin/classroom', scene);
  }

  void close() => _client.close();
}
