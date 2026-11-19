import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:classsweep/app/app_model.dart';
import 'package:classsweep/app/account_pages.dart';
import 'package:classsweep/app/classsweep_app.dart';
import 'package:classsweep/app/local_store.dart';
import 'package:classsweep/network/api_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryStore extends LocalStore {
  @override
  Future<String> serverUrl() async => LocalStore.defaultServer;
  @override
  Future<String> deviceId() async => 'synthetic-widget-device';
  @override
  Future<AuthSession?> session() async => null;
}

void main() {
  test('instructor session controls use the saved bearer credential', () async {
    final paths = <String>[];
    final body = {
      'title': 'Synthetic GPS session',
      'ttl_seconds': 300,
      'gps': {
        'enabled': true,
        'latitude': 35.7,
        'longitude': 51.4,
        'accuracy_m': 10.0,
        'captured_at': 1800000000.0,
        'radius_m': 100.0,
      },
    };
    final api = ClassSweepApi(
      'http://laptop.local:8000',
      token: 'synthetic-instructor-token',
      client: MockClient((request) async {
        paths.add(request.url.path);
        expect(
          request.headers['Authorization'],
          'Bearer synthetic-instructor-token',
        );
        if (request.url.path == '/admin/sessions' && request.method == 'POST') {
          expect(jsonDecode(request.body), body);
          return http.Response(
            '{"id":"session-1","code_a":"1234","code_b":"5678","gps":{"enabled":true}}',
            201,
          );
        }
        if (request.url.path == '/admin/sessions') {
          return http.Response(
            '[{"id":"session-1","gps":{"enabled":true}}]',
            200,
          );
        }
        expect(request.url.path, '/admin/sessions/session-1/gps/disable');
        expect(jsonDecode(request.body), <String, dynamic>{});
        return http.Response('{"id":"session-1","gps":{"enabled":false}}', 200);
      }),
    );
    expect((await api.createInstructorSession(body))['id'], 'session-1');
    expect((await api.instructorSessions()).length, 1);
    expect((await api.disableSessionGps('session-1'))['gps'], {
      'enabled': false,
    });
    expect(paths, [
      '/admin/sessions',
      '/admin/sessions',
      '/admin/sessions/session-1/gps/disable',
    ]);
    api.close();
  });

  test('student refreshes the live GPS policy with its bearer token', () async {
    final api = ClassSweepApi(
      'http://laptop.local:8000',
      token: 'synthetic-student-token',
      client: MockClient((request) async {
        expect(request.url.path, '/api/sessions/session-1');
        expect(
          request.headers['Authorization'],
          'Bearer synthetic-student-token',
        );
        return http.Response('{"id":"session-1","gps":{"enabled":false}}', 200);
      }),
    );
    expect((await api.session('session-1'))['gps'], {'enabled': false});
    api.close();
  });

  test('Wi-Fi is the fresh-install default and local hostnames are valid', () {
    expect(LocalStore.defaultServer, 'http://laptop.local:8000');
    expect(
      normalizeServerUrl(' http://laptop.local:8000/ '),
      LocalStore.defaultServer,
    );
  });

  test(
    'connection probe sends no credentials and checks server identity',
    () async {
      for (final body in [
        '{"status":"ok","service":"classsweep"}',
        '{"status":"ok"}',
        '<html>Another service</html>',
      ]) {
        final api = ClassSweepApi(
          'http://laptop.local:8000',
          token: 'must-not-be-sent',
          client: MockClient((request) async {
            expect(request.url.toString(), 'http://laptop.local:8000/health');
            expect(request.headers.containsKey('Authorization'), isFalse);
            return http.Response(body, 200);
          }),
        );
        if (body.contains('classsweep')) {
          await api.testConnection();
        } else {
          await expectLater(api.testConnection(), throwsA(isA<ApiFailure>()));
        }
        api.close();
      }
    },
  );

  testWidgets(
    'Wi-Fi settings explain hostname fallback and expose connection test',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(store: MemoryStore());
      await model.initialize();
      await tester.pumpWidget(MaterialApp(home: SettingsPage(model: model)));
      await tester.pumpAndSettle();
      expect(find.text('Connect over Wi-Fi'), findsOneWidget);
      expect(find.text('If the local name does not work'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'not a server address');
      final testButton = find.text('Test connection');
      await tester.scrollUntilVisible(
        testButton,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(testButton, findsOneWidget);
      await tester.ensureVisible(testButton);
      await tester.tap(testButton);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Use a server address such as'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  test(
    'server URL normalizes root and rejects embedded credentials or paths',
    () {
      expect(
        normalizeServerUrl(' http://127.0.0.1:8000/ '),
        'http://127.0.0.1:8000',
      );
      expect(
        normalizeServerUrl('https://class.example'),
        'https://class.example',
      );
      for (final invalid in [
        'localhost:8000',
        'file:///tmp/data',
        'http://u:p@host',
        'http://host/api',
        'http://host/?token=secret',
        'http://host/#x',
      ]) {
        expect(() => normalizeServerUrl(invalid), throwsFormatException);
      }
    },
  );

  test(
    'approved reference checks exact bytes, device and server hash',
    () async {
      final bytes = utf8.encode('synthetic-image-bytes-for-transport-test');
      final digest = sha256.convert(bytes).toString();
      for (final variation in ['valid', 'bytes', 'device', 'header']) {
        final api = ClassSweepApi(
          'http://localhost:8000',
          token: 'synthetic-token',
          client: MockClient((request) async {
            expect(request.headers['Authorization'], 'Bearer synthetic-token');
            return http.Response.bytes(
              variation == 'bytes' ? [0] : bytes,
              200,
              headers: {
                'x-device-id': variation == 'device'
                    ? 'wrong-device'
                    : 'test-device',
                'x-reference-sha256': variation == 'header' ? '0' * 64 : digest,
              },
            );
          }),
        );
        if (variation == 'valid') {
          expect(
            await api.approvedReference(
              expectedHash: digest,
              deviceId: 'test-device',
            ),
            bytes,
          );
        } else {
          await expectLater(
            api.approvedReference(
              expectedHash: digest,
              deviceId: 'test-device',
            ),
            throwsA(isA<ApiFailure>()),
          );
        }
        api.close();
      }
    },
  );

  test(
    'attendance transport sends only explicitly supplied JSON results',
    () async {
      final payload = {
        'attempt_id': 'synthetic-attempt',
        'checks': {'face_match': false},
      };
      final api = ClassSweepApi(
        'http://localhost:8000',
        token: 'synthetic-token',
        client: MockClient((request) async {
          expect(request.url.path, '/api/attendance');
          expect(jsonDecode(request.body), payload);
          expect(request.headers['content-type'], contains('application/json'));
          return http.Response('{"detail":"Checks failed"}', 403);
        }),
      );
      await expectLater(
        api.submit(payload),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
      );
      api.close();
    },
  );

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'sign-in and registration fit a $width pixel phone and validate input',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final model = AppModel(store: MemoryStore());
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: ClassSweepApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Student access'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('CAPTURE_PREVIEW') && width == 390) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('../outputs').create(recursive: true);
            await File('../outputs/login-preview.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        final button = find.widgetWithText(FilledButton, 'Sign in');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('Enter your password.'), findsOneWidget);
        final register = find.text('Create account');
        await tester.ensureVisible(register);
        await tester.tap(register);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextFormField, 'Full name'), findsOneWidget);
        final suggest = find.text('Suggest strong password');
        await tester.ensureVisible(suggest);
        await tester.tap(suggest);
        await tester.pumpAndSettle();
        final field = tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Password'),
        );
        expect(field.controller?.text.length, 20);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      },
    );
  }
}
