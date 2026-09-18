import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/scroll_harness.dart';

void main() {
  group('ISC-43: horizontal ListView.builder with varied item widths', () {
    // Fixed height, varied width — the previous height-only formula would
    // sum item heights (all equal) instead of widths, producing a wrong
    // pixel offset whenever width varies by index.
    double widthOf(int index) => 60.0 + (index % 10) * 10.0;

    testWidgets(
      'scrollTo an already-measured index lands at the width-summed offset',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 30,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: widthOf,
            scrollDirection: Axis.horizontal,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        // Warm the cache by jumping to index 10's target offset first, then
        // prove index 10 actually landed in measurementsSizes before relying
        // on scrollTo()'s already-measured fast path below — otherwise this
        // test could pass for the wrong reason (falling through to the
        // sequential-search path instead of exercising the fast path).
        double warmupOffset = 0;
        for (int i = 0; i < 10; i++) {
          warmupOffset += widthOf(i);
        }
        state.controller.jumpTo(warmupOffset);
        await tester.pumpAndSettle();
        expect(
          state.controller.measurementsSizes.containsKey(10),
          isTrue,
          reason: 'Index 10 must be measured before scrollTo(10) so this '
              'test exercises the already-measured fast path',
        );

        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(10.0, duration: const Duration(milliseconds: 100)),
        );

        double expectedSum = 0;
        for (int i = 0; i < 10; i++) {
          expectedSum += widthOf(i);
        }

        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(expectedSum, 1.0),
          reason: 'alignment=0 horizontal scrollTo(10) should land at the '
              'sum of widths 0..9 ($expectedSum), not a height-based sum',
        );
      },
    );

    testWidgets(
      'scrollTo an unmeasured distant index searches forward and lands correctly',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 60,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: widthOf,
            scrollDirection: Axis.horizontal,
            guardLimit: 300,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        const targetIndex = 45;
        expect(
          state.controller.measurementsSizes.containsKey(targetIndex),
          isFalse,
          reason: 'Index 45 must start unmeasured so scrollTo drives the '
              'sequential search/measure loop, not the fast path',
        );

        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(targetIndex.toDouble(), duration: const Duration(milliseconds: 100)),
          maxPumps: 300,
        );

        double expectedSum = 0;
        for (int i = 0; i < targetIndex; i++) {
          expectedSum += widthOf(i);
        }

        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(expectedSum, 1.0),
          reason: 'Sequential search must sum widths, not heights, when '
              'measuring forward to an unmeasured horizontal index',
        );
        expect(state.controller.measurementsSizes.containsKey(targetIndex), isTrue);
      },
    );

    testWidgets(
      'fractional index with alignment=0 sums widths without centering adjustment',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 40,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: (index) => 100.0,
            scrollDirection: Axis.horizontal,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        // Expected: sum(0..11)*100 + 100*0.5 - (viewport-100)*0 = 1250
        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(12.5, duration: const Duration(milliseconds: 100), alignment: 0.0),
        );

        const expected = 12 * 100.0 + 100.0 * 0.5;
        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(expected, 1.0),
          reason: 'Fractional horizontal index with alignment=0 should sum '
              'widths without a centering adjustment',
        );
      },
    );

    testWidgets(
      'fractional index with alignment=0.5 centers using item width',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 40,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: (index) => 100.0,
            scrollDirection: Axis.horizontal,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        final viewportWidth = state.controller.position.viewportDimension;

        // Expected: sum(0..11)*100 + 100*0.5 - (viewport-100)*0.5
        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(12.5, duration: const Duration(milliseconds: 100), alignment: 0.5),
        );

        final expected = 12 * 100.0 + 100.0 * 0.5 - (viewportWidth - 100.0) * 0.5;
        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(expected, 1.0),
          reason: 'Fractional horizontal index with alignment=0.5 should '
              'center using item width, not height',
        );
      },
    );

    testWidgets(
      'fractional index with alignment=1 bottom-aligns (end-of-axis) using item width',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 40,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: (index) => 100.0,
            scrollDirection: Axis.horizontal,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        final viewportWidth = state.controller.position.viewportDimension;

        // Expected: sum(0..11)*100 + 100*0.5 - (viewport-100)*1
        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(12.5, duration: const Duration(milliseconds: 100), alignment: 1.0),
        );

        final expected = 12 * 100.0 + 100.0 * 0.5 - (viewportWidth - 100.0) * 1.0;
        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(expected, 1.0),
          reason: 'Fractional horizontal index with alignment=1 should '
              'align the item to the end of the axis using item width, not '
              'height',
        );
      },
    );
  });
}
