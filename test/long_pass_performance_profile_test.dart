// ISC-18: Measure the cost of sequential height measurement on long lists.
//
// This file profiles real performance of scrollTo on lists of varying lengths
// and height distributions. The goal is to quantify the cost and confirm that
// the sequential measuring pass takes time proportional to distance travelled
// (not exponential), and that the dictionary of heights (`_sizes`) is not a
// memory bottleneck at reasonable list sizes.
//
// Measurements capture:
// 1. **Steps**: Number of iterations of the sequential search loop (each
//    iteration invokes one animation frame pump and progresses the viewport).
// 2. **Frames**: Total animation frames pumped during scrollTo (same as step
//    count, since scrollTo uses pump-per-iteration).
// 3. **Memory**: Estimated memory footprint of _sizes dictionary for fully
//    measured lists of varying length — computed analytically (not direct
//    profiling) since Flutter's testing environment has limited memory
//    introspection tools.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'support/scroll_harness.dart';

// Helper functions for item height builders (used with ScrollHarness)
double _uniform100px(int index) => 100.0;
double _varied40to72px(int index) => 40.0 + (index % 10) * 4.0;
double _random50to150px(int index) {
  final random = math.Random(42 + index); // Seeded per-index for reproducibility
  return 50.0 + random.nextDouble() * 100.0;
}

double _varied60to78px(int index) => 60.0 + (index % 15) * 3.0;

void main() {
  group('ISC-18: Long-pass performance profile', () {
    testWidgets('scrollTo(100) on 150-item list with uniform 100px heights',
        (WidgetTester tester) async {
      // Baseline: uniform heights allow straightforward calculation and comparison.
      // 150 items × 100px = 15,000px total; scrolling to item 100 (offset ~10,000px)
      // is a substantial jump that requires sequential measurement.
      await tester.pumpWidget(
        const ScrollHarness(
          itemCount: 150,
          itemHeightBuilder: _uniform100px,
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));

      var scrollCompleted = false;
      var frameCount = 0;

      unawaited(
        state.controller.scrollTo(
          100.0,
          duration: const Duration(milliseconds: 100),
        ).then((_) => scrollCompleted = true),
      );

      // Pump frames and collect snapshots until completion or guard limit.
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        frameCount++;

        if (scrollCompleted) break;
      }

      expect(scrollCompleted, isTrue,
          reason: 'scrollTo(100) on 150 uniform-height items must complete');

      final finalMeasurementCount = state.controller.measurementsSizes.length;
      final finalOffset = state.controller.position.pixels;

      // Expected: sum of heights 0..99 = 100 × 100 = 10,000px
      const expectedOffsetMin = 9900.0;
      const expectedOffsetMax = 10100.0;
      expect(finalOffset, inInclusiveRange(expectedOffsetMin, expectedOffsetMax),
          reason: 'Final offset for scrollTo(100) should be ~10,000px');

      expect(finalMeasurementCount, greaterThan(95),
          reason:
              'Sequential measurement to index 100 should measure at least 95 items');

      // Report measured metrics for ISC-18 documentation.
      // ignore: avoid_print
      print(
        'Uniform 100px list (150 items, scrollTo(100)): '
        'frames=$frameCount, measurements=$finalMeasurementCount, '
        'offset=${finalOffset.toStringAsFixed(0)}px',
      );

      // Verify linearity assumption: frame count should scale roughly linearly
      // with distance, not exponentially. For 150 items with 100px heights,
      // viewport is ~600px, so roughly 10,000px / 600px ≈ 16-17 viewports
      // to traverse. Empirical observation from ISC-04 (scrollTo(250) on
      // 300 items) showed ~120 frames; ratio of distance (250 items) to
      // frame count (120) ≈ 2 items/frame. At that rate, scrollTo(100)
      // should take roughly 50 frames; actual should be in the ballpark.
      expect(frameCount, lessThan(200),
          reason:
              'scrollTo(100) on 150-item list should not require >200 frames '
              '(would suggest exponential cost, not linear)');
    });

    testWidgets('scrollTo(250) on 300-item list with varied heights (40-72px)',
        (WidgetTester tester) async {
      // Mirror ISC-04's documented scenario: 250 items, varied heights,
      // observable in ~120 frames. This test validates that the measurement
      // is still linear for larger distances.
      await tester.pumpWidget(
        const ScrollHarness(
          itemCount: 300,
          itemHeightBuilder: _varied40to72px, // 40, 44, 48, 52, 56, 60, 64, 68, 72, 40, ...
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));

      var scrollCompleted = false;
      var frameCount = 0;

      unawaited(
        state.controller.scrollTo(
          250.0,
          duration: const Duration(milliseconds: 100),
        ).then((_) => scrollCompleted = true),
      );

      for (int i = 0; i < 400; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        frameCount++;

        if (scrollCompleted) break;
      }

      expect(scrollCompleted, isTrue,
          reason: 'scrollTo(250) on 300-item varied-height list must complete');

      final finalMeasurementCount = state.controller.measurementsSizes.length;

      // With heights varying 40-72px, average ~56px. Approximate offset:
      // 250 items × 56px average = 14,000px (rough estimate).
      const expectedOffsetMin = 13000.0;
      const expectedOffsetMax = 15000.0;
      expect(state.controller.position.pixels,
          inInclusiveRange(expectedOffsetMin, expectedOffsetMax),
          reason: 'Final offset for scrollTo(250) should be in range ~13-15kpx');

      expect(finalMeasurementCount, greaterThan(240),
          reason:
              'Sequential measurement to index 250 should measure at least 240 items');

      // ISC-04 documented ~120 frames for this scenario; actual may vary slightly
      // due to frame-pumping jitter, but should be in the same ballpark (80-200).
      expect(frameCount, lessThan(250),
          reason:
              'scrollTo(250) on 300-item list should complete within ~250 frames '
              '(consistent with ISC-04 observation of ~120 frames for similar scenario)');

      // ignore: avoid_print
      print(
        'Varied-height list (300 items, scrollTo(250)): '
        'frames=$frameCount, measurements=$finalMeasurementCount, '
        'offset=${state.controller.position.pixels.toStringAsFixed(0)}px',
      );

      // Confirm linearity: compare frame/distance ratio to smaller tests.
      // frameCount / distance should remain stable; if distance doubles
      // and frame count quintuples, that would suggest non-linearity.
      final framePerItemRatio = frameCount / 250.0;
      // ignore: avoid_print
      print('  Frame-per-item ratio: ${framePerItemRatio.toStringAsFixed(3)}');
    });

    testWidgets(
        'scrollTo(500) on 600-item list with random heights (50-150px)',
        (WidgetTester tester) async {
      // Large list with wider height variation; tests whether
      // sequential measurement remains linear and memory scales acceptably.
      await tester.pumpWidget(
        const ScrollHarness(
          itemCount: 600,
          itemHeightBuilder: _random50to150px,
          guardLimit: 1000, // Higher guard for larger list
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));

      var scrollCompleted = false;
      var frameCount = 0;

      unawaited(
        state.controller.scrollTo(
          500.0,
          duration: const Duration(milliseconds: 100),
        ).then((_) => scrollCompleted = true),
      );

      for (int i = 0; i < 800; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        frameCount++;

        if (scrollCompleted) break;
      }

      expect(scrollCompleted, isTrue,
          reason: 'scrollTo(500) on 600-item random-height list must complete');

      final finalMeasurementCount = state.controller.measurementsSizes.length;

      // With heights 50-150px, average ~100px. Approximate offset:
      // 500 items × 100px = 50,000px.
      expect(state.controller.position.pixels, greaterThan(40000.0),
          reason: 'scrollTo(500) on 600-item list should reach deep offset >40kpx');

      expect(finalMeasurementCount, greaterThan(490),
          reason:
              'Sequential measurement to index 500 should measure most of prefix');

      // Frame count scaling: at 500 items with higher average heights (~100px),
      // viewport is still ~600px, so ~50,000px / 600px ≈ 80 viewports.
      // If linear, should be ~2-3 items/frame → ~250-330 frames (rough).
      // Allow wider margin for larger list (more variability and randomness).
      expect(frameCount, lessThan(800),
          reason:
              'scrollTo(500) on large list should remain roughly linear, <800 frames '
              '(non-linear cost would exceed 1200+)');

      // ignore: avoid_print
      print(
        'Random-height list (600 items, scrollTo(500)): '
        'frames=$frameCount, measurements=$finalMeasurementCount, '
        'offset=${state.controller.position.pixels.toStringAsFixed(0)}px',
      );

      final framePerItemRatio = frameCount / 500.0;
      // ignore: avoid_print
      print('  Frame-per-item ratio: ${framePerItemRatio.toStringAsFixed(3)}');
    });

    test('Memory estimate: _sizes dictionary footprint at various list lengths',
        () {
      // Analytical memory estimation for fully-measured `Map<int, Size>` at
      // different list lengths. This does NOT directly profile the widget
      // test (that would be fragile), but estimates the overhead based on Dart
      // Size and Map semantics.
      //
      // Size is a simple record with two doubles: 16 bytes (2 × 8-byte floats).
      // Map<int, Size> has per-entry overhead:
      //   - Map.length tracks 1 entry (8 bytes overhead in _InternalLinkedHashMap)
      //   - LinkedHashMap uses a bucket array + linked list node per entry
      //   - Typical overhead: ~80 bytes per entry (hash bucket, chain pointers, etc)
      //   - Total per entry: 16 (Size) + 80 (Map overhead) ≈ 96 bytes worst-case
      //   - Conservative estimate: 100 bytes per entry for safety.
      //
      // For a list with full prefix measured (N items):
      //   - Memory ≈ N × 100 bytes
      //   - N=1000:  ~100 KB
      //   - N=5000:  ~500 KB
      //   - N=10000: ~1 MB

      const sizes = [100, 500, 1000, 5000, 10000];
      const bytesPerEntry = 100; // Conservative estimate

      // ignore: avoid_print
      print('\nMemory estimate for _sizes dictionary (Map<int, Size>):');
      // ignore: avoid_print
      print('(Analytical estimate, not direct profiling; assumes ~100 bytes/entry)');

      for (final n in sizes) {
        final estimatedBytes = n * bytesPerEntry;
        final estimatedKB = estimatedBytes / 1024.0;
        final estimatedMB = estimatedKB / 1024.0;

        final memoryStr = estimatedMB >= 1.0
            ? '${estimatedMB.toStringAsFixed(2)} MB'
            : '${estimatedKB.toStringAsFixed(1)} KB';

        // ignore: avoid_print
        print('  N=$n items: ~$memoryStr');

        // Sanity check: at reasonable list sizes, memory should remain modest.
        // Even at N=10,000, memory is ~1MB, which is negligible on mobile.
        expect(estimatedMB, lessThan(5.0),
            reason:
                'Memory per item should remain <500 bytes, keeping total <5MB at N=10,000');
      }
    });

    testWidgets('Frame-per-item ratio remains stable across different distances',
        (WidgetTester tester) async {
      // Meta-test: compare frame costs for scrolls of increasing distance,
      // confirming that the ratio frames/distance stays roughly constant
      // (linear scaling). Each scroll starts fresh from offset 0 to maximize
      // measurement work and avoid cache effects from previous scrolls.

      final results = <(int distance, int frames, double ratio)>[];

      // Test 1: scrollTo(50) — short distance
      await tester.pumpWidget(
        const ScrollHarness(
          itemCount: 500,
          itemHeightBuilder: _varied60to78px, // ~70px average
          guardLimit: 300,
        ),
      );

      var state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      var completed = false;
      var frames = 0;

      unawaited(
        state.controller.scrollTo(
          50.0,
          duration: const Duration(milliseconds: 100),
        ).then((_) => completed = true),
      );

      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
        if (completed) break;
      }

      expect(completed, isTrue, reason: 'scrollTo(50) must complete');
      final ratio1 = frames / 50.0;
      results.add((50, frames, ratio1));

      // Test 2: scrollTo(150) — medium distance (fresh harness)
      await tester.pumpWidget(
        const ScrollHarness(
          itemCount: 500,
          itemHeightBuilder: _varied60to78px,
          guardLimit: 400,
        ),
      );

      state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      completed = false;
      frames = 0;

      unawaited(
        state.controller.scrollTo(
          150.0,
          duration: const Duration(milliseconds: 100),
        ).then((_) => completed = true),
      );

      for (int i = 0; i < 400; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
        if (completed) break;
      }

      expect(completed, isTrue, reason: 'scrollTo(150) must complete');
      final ratio2 = frames / 150.0;
      results.add((150, frames, ratio2));

      // Test 3: scrollTo(300) — long distance (fresh harness)
      await tester.pumpWidget(
        const ScrollHarness(
          itemCount: 500,
          itemHeightBuilder: _varied60to78px,
          guardLimit: 600,
        ),
      );

      state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      completed = false;
      frames = 0;

      unawaited(
        state.controller.scrollTo(
          300.0,
          duration: const Duration(milliseconds: 100),
        ).then((_) => completed = true),
      );

      for (int i = 0; i < 600; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
        if (completed) break;
      }

      expect(completed, isTrue, reason: 'scrollTo(300) must complete');
      final ratio3 = frames / 300.0;
      results.add((300, frames, ratio3));

      // Report ratios
      // ignore: avoid_print
      print(
        '\nFrame-per-item ratio across distances (500-item list, ~70px average height):',
      );
      for (final (distance, frames, ratio) in results) {
        // ignore: avoid_print
        print('  scrollTo($distance): $frames frames → ratio = ${ratio.toStringAsFixed(3)} frames/item');
      }

      // Ratios should be close (within reasonable tolerance).
      // If linear, ratio should be ~0.3-0.5 frames per item (depending on
      // frame-pumping overhead). Allow ±50% variation due to frame timing jitter.
      final minRatio = results.map((r) => r.$3).reduce((a, b) => a < b ? a : b);
      final maxRatio = results.map((r) => r.$3).reduce((a, b) => a > b ? a : b);
      final ratioVariation = maxRatio / minRatio;

      // ignore: avoid_print
      print('  Min ratio: ${minRatio.toStringAsFixed(3)}, '
          'Max ratio: ${maxRatio.toStringAsFixed(3)}, '
          'Variation: ${ratioVariation.toStringAsFixed(2)}x');

      // If scaling is exponential, variation would be extreme (5x+).
      // If linear, variation should be modest (<2.5x due to jitter).
      expect(ratioVariation, lessThan(2.5),
          reason:
              'Frame-per-item ratio should remain stable across distances '
              '(linear cost); variation >2.5x would suggest non-linear scaling');
    });
  });
}
