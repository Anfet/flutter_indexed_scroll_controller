// Benchmark backing the ISC-12B storage decision: keep `Map<int, Size>` and
// a per-call `for` summation instead of moving to prefix sums or a Fenwick
// tree for this release.
//
// The question this measures is narrow: given the *same* number of entries
// already in `_sizes`, how expensive is the summation loop itself
// (`for (int i = 0; i < targetItemIndex; i++) priorItems += ...height`),
// compared to the cost that actually dominates a `scrollTo` call — the
// sequential measuring pass, which test/scroll_to_success_test.dart's
// "Long valid scroll pass" already shows takes on the order of 120 animation
// frames (roughly 2 seconds at 60fps) to reach index 250 on a 300-row list.
//
// This file intentionally does not touch IndexedScrollController or
// Flutter's widget/frame machinery: it isolates the arithmetic cost of the
// Map-based summation in plain Dart, which is the only variable ISC-12B is
// about. The frame-driven search cost is already established empirically by
// ISC-04/ISC-05's long-pass tests and is only restated here for comparison.
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';

/// Mirrors the summation loop in `_animateTo`/`scrollTo`
/// (indexed_scroll_controller.dart): sum the heights of every prior index
/// out of a `Map<int, Size>`, terminating at the first missing entry via
/// `_sizeOrThrow`.
double _sumPriorHeights(Map<int, Size> sizes, int targetItemIndex) {
  var priorItems = 0.0;
  for (int i = 0; i < targetItemIndex; i++) {
    final size = sizes[i];
    if (size == null) {
      throw StateError('Missing measurement for index $i');
    }
    priorItems += size.height;
  }
  return priorItems;
}

void main() {
  group('ISC-12B: Map<int, Size> summation cost', () {
    test('summing N=1000 entries takes microseconds, not milliseconds', () {
      final sizes = <int, Size>{
        for (int i = 0; i < 1000; i++) i: Size(100, 40.0 + (i % 10) * 4.0),
      };

      // Run the loop repeatedly and take the median wall-clock cost of a
      // single summation, to smooth out one-off JIT/GC noise.
      const runs = 200;
      final samples = <int>[];
      for (int r = 0; r < runs; r++) {
        final sw = Stopwatch()..start();
        final total = _sumPriorHeights(sizes, 1000);
        sw.stop();
        samples.add(sw.elapsedMicroseconds);
        expect(total, greaterThan(0));
      }
      samples.sort();
      final medianMicros = samples[samples.length ~/ 2];

      // Report the measured cost so it shows up in `flutter test` output.
      // ignore: avoid_print
      print(
        'N=1000 Map<int,Size> summation: median ${medianMicros}us '
        'over $runs runs (min ${samples.first}us, max ${samples.last}us)',
      );

      // A single scrollTo call performs this summation at most a handful of
      // times (once per animation step plus once at the end). Even a
      // generous 1ms budget per summation is far below a single 16ms frame.
      expect(
        medianMicros,
        lessThan(1000),
        reason: 'Summing 1000 Map entries should cost well under 1ms; if '
            'this regresses, the ISC-12B "negligible cost" premise no '
            'longer holds and the storage decision must be revisited.',
      );
    });

    test('summing N=5000 entries takes microseconds, not milliseconds', () {
      final sizes = <int, Size>{
        for (int i = 0; i < 5000; i++) i: Size(100, 40.0 + (i % 10) * 4.0),
      };

      const runs = 200;
      final samples = <int>[];
      for (int r = 0; r < runs; r++) {
        final sw = Stopwatch()..start();
        final total = _sumPriorHeights(sizes, 5000);
        sw.stop();
        samples.add(sw.elapsedMicroseconds);
        expect(total, greaterThan(0));
      }
      samples.sort();
      final medianMicros = samples[samples.length ~/ 2];

      // ignore: avoid_print
      print(
        'N=5000 Map<int,Size> summation: median ${medianMicros}us '
        'over $runs runs (min ${samples.first}us, max ${samples.last}us)',
      );

      expect(
        medianMicros,
        lessThan(2000),
        reason: 'Summing 5000 Map entries should cost a few ms at most; if '
            'this regresses, the ISC-12B "negligible cost" premise no '
            'longer holds and the storage decision must be revisited.',
      );
    });

    test(
        'summation cost at N=5000 is orders of magnitude below one animation '
        'frame budget (16.6ms), let alone a ~120-frame search pass', () {
      final sizes = <int, Size>{
        for (int i = 0; i < 5000; i++) i: Size(100, 40.0 + (i % 10) * 4.0),
      };

      const runs = 50;
      var totalMicros = 0;
      for (int r = 0; r < runs; r++) {
        final sw = Stopwatch()..start();
        _sumPriorHeights(sizes, 5000);
        sw.stop();
        totalMicros += sw.elapsedMicroseconds;
      }
      final avgMicros = totalMicros / runs;
      const frameBudgetMicros = 16667; // 60fps frame, in microseconds.
      // ISC-04's QA scenario: scrollTo(250) on 300 rows took ~120 frames.
      const observedLongPassFrames = 120;
      const observedLongPassMicros = frameBudgetMicros * observedLongPassFrames;

      // ignore: avoid_print
      print(
        'N=5000 summation avg: ${avgMicros}us vs one frame budget '
        '(${frameBudgetMicros}us) vs observed ~120-frame long pass '
        '(${observedLongPassMicros}us)',
      );

      expect(
        avgMicros,
        lessThan(frameBudgetMicros),
        reason: 'The summation itself must fit comfortably inside a single '
            'animation frame; it is not the cost driver of a scrollTo call.',
      );
      expect(
        avgMicros / observedLongPassMicros,
        lessThan(0.001),
        reason: 'Summation cost must be negligible (<0.1%) relative to the '
            'empirically observed ~120-frame sequential search pass from '
            'ISC-04; this is the quantitative basis for the ISC-12B '
            'decision to keep Map<int, Size> instead of adding prefix '
            'sums/Fenwick tree.',
      );
    });
  });
}
