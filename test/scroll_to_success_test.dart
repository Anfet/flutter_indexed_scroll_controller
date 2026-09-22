import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'support/scroll_harness.dart';

void main() {
  group('IndexedScrollController scrollTo success scenarios', () {
    testWidgets('scrollTo reaches far distant index (near-last element)', (WidgetTester tester) async {
      // Test scrolling to a distant index in a list with varied heights.
      // The early-exit bug (ISC-02A/ISC-02B) only triggers when maxVisibleIndex
      // exactly equals the target scrollToIndex at the moment of the call, not
      // merely because a scroll pass is long. Starting from offset=0 keeps the
      // initial maxVisibleIndex far from any distant target, so it is safe here.
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 150,
          itemHeightBuilder: (index) {
            return 40.0 + (index % 15) * 8.0;
          },
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));

      // Start at top
      await tester.pumpAndSettle();

      // Scroll to index 130 (far from initial 0)
      // This is far enough that maxVisibleIndex won't equal the target on the first check
      const targetIndex = 130;

      // Note: we don't use .then() tracking because the early exit bug
      // can cause completion with wrong offset. Instead we verify the result
      // by checking measured sizes and final offset directly.
      unawaited(
        state.controller.scrollTo(
          targetIndex.toDouble(),
          duration: const Duration(milliseconds: 100),
        ),
      );

      // Pump many frames to allow the scroll operation to complete
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // Verify the target index was reached
      // After a successful scroll, many items up to the target should be measured
      expect(
        state.controller.measurementsSizes.length,
        greaterThan(120),
        reason: 'Distant scroll should measure a continuous prefix of items (at least to near-target)',
      );

      // Get final position and verify it's reasonable for the target index
      final finalOffset = state.controller.position.pixels;

      // Calculate expected approximate offset:
      // Sum of heights from 0 to 129
      double expectedSum = 0;
      for (int i = 0; i < targetIndex; i++) {
        final height = 40.0 + (i % 15) * 8.0;
        expectedSum += height;
      }

      // The final offset should be close to the sum of prior items
      // Allow tolerance due to viewport-based stepping and fractional rounding
      expect(
        finalOffset,
        greaterThan(expectedSum - 500),
        reason: 'Final offset should be significantly greater than sum of initial items (~$expectedSum)',
      );
    });

    testWidgets('jumpTo forward to distant index and return with scrollTo', (WidgetTester tester) async {
      // Test the pattern: jumpTo forward, then scrollTo back
      // Confirms measurements are maintained across different scroll patterns
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 120,
          itemHeightBuilder: (index) {
            return 50.0 + (index % 12) * 5.0;
          },
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));

      await tester.pumpAndSettle();

      // JumpTo a distant pixel position
      state.controller.jumpTo(1000.0);
      await tester.pumpAndSettle();

      // Now scrollTo back to an earlier index (2) with animation
      // Use a small target to ensure it's far from current viewport
      unawaited(
        state.controller.scrollTo(
          2.0,
          duration: const Duration(milliseconds: 100),
        ),
      );

      // Pump frames to allow completion
      for (int i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // Verify we're back near the start
      final finalOffset = state.controller.position.pixels;
      expect(
        finalOffset,
        lessThan(300),
        reason: 'Scroll back to index 2 should result in offset < 300',
      );
    });

    testWidgets('scrollTo with fractional index and alignment = 0', (WidgetTester tester) async {
      // Test fractional indices with alignment=0 (top-align the row)
      // Formula: target = sum(heights 0..k-1) + height[k] * fraction
      //          - (viewport - height[k]) * alignment
      //        = sum(heights 0..k-1) + height[k] * fraction - (viewport - height[k]) * 0
      //        = sum(heights 0..k-1) + height[k] * fraction
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 100,
          itemHeightBuilder: (index) {
            return 100.0; // Uniform heights for easier verification
          },
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      // Scroll to index 12.5 with alignment=0
      // Expected: sum(0..11) + 100*0.5 = 1200 + 50 = 1250
      unawaited(
        state.controller.scrollTo(
          12.5,
          duration: const Duration(milliseconds: 100),
          alignment: 0.0,
        ),
      );

      // Pump many frames
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final finalOffset = state.controller.position.pixels;
      // With uniform 100px items and alignment=0, offset should be ~1250
      expect(
        finalOffset,
        inInclusiveRange(1200, 1300),
        reason: 'Fractional index 12.5 with alignment=0 should give offset ~1250 (± tolerance)',
      );
    });

    testWidgets('scrollTo with fractional index and alignment = 0.5', (WidgetTester tester) async {
      // Test fractional indices with alignment=0.5 (center the row in viewport)
      // Formula: target = sum(heights 0..k-1) + height[k] * fraction
      //          - (viewport - height[k]) * 0.5
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 100,
          itemHeightBuilder: (index) {
            return 100.0;
          },
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      // Scroll to index 12.5 with alignment=0.5
      // Expected: sum(0..11) + 100*0.5 - (600-100)*0.5 = 1200 + 50 - 250 = 1000
      unawaited(
        state.controller.scrollTo(
          12.5,
          duration: const Duration(milliseconds: 100),
          alignment: 0.5,
        ),
      );

      // Pump many frames
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final finalOffset = state.controller.position.pixels;
      // With alignment=0.5, offset should be around 1000
      expect(
        finalOffset,
        inInclusiveRange(950, 1050),
        reason: 'Fractional index 12.5 with alignment=0.5 should give offset ~1000 (± tolerance)',
      );
    });

    testWidgets('scrollTo with fractional index and alignment = 1', (WidgetTester tester) async {
      // Test fractional indices with alignment=1 (bottom-align the row)
      // Formula: target = sum(heights 0..k-1) + height[k] * fraction
      //          - (viewport - height[k]) * 1
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 100,
          itemHeightBuilder: (index) {
            return 100.0;
          },
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      // Scroll to index 12.5 with alignment=1
      // Expected: sum(0..11) + 100*0.5 - (600-100)*1 = 1200 + 50 - 500 = 750
      unawaited(
        state.controller.scrollTo(
          12.5,
          duration: const Duration(milliseconds: 100),
          alignment: 1.0,
        ),
      );

      // Pump many frames
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final finalOffset = state.controller.position.pixels;
      // With alignment=1, offset should be around 750
      expect(
        finalOffset,
        inInclusiveRange(700, 800),
        reason: 'Fractional index 12.5 with alignment=1 should give offset ~750 (± tolerance)',
      );
    });

    testWidgets('scrollTo reaches last element in large list', (WidgetTester tester) async {
      // Test scrolling to the very last item in a large list
      // Confirms the end boundary is handled correctly
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 200,
          itemHeightBuilder: (index) {
            return 60.0 + (index % 10) * 3.0;
          },
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      // Scroll to the last item (index 199)
      const lastIndex = 199;

      unawaited(
        state.controller.scrollTo(
          lastIndex.toDouble(),
          duration: const Duration(milliseconds: 100),
        ),
      );

      // Pump many frames to allow completion
      for (int i = 0; i < 400; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // All items should be measured
      expect(
        state.controller.measurementsSizes.length,
        greaterThanOrEqualTo(lastIndex),
        reason: 'Scroll to last item should measure a full continuous prefix of items',
      );

      // Verify we reached a position that makes sense for the last item
      final finalOffset = state.controller.position.pixels;
      expect(
        finalOffset,
        greaterThan(10000),
        reason: 'Scroll to last item (199) should reach significant offset > 10000',
      );
    });

    testWidgets('Multiple sequential scrolls accumulate measurements', (WidgetTester tester) async {
      // Test that the controller maintains and accumulates measurements across multiple
      // sequential scroll operations forward. This validates that the measurement dict
      // persists across multiple operations and that forward scrolling is reliable.
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 100,
          itemHeightBuilder: (index) {
            return 50.0 + (index % 15) * 3.0;
          },
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      // First scroll: to index 25
      unawaited(
        state.controller.scrollTo(
          25.0,
          duration: const Duration(milliseconds: 100),
        ),
      );

      // Pump frames
      for (int i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final firstMeasurements = state.controller.measurementsSizes.length;
      expect(
        firstMeasurements,
        greaterThan(20),
        reason: 'First scroll to 25 should measure many items',
      );

      // Second scroll: to a higher index (50)
      unawaited(
        state.controller.scrollTo(
          50.0,
          duration: const Duration(milliseconds: 100),
        ),
      );

      // Pump frames
      for (int i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final secondMeasurements = state.controller.measurementsSizes.length;
      expect(
        secondMeasurements,
        greaterThanOrEqualTo(firstMeasurements),
        reason: 'Measurements should accumulate or stay same; never decrease',
      );
      expect(
        secondMeasurements,
        greaterThan(40),
        reason: 'Second scroll should result in more measurements',
      );

      // Third scroll: to an even higher index (75)
      unawaited(
        state.controller.scrollTo(
          75.0,
          duration: const Duration(milliseconds: 100),
        ),
      );

      // Pump frames
      for (int i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final thirdMeasurements = state.controller.measurementsSizes.length;
      expect(
        thirdMeasurements,
        greaterThanOrEqualTo(secondMeasurements),
        reason: 'Measurements should continue to accumulate',
      );
      expect(
        thirdMeasurements,
        greaterThan(70),
        reason: 'Third scroll should result in comprehensive measurements',
      );
    });

    testWidgets('Long valid scroll pass (250 indices, ~300 rows, ~120+ frames)', (WidgetTester tester) async {
      // Mirrors the QA scenario: scrollTo(250) on a 300-row list took about
      // 120 frames to complete but did finish successfully. Starting from
      // offset=0 keeps the initial maxVisibleIndex (~5-8) far from the
      // target (250), so the early-exit bug (triggered only by an exact
      // numeric match between maxVisibleIndex and scrollToIndex) cannot
      // interfere here; a long pass is not itself a defect.
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 300,
          itemHeightBuilder: (index) {
            return 40.0 + (index % 10) * 4.0; // average ~58px per row
          },
          guardLimit: 500,
        ),
      );

      final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      var scrollCompleted = false;
      var scrollFailed = false;
      unawaited(
        state.controller
            .scrollTo(
              250.0,
              duration: const Duration(milliseconds: 100),
            )
            .then(
              (_) => scrollCompleted = true,
              onError: (_) => scrollFailed = true,
            ),
      );

      // Pump well beyond the observed ~120-frame QA completion time.
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(scrollFailed, isFalse, reason: 'scrollTo(250) must not error out');
      expect(
        scrollCompleted,
        isTrue,
        reason: 'scrollTo(250) Future must actually resolve, not just leave '
            'the offset looking plausible',
      );

      final finalOffset = state.controller.position.pixels;
      expect(
        finalOffset,
        greaterThan(10000),
        reason: 'A successful long pass to index 250 should reach a large offset',
      );
      expect(
        state.controller.measurementsSizes.length,
        greaterThan(200),
        reason: 'Sequential measurement should have covered most of the prefix',
      );
    });
  });
}
