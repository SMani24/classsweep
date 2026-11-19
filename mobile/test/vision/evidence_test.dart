import 'package:flutter_test/flutter_test.dart';
import 'package:classsweep/vision/evidence.dart';
import 'package:classsweep/vision/references.dart';

void main() {
  final epoch = DateTime.utc(2026);
  test(
    'OCR boundaries, repeated text and leading zeroes vote once per frame',
    () {
      final v = CodeVoter();
      expect(v.add('0123 0123 99999 ۱۲۳۴', epoch), isEmpty);
      expect(
        v.add('0123 4567', epoch.add(const Duration(milliseconds: 100))),
        isEmpty,
      );
      expect(v.add('0123 4567', epoch.add(const Duration(milliseconds: 200))), [
        '0123',
      ]);
      expect(v.add('4567', epoch.add(const Duration(milliseconds: 300))), [
        '0123',
        '4567',
      ]);
      expect(v.add('', epoch.add(const Duration(seconds: 4))), isEmpty);
    },
  );
  test('repeated/out-of-order timestamps cannot manufacture OCR votes', () {
    final v = CodeVoter();
    for (var i = 0; i < 10; i++) {
      expect(v.add('1234', epoch), isEmpty);
    }
    expect(v.add('1234', epoch.subtract(const Duration(seconds: 1))), isEmpty);
  });
  test(
    'median rejects isolated extreme flow and Pearson has signed output',
    () {
      expect(median([1, 1.1, .9, 100]), closeTo(1.05, .0001));
      expect(correlation([1, 2, 3], [-1, -2, -3]), closeTo(-1, 1e-6));
      expect(correlation([1, 1, 1], [2, 2, 2]), 0);
    },
  );
  test('sweep needs directed motion, stationary pause and reversal', () {
    final s = SweepChallenge(direction: 'left');
    var t = 0;
    void sample(double f, double? g, {bool valid = true}) {
      s.add(
        MotionSample(
          timestamp: epoch.add(Duration(milliseconds: t)),
          flowX: f,
          flowY: 0,
          tracks: 30,
          gyroYaw: g,
          valid: valid,
        ),
      );
      t += 100;
    }

    for (var i = 0; i < 9; i++) {
      sample(-.08, -.2);
    }
    expect(s.progress.phase, SweepPhase.first);
    for (var i = 0; i < 9; i++) {
      sample(.08, .2);
    }
    expect(s.progress.phase, SweepPhase.pause);
    for (var i = 0; i < 7; i++) {
      sample(0, 0);
    }
    expect(s.progress.phase, SweepPhase.reverse);
    for (var i = 0; i < 9; i++) {
      sample(-.08, -.2);
    }
    expect(s.progress.passed, isTrue);
    expect(s.progress.correlation, greaterThan(.99));
  });
  test(
    'missing gyro, scene motion without device motion and timeout fail closed',
    () {
      for (final gyro in <double?>[null, 0, -.2]) {
        final s = SweepChallenge(direction: 'left');
        for (var i = 0; i < 30; i++) {
          s.add(
            MotionSample(
              timestamp: epoch.add(Duration(milliseconds: i * 100)),
              flowX: .1,
              flowY: 0,
              tracks: 40,
              gyroYaw: gyro,
              valid: true,
            ),
          );
        }
        expect(s.progress.passed, isFalse);
        s.add(
          MotionSample(
            timestamp: epoch.add(const Duration(seconds: 46)),
            flowX: 0,
            flowY: 0,
            tracks: 0,
            gyroYaw: null,
            valid: false,
          ),
        );
        expect(s.progress.phase, SweepPhase.failed);
      }
    },
  );
  test('board codes are captured separately, with the second code gated by the sweep', () {
    final scan = BoardCodeScan();
    scan.observe(visible: ['0123'], stable: ['0123'], seekingSecond: false);
    scan.observe(
      visible: ['4567'],
      stable: ['0123', '4567'],
      seekingSecond: false,
    );
    expect(scan.first, '0123');
    expect(scan.second, isNull);
    scan.observe(
      visible: ['0123'],
      stable: ['0123', '4567'],
      seekingSecond: true,
    );
    expect(scan.second, isNull);
    scan.observe(
      visible: ['4567'],
      stable: ['0123', '4567'],
      seekingSecond: true,
    );
    expect(scan.second, '4567');
  });

  test('head challenge checks server direction, dwell, identity continuity and return', () {
    final h = HeadChallenge(direction: 'left');
    var t = 0;
    void head(double? yaw, {bool identity = true, int count = 1}) {
      h.add(
        at: epoch.add(Duration(milliseconds: t)),
        yaw: yaw,
        identityMatches: identity,
        faceCount: count,
      );
      t += 100;
    }

    for (var i = 0; i < 5; i++) {
      head(0);
    }
    expect(h.progress.phase, HeadPhase.turn);
    for (var i = 0; i < 5; i++) {
      head(-22);
    }
    expect(h.progress.phase, HeadPhase.turn);
    for (var i = 0; i < 5; i++) {
      head(22);
    }
    expect(h.progress.phase, HeadPhase.returnCenter);
    head(0, identity: false);
    expect(h.progress.phase, HeadPhase.center);
    for (var i = 0; i < 5; i++) {
      head(0);
    }
    for (var i = 0; i < 5; i++) {
      head(22);
    }
    for (var i = 0; i < 5; i++) {
      head(0);
    }
    expect(h.progress.passed, isTrue);
  });
  test(
    'missing reference never passes; ORB reference wire format round trips',
    () {
      expect(
        const SceneMatch(
          hasReference: false,
          matches: 100,
          inliers: 100,
        ).passed,
        isFalse,
      );
      final ref = SceneReference(
        width: 100,
        height: 100,
        keypoints: List.generate(16, (i) => [i.toDouble(), i.toDouble()]),
        descriptors: List.generate(16, (_) => List.filled(32, 7)),
      );
      final copy = SceneReference.fromBytes(ref.toBytes());
      expect(copy.toJson(), ref.toJson());
      expect(ref.toJson().keys.toSet(), {
        'id',
        'width',
        'height',
        'keypoints',
        'descriptors',
      });
      expect(() => FaceReference(List.filled(128, 0)), throwsFormatException);
      expect(
        () =>
            SceneReference(width: 1, height: 1, keypoints: [], descriptors: []),
        throwsFormatException,
      );
    },
  );
}
