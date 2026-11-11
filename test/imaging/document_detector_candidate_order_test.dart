import 'package:flutter_test/flutter_test.dart';
import 'package:scan_id/imaging/document_detector.dart';

/// Regression tests for candidate ordering in the classical detector.
///
/// The detector sorts candidates by descending total score and must keep
/// checking lower-scored candidates when the top-scored candidate fails the
/// edge-support gates, instead of rejecting the whole search. These tests
/// use synthetic candidates with fixed scores; they do not depend on
/// photographs, OCR, or image rendering.
class _Candidate {
  const _Candidate(this.id, this.total, this.mean, this.min, this.x);

  final String id;
  final double total;
  final double mean;
  final double min;

  /// Position marker: candidates sharing [x] count as duplicates.
  final double x;
}

/// The pre-fix selection, kept verbatim in behaviour so the regression test
/// below can prove it rejects a document the fixed code accepts.
List<T> _legacyShortlist<T>(
  List<T> ranked, {
  required double Function(T candidate) totalOf,
  required double Function(T candidate) meanOf,
  required double Function(T candidate) minOf,
  required bool Function(T a, T b) isDuplicate,
  required double needMean,
  required double needMin,
}) {
  if (ranked.isEmpty) {
    return [];
  }
  final best = ranked.first;
  if (meanOf(best) < needMean || minOf(best) < needMin) {
    return [];
  }
  final shortlist = <T>[];
  for (final candidate in ranked) {
    if (totalOf(candidate) < totalOf(best) - .05 || shortlist.length >= 12) {
      break;
    }
    if (meanOf(candidate) < needMean || minOf(candidate) < needMin) {
      continue;
    }
    if (shortlist.any((existing) => isDuplicate(existing, candidate))) {
      continue;
    }
    shortlist.add(candidate);
  }
  return shortlist;
}

List<_Candidate> _shortlist(
  List<_Candidate> ranked, {
  double needMean = .5,
  double needMin = .3,
  double window = .05,
  int maxCount = 12,
}) {
  return shortlistEdgeSupportedCandidates<_Candidate>(
    ranked,
    totalOf: (c) => c.total,
    meanOf: (c) => c.mean,
    minOf: (c) => c.min,
    isDuplicate: (a, b) => a.x == b.x,
    needMean: needMean,
    needMin: needMin,
    window: window,
    maxCount: maxCount,
  );
}

List<String> _legacy(List<_Candidate> ranked) {
  return _legacyShortlist<_Candidate>(
    ranked,
    totalOf: (c) => c.total,
    meanOf: (c) => c.mean,
    minOf: (c) => c.min,
    isDuplicate: (a, b) => a.x == b.x,
    needMean: .5,
    needMin: .3,
  );
}

List<String> _ids(List<_Candidate> candidates) => [
  for (final c in candidates) c.id,
];

void main() {
  test('falls back to a lower-scored candidate when the top candidate '
      'fails mean edge support', () {
    // The passing candidate sits more than the 0.05 window below the
    // failing top candidate. The old code returned null as soon as the
    // top candidate failed, and a window anchored to the failing top
    // candidate would discard this candidate as well.
    final ranked = [
      _Candidate('top', .9, .4, .6, 0),
      _Candidate('second', .8, .8, .6, 10),
    ];
    expect(_ids(_shortlist(ranked)), ['second']);
  });

  test('the pre-fix selection rejects this scene and the fixed selection '
      'accepts it, so the regression is discriminating', () {
    final ranked = [
      _Candidate('top', .9, .4, .6, 0),
      _Candidate('second', .8, .8, .6, 10),
    ];
    // Old behaviour: the failing top candidate returned null outright.
    expect(_legacy(ranked), isEmpty);
    // Fixed behaviour: the passing candidate below it is still considered.
    expect(_ids(_shortlist(ranked)), ['second']);
  });

  test('falls back to a lower-scored candidate when the top candidate '
      'fails minimum edge support', () {
    final ranked = [
      _Candidate('top', .9, .8, .2, 0),
      _Candidate('second', .88, .8, .6, 10),
    ];
    expect(_ids(_shortlist(ranked)), ['second']);
  });

  test('returns an empty shortlist when every candidate fails', () {
    final ranked = [
      _Candidate('a', .9, .4, .6, 0),
      _Candidate('b', .85, .8, .2, 10),
      _Candidate('c', .8, .4, .2, 20),
    ];
    expect(_shortlist(ranked), isEmpty);
    expect(_shortlist([]), isEmpty);
  });

  test('keeps the top candidate when it passes', () {
    final ranked = [
      _Candidate('top', .9, .8, .6, 0),
      _Candidate('second', .88, .8, .6, 10),
    ];
    expect(_ids(_shortlist(ranked)), ['top', 'second']);
  });

  test('skips a later failing candidate without ending the search', () {
    final ranked = [
      _Candidate('top', .9, .8, .6, 0),
      _Candidate('failing', .88, .4, .6, 10),
      _Candidate('third', .87, .8, .6, 20),
    ];
    expect(_ids(_shortlist(ranked)), ['top', 'third']);
  });

  test('rejects a candidate that passes mean support but fails minimum '
      'support and continues the search', () {
    final ranked = [
      _Candidate('weak-min', .9, .8, .2, 0),
      _Candidate('passing', .88, .8, .6, 10),
    ];
    expect(_ids(_shortlist(ranked)), ['passing']);
  });

  test('rejects a candidate that passes minimum support but fails mean '
      'support and continues the search', () {
    final ranked = [
      _Candidate('weak-mean', .9, .4, .6, 0),
      _Candidate('passing', .88, .8, .6, 10),
    ];
    expect(_ids(_shortlist(ranked)), ['passing']);
  });

  test('excludes a passing candidate outside the near-best window when '
      'the top candidate passes', () {
    final ranked = [
      _Candidate('top', .9, .8, .6, 0),
      _Candidate('far', .8, .8, .6, 10),
    ];
    expect(_ids(_shortlist(ranked)), ['top']);
  });

  test('anchors the window to the first passing candidate after a '
      'failing top candidate', () {
    final ranked = [
      _Candidate('top', .99, .4, .6, 0),
      _Candidate('second', .8, .8, .6, 10),
      _Candidate('third', .76, .8, .6, 20),
      _Candidate('fourth', .74, .8, .6, 30),
    ];
    expect(_ids(_shortlist(ranked)), ['second', 'third']);
  });

  test('a shrinking near-best window does not starve the fallback: the '
      'first passing candidate is always eligible', () {
    // The anchored window is tight, yet the first passing candidate must
    // still be considered; otherwise the fallback would depend on the gap
    // between the failing candidate and the passing one.
    final ranked = [
      _Candidate('top', .99, .4, .6, 0),
      _Candidate('second', .8, .8, .6, 10),
    ];
    expect(_ids(_shortlist(ranked, window: .001)), ['second']);
    expect(_ids(_shortlist(ranked, window: 0)), ['second']);
  });

  test('preserves ranked order for equal scores deterministically', () {
    final ranked = [
      _Candidate('first', .8, .8, .6, 0),
      _Candidate('second', .8, .8, .6, 10),
      _Candidate('third', .8, .8, .6, 20),
    ];
    expect(_ids(_shortlist(ranked)), ['first', 'second', 'third']);
    expect(
      _ids(_shortlist(ranked)),
      _ids(_shortlist(ranked)),
    );
  });

  test('suppresses near-duplicate candidates and keeps the first', () {
    final ranked = [
      _Candidate('top', .9, .8, .6, 0),
      _Candidate('duplicate', .88, .8, .6, 0),
      _Candidate('distinct', .87, .8, .6, 10),
    ];
    expect(_ids(_shortlist(ranked)), ['top', 'distinct']);
  });

  test('a failing candidate does not suppress a later passing candidate '
      'with the same position', () {
    final ranked = [
      _Candidate('top', .9, .4, .6, 0),
      _Candidate('passing', .88, .8, .6, 0),
      _Candidate('duplicate', .87, .8, .6, 0),
    ];
    expect(_ids(_shortlist(ranked)), ['passing']);
  });

  test('never returns a failing candidate just because it is the best '
      'available', () {
    final ranked = [_Candidate('only', .9, .4, .6, 0)];
    expect(_shortlist(ranked), isEmpty);
  });

  test('returns a single passing candidate', () {
    final ranked = [_Candidate('only', .9, .8, .6, 0)];
    expect(_ids(_shortlist(ranked)), ['only']);
  });

  test('caps the shortlist at twelve candidates', () {
    final ranked = [
      for (var i = 0; i < 15; i++)
        _Candidate('c$i', .9 - i * .001, .8, .6, i * 10.0),
    ];
    final shortlist = _shortlist(ranked);
    expect(shortlist, hasLength(12));
    expect(_ids(shortlist), [for (var i = 0; i < 12; i++) 'c$i']);
  });

  test('includes a candidate exactly at the window boundary', () {
    final ranked = [
      _Candidate('top', .75, .8, .6, 0),
      _Candidate('edge', .5, .8, .6, 10),
      _Candidate('outside', .49, .8, .6, 20),
    ];
    expect(
      _ids(_shortlist(ranked, window: .25)),
      ['top', 'edge'],
    );
  });
}
