import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:classsweep/app/app_model.dart';
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
        expect(find.text('Be here.\nCheck in securely.'), findsOneWidget);
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
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      },
    );
  }
}
