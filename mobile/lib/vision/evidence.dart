import 'dart:math';

/// One vote per frame per code. Empty frames still age older observations.
class CodeVoter {
  CodeVoter({
    this.window = const Duration(seconds: 3),
    this.minimumVotes = 3,
    this.codeLength = 4,
  });
  final Duration window;
  final int minimumVotes;
  final int codeLength;
  final List<(DateTime, Set<String>)> _frames = [];
  List<String> add(String text, DateTime at) {
    final codes = RegExp('(?<![0-9])[0-9]{$codeLength}(?![0-9])')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .toSet();
    if (_frames.isNotEmpty && !at.isAfter(_frames.last.$1)) return stable(at);
    _frames.add((at, codes));
    return stable(at);
  }

  List<String> stable(DateTime at) {
    _frames.removeWhere((f) => at.difference(f.$1) > window);
    final counts = <String, int>{};
    for (final f in _frames) {
      for (final c in f.$2) {
        counts[c] = (counts[c] ?? 0) + 1;
      }
    }
    return counts.entries
        .where((e) => e.value >= minimumVotes)
        .map((e) => e.key)
        .toList()
      ..sort();
  }

  void reset() => _frames.clear();
}

double median(List<double> values) {
  if (values.isEmpty) return double.nan;
  final s = [...values]..sort();
  return s.length.isOdd
      ? s[s.length ~/ 2]
      : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

double correlation(List<double> x, List<double> y) {
  if (x.length != y.length || x.length < 3) return 0;
  final mx = x.reduce((a, b) => a + b) / x.length;
  final my = y.reduce((a, b) => a + b) / y.length;
  double a = 0, b = 0, c = 0;
  for (var i = 0; i < x.length; i++) {
    a += (x[i] - mx) * (y[i] - my);
    b += pow(x[i] - mx, 2);
    c += pow(y[i] - my, 2);
  }
  return b * c <= 1e-12 ? 0 : a / sqrt(b * c);
}

class MotionSample {
  const MotionSample({
    required this.timestamp,
    required this.flowX,
    required this.flowY,
    required this.tracks,
    required this.gyroYaw,
    required this.valid,
  });
  final DateTime timestamp;

  /// Normalized image displacement per second, opposite camera yaw.
  final double flowX, flowY;
  final int tracks;

  /// Screen-up angular velocity in rad/s; null means sensor unavailable/stale.
  final double? gyroYaw;
  final bool valid;
}

enum SweepPhase { first, pause, reverse, complete, failed }

class SweepProgress {
  const SweepProgress(
    this.phase,
    this.direction,
    this.correlation,
    this.samples,
  );
  final SweepPhase phase;
  final String direction;
  final double correlation;
  final int samples;
  bool get passed => phase == SweepPhase.complete;
  String get instruction => switch (phase) {
    SweepPhase.first => 'Pan $direction',
    SweepPhase.pause => 'Hold still',
    SweepPhase.reverse => 'Pan ${direction == 'left' ? 'right' : 'left'}',
    SweepPhase.complete => 'Sweep complete',
    SweepPhase.failed => 'Restart sweep',
  };
}

/// Experimental: requires sustained pan, pause, opposite pan and signed correlation.
class SweepChallenge {
  SweepChallenge({String? direction})
    : direction = direction ?? (Random.secure().nextBool() ? 'left' : 'right') {
    if (this.direction != 'left' && this.direction != 'right') {
      throw ArgumentError('direction must be left/right');
    }
  }
  final String direction;
  SweepPhase _phase = SweepPhase.first;
  DateTime? _start, _last, _held;
  final List<double> _flow = [], _gyro = [];
  SweepProgress get progress =>
      SweepProgress(_phase, direction, correlation(_flow, _gyro), _flow.length);
  SweepProgress add(MotionSample s) {
    if (_phase == SweepPhase.complete || _phase == SweepPhase.failed) {
      return progress;
    }
    _start ??= s.timestamp;
    if (s.timestamp.difference(_start!) > const Duration(seconds: 20)) {
      _phase = SweepPhase.failed;
    }
    final gap = _last == null
        ? 0
        : s.timestamp.difference(_last!).inMilliseconds;
    if (gap <= 0 && _last != null) return progress;
    _last = s.timestamp;
    if (gap > 600 && _phase != SweepPhase.failed) _phase = SweepPhase.first;
    if (!s.valid || s.gyroYaw == null || !s.gyroYaw!.isFinite || gap > 600) {
      _held = null;
      return progress;
    }
    // Positive gyro about upright screen y pans camera left; scene flows right.
    final signedFlow = s.flowX;
    final gyro = s.gyroYaw!;
    _flow.add(signedFlow);
    _gyro.add(gyro);
    final sign = direction == 'left' ? 1 : -1;
    final moving =
        signedFlow.abs() > .025 && gyro.abs() > .06 && signedFlow * gyro > 0;
    final expected = _phase == SweepPhase.reverse ? -sign : sign;
    final ok = _phase == SweepPhase.pause
        ? signedFlow.abs() < .012 && s.flowY.abs() < .012 && gyro.abs() < .04
        : moving && signedFlow * expected > 0;
    if (!ok) {
      _held = null;
      return progress;
    }
    _held ??= s.timestamp;
    final needed = _phase == SweepPhase.pause ? 500 : 700;
    if (s.timestamp.difference(_held!).inMilliseconds >= needed) {
      _held = null;
      if (_phase == SweepPhase.first) {
        _phase = SweepPhase.pause;
      } else if (_phase == SweepPhase.pause) {
        _phase = SweepPhase.reverse;
      } else if (_phase == SweepPhase.reverse &&
          _flow.length >= 12 &&
          correlation(_flow, _gyro) >= .65) {
        _phase = SweepPhase.complete;
      }
    }
    return progress;
  }
}

enum HeadPhase { center, turn, returnCenter, complete, failed }

class LivenessProgress {
  const LivenessProgress(this.phase, this.direction);
  final HeadPhase phase;
  final String direction;
  bool get passed => phase == HeadPhase.complete;
}

class HeadChallenge {
  HeadChallenge({String? direction})
    : direction = direction ?? (Random.secure().nextBool() ? 'left' : 'right') {
    if (this.direction != 'left' && this.direction != 'right') {
      throw ArgumentError('direction must be left/right');
    }
  }
  final String direction;
  HeadPhase _phase = HeadPhase.center;
  DateTime? _start, _held, _last;
  LivenessProgress get progress => LivenessProgress(_phase, direction);
  LivenessProgress add({
    required DateTime at,
    required double? yaw,
    required bool identityMatches,
    required int faceCount,
  }) {
    if (_phase == HeadPhase.failed || _phase == HeadPhase.complete) {
      return progress;
    }
    _start ??= at;
    if (at.difference(_start!) > const Duration(seconds: 15)) {
      _phase = HeadPhase.failed;
    }
    if (_last != null && !at.isAfter(_last!)) return progress;
    if (_last != null && at.difference(_last!).inMilliseconds > 700) {
      _held = null;
      if (_phase != HeadPhase.failed) _phase = HeadPhase.center;
    }
    _last = at;
    if (faceCount != 1 || !identityMatches || yaw == null || !yaw.isFinite) {
      // Identity loss invalidates prior steps to prevent stitching different people.
      _held = null;
      if (_phase != HeadPhase.failed) _phase = HeadPhase.center;
      return progress;
    }
    // ML Kit: positive yaw is face turning toward image right (subject left).
    final ok = _phase == HeadPhase.turn
        ? yaw * (direction == 'left' ? 1 : -1) >= 18
        : yaw.abs() <= 8;
    if (!ok) {
      _held = null;
      return progress;
    }
    _held ??= at;
    if (at.difference(_held!).inMilliseconds >= 300) {
      _held = null;
      _phase = switch (_phase) {
        HeadPhase.center => HeadPhase.turn,
        HeadPhase.turn => HeadPhase.returnCenter,
        HeadPhase.returnCenter => HeadPhase.complete,
        _ => _phase,
      };
    }
    return progress;
  }
}
