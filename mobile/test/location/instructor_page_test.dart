import 'package:classsweep/app/app_model.dart';
import 'package:classsweep/app/instructor_page.dart';
import 'package:classsweep/location/location.dart';
import 'package:classsweep/network/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const epoch = 1800000000.0;

class PageProvider implements LocationProvider {
  int calls = 0;
  Object? error;
  @override
  Future<LocationSample> currentPosition() async {
    calls++;
    if (error != null) throw error!;
    return LocationSample(
      latitude: calls.toDouble(),
      longitude: 2,
      accuracyM: 5,
      capturedAt: epoch,
    );
  }
}

class PageApi extends ClassSweepApi {
  PageApi() : super('http://localhost:8000');
  Map<String, dynamic>? body;
  String? password, disabledId;
  List<Map<String, dynamic>> active = [];
  int creates = 0;
  @override
  Future<Map<String, dynamic>> createInstructorSession(
    String password,
    Map<String, dynamic> body,
  ) async {
    creates++;
    this.password = password;
    this.body = body;
    final session = <String, dynamic>{
      ...body,
      'id': 'session-1',
      'code_a': '1234',
      'code_b': '5678',
      'expires_at': 4102444800,
    };
    active = [session];
    return session;
  }

  @override
  Future<List<Map<String, dynamic>>> instructorSessions(String password) async {
    this.password = password;
    return active;
  }

  @override
  Future<Map<String, dynamic>> disableSessionGps(
    String password,
    String id,
  ) async {
    this.password = password;
    disabledId = id;
    return {
      'id': id,
      'gps': {'enabled': false},
    };
  }
}

class PageModel extends AppModel {
  PageModel(this.fakeApi);
  final PageApi fakeApi;
  @override
  ClassSweepApi get api => fakeApi;
  @override
  void dispose() {
    fakeApi.close();
    super.dispose();
  }
}

Finder field(String label) => find.widgetWithText(TextFormField, label);

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    return;
  }
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(0);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    finder,
    150,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 40,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  final finder = text == 'Create attendance'
      ? find.widgetWithText(FilledButton, text)
      : find.text(text);
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late PageApi api;
  late PageModel model;
  late PageProvider provider;
  setUp(() {
    api = PageApi();
    model = PageModel(api);
    provider = PageProvider();
  });
  tearDown(() => model.dispose());

  Future<void> open(WidgetTester tester, {bool narrow = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(narrow ? 320 : 600, narrow ? 640 : 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(narrow ? 1.3 : 1)),
          child: child!,
        ),
        home: InstructorPage(
          model: model,
          verifier: LocationVerifier(
            provider: provider,
            now: () => DateTime.fromMillisecondsSinceEpoch(
              (epoch * 1000).toInt(),
              isUtc: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester) async {
    await reveal(tester, field('Instructor password'));
    await tester.enterText(field('Instructor password'), 'instructor-secret');
    await reveal(tester, field('Session title'));
    await tester.enterText(field('Session title'), 'Test lecture');
    tester.testTextInput.hide();
  }

  testWidgets('logged-out creation defaults GPS off and never samples', (
    tester,
  ) async {
    await open(tester);
    expect(model.session, isNull);
    expect(provider.calls, 0);
    await fill(tester);
    await tapText(tester, 'Create attendance');
    expect(api.creates, 1);
    expect(api.body, {
      'title': 'Test lecture',
      'ttl_seconds': 300,
      'gps': {'enabled': false},
    });
    expect(provider.calls, 0);
    await reveal(tester, find.text('Code A: 1234'));
    expect(find.text('Code A: 1234'), findsOneWidget);
    expect(find.text('Code B: 5678'), findsOneWidget);
    expect(api.password, 'instructor-secret');
    // The password remains in the page for admin management after creation.
    await reveal(tester, field('Instructor password'));
    expect(
      tester
          .widget<TextFormField>(field('Instructor password'))
          .controller!
          .text,
      'instructor-secret',
    );
  });

  testWidgets(
    'narrow screen toggles GPS without sampling, previews, changes radius, creates fresh and disables',
    (tester) async {
      await open(tester, narrow: true);
      await fill(tester);
      await tapText(tester, 'Require GPS for this session');
      expect(provider.calls, 0);
      await reveal(tester, find.byType(Slider));
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, 25);
      expect(slider.max, 1000);
      expect(slider.value, 100);
      await tapText(tester, 'Use current location for GPS');
      expect(provider.calls, 1);
      await reveal(tester, find.textContaining('Preview accuracy:'));
      expect(find.textContaining('Preview accuracy:'), findsOneWidget);
      // A changed radius invalidates the preview without requesting another fix.
      await reveal(tester, find.byType(Slider));
      await tester.drag(find.byType(Slider), const Offset(50, 0));
      await tester.pumpAndSettle();
      expect(find.textContaining('Preview accuracy:'), findsNothing);
      expect(provider.calls, 1);
      await tapText(tester, 'Create attendance');
      expect(provider.calls, 2);
      expect(api.body!['gps']['latitude'], 2); // Creation used the new fix.
      await reveal(tester, find.text('Code A: 1234'));
      expect(find.text('Code A: 1234'), findsOneWidget);
      await tapText(tester, 'Disable GPS now');
      expect(api.disabledId, 'session-1');
      expect(api.password, 'instructor-secret');
      expect(find.text('GPS off · no location required'), findsOneWidget);
      expect(provider.calls, 2);
      expect(tester.takeException(), isNull); // Includes overflow exceptions.
    },
  );

  testWidgets(
    'capture failure explains problem and does not create a session',
    (tester) async {
      await open(tester);
      await fill(tester);
      await tapText(tester, 'Require GPS for this session');
      provider.error = const GpsFailure(
        'services_disabled',
        'Turn on Location and retry.',
      );
      await tapText(tester, 'Create attendance');
      expect(api.creates, 0);
      expect(provider.calls, 1);
      await reveal(tester, find.text('Turn on Location and retry.'));
      expect(find.text('Turn on Location and retry.'), findsOneWidget);
    },
  );

  testWidgets(
    'disabling GPS clears preview and subsequent creation never samples',
    (tester) async {
      await open(tester);
      await fill(tester);
      await tapText(tester, 'Require GPS for this session');
      await tapText(tester, 'Use current location for GPS');
      expect(provider.calls, 1);
      await reveal(tester, find.textContaining('Preview accuracy:'));
      await reveal(tester, find.text('Require GPS for this session'));
      await tester.tap(find.text('Require GPS for this session'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Preview accuracy:'), findsNothing);
      await tapText(tester, 'Create attendance');
      expect(api.body!['gps'], {'enabled': false});
      expect(provider.calls, 1);
    },
  );

  testWidgets('refresh merges external GPS disable into single created card', (
    tester,
  ) async {
    await open(tester);
    await fill(tester);
    await tapText(tester, 'Require GPS for this session');
    await tapText(tester, 'Create attendance');
    api.active = [
      {
        ...api.active.single,
        'gps': {'enabled': false},
      },
    ];
    await tapText(tester, 'Load active sessions');
    await reveal(tester, find.text('Code A: 1234'));
    expect(find.text('Code A: 1234'), findsOneWidget);
    expect(find.text('GPS off · no location required'), findsOneWidget);
    expect(find.text('Disable GPS now'), findsNothing);
  });
}
