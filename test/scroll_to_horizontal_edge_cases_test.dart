import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/scroll_harness.dart';

void main() {
  group('ISC-45: horizontal edge cases', () {
    double widthOf(int index) => 60.0 + (index % 10) * 10.0;

    testWidgets(
      'scrollTo a far unmeasured index with Duration.zero completes without animating',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 80,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: widthOf,
            scrollDirection: Axis.horizontal,
            guardLimit: 300,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        const targetIndex = 60;
        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero),
        );

        double expectedSum = 0;
        for (int i = 0; i < targetIndex; i++) {
          expectedSum += widthOf(i);
        }

        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(expectedSum, 1.0),
          reason: 'Duration.zero horizontal scrollTo should jump straight to '
              'the width-summed offset without animating',
        );
      },
    );

    testWidgets(
      'scrollTo an index past the end of a horizontal list fails with RangeError',
      (WidgetTester tester) async {
        const itemCount = 20;
        const unreachableIndex = 999.0;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: widthOf,
            scrollDirection: Axis.horizontal,
            guardLimit: 400,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        Object? scrollError;
        try {
          await pumpUntilComplete(
            tester,
            state.controller.scrollTo(unreachableIndex),
            maxPumps: 300,
          );
        } catch (e) {
          scrollError = e;
        }

        expect(
          scrollError,
          isA<RangeError>(),
          reason: 'An index past the end of a horizontal list should fail '
              'with a RangeError. Got: $scrollError',
        );
      },
    );

    testWidgets(
      'invalidateMeasurements() after a width change is required before the next scrollTo',
      (WidgetTester tester) async {
        double currentWidthOf(int index) => 60.0 + (index % 10) * 10.0;
        double widenedWidthOf(int index) => currentWidthOf(index) + 40.0;

        Widget buildHarness(ItemHeightBuilder widthBuilder) => ScrollHarness(
              itemCount: 40,
              itemHeightBuilder: (index) => 80.0,
              itemWidthBuilder: widthBuilder,
              scrollDirection: Axis.horizontal,
              guardLimit: 300,
            );

        await tester.pumpWidget(buildHarness(currentWidthOf));

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        // Measure the initial prefix, then return to the start of the axis
        // so the probing scrollTo below starts its search from a live index
        // 0 rather than needing a multi-frame jump-back-to-0 recovery pass.
        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(20.0, duration: const Duration(milliseconds: 100)),
        );
        state.controller.jumpTo(0);
        await tester.pumpAndSettle();

        // Widths change (a real app calls setState with new data here); the
        // contract requires invalidateMeasurements() once the new widths are
        // in the widget tree.
        await tester.pumpWidget(buildHarness(widenedWidthOf));
        state.controller.invalidateMeasurements();
        await tester.pumpAndSettle();

        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(20.0, duration: const Duration(milliseconds: 100)),
        );

        double expectedSum = 0;
        for (int i = 0; i < 20; i++) {
          expectedSum += widenedWidthOf(i);
        }

        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(expectedSum, 1.0),
          reason: 'After invalidateMeasurements() and re-layout with new '
              'widths, scrollTo must land using the new widths, not stale '
              'cached ones',
        );
      },
    );

    testWidgets(
      'switching the same controller/list from vertical to horizontal requires '
      'invalidateMeasurements() before the next scrollTo',
      (WidgetTester tester) async {
        double heightOf(int index) => 60.0 + (index % 10) * 10.0;

        // Start vertical: measure a prefix under vertical (height-based)
        // layout constraints.
        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 40,
            itemHeightBuilder: heightOf,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(15.0, duration: const Duration(milliseconds: 100)),
        );

        double expectedVerticalSum = 0;
        for (int i = 0; i < 15; i++) {
          expectedVerticalSum += heightOf(i);
        }
        expect(
          state.controller.position.pixels,
          closeTo(expectedVerticalSum, 1.0),
          reason: 'Sanity check: the vertical scroll must land at the '
              'height-summed offset before the orientation switch',
        );

        // Switch the same controller/list to horizontal. Old measurements
        // were taken under vertical layout constraints and are no longer
        // valid — the contract requires invalidateMeasurements() before the
        // next scrollTo, the same rule that applies to any other geometry
        // change.
        state.controller.jumpTo(0);
        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 40,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: widthOf,
            scrollDirection: Axis.horizontal,
          ),
        );
        state.controller.invalidateMeasurements();
        await tester.pumpAndSettle();

        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(15.0, duration: const Duration(milliseconds: 100)),
        );

        double expectedHorizontalSum = 0;
        for (int i = 0; i < 15; i++) {
          expectedHorizontalSum += widthOf(i);
        }

        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(expectedHorizontalSum, 1.0),
          reason: 'After switching to horizontal and invalidating, scrollTo '
              'must use the new widths (position.axis), not the stale '
              'vertical heights',
        );
      },
    );

    testWidgets(
      'RTL horizontal list without reverse: alignment=0 measures from the start of the axis',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 30,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: widthOf,
            scrollDirection: Axis.horizontal,
            textDirection: TextDirection.rtl,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        const targetIndex = 10;
        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(targetIndex.toDouble(), duration: const Duration(milliseconds: 100)),
        );

        double expectedSum = 0;
        for (int i = 0; i < targetIndex; i++) {
          expectedSum += widthOf(i);
        }

        final finalOffset = state.controller.position.pixels;
        // RTL without `reverse: true` does not flip position.pixels direction
        // (ListView's own `reverse` flag controls that, unchanged by this
        // package); position.pixels still measures growth from the scroll
        // start of the axis, so the same width-sum formula applies.
        expect(
          finalOffset,
          closeTo(expectedSum, 1.0),
          reason: 'RTL Directionality alone (no reverse:true) must not '
              'change how scrollTo computes pixels from summed widths',
        );
      },
    );
  });
}
