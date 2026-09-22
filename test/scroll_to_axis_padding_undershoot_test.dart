import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/scroll_harness.dart';

void main() {
  group('ISC-60: scrollTo undershoots by leading padding along the scroll axis',
      () {
    testWidgets(
      'vertical list with padding.top undershoots by exactly padding.top',
      (WidgetTester tester) async {
        const paddingTop = 40.0;
        const itemHeight = 100.0;
        const targetIndex = 10;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 50,
            itemHeightBuilder: (index) => itemHeight,
            padding: const EdgeInsets.only(top: paddingTop),
            guardLimit: 200,
          ),
        );

        final state =
            tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(targetIndex.toDouble(),
              duration: const Duration(milliseconds: 100)),
        );

        // ListView.builder wraps its SliverList in a SliverPadding when
        // `padding` is set. position.pixels is measured from the start of
        // the viewport, while the controller's formula sums item extents
        // from the start of the CONTENT (i.e. after the leading padding).
        // Correct target = leadingPadding + sum(heights 0..9)
        //                = 40 + 10*100 = 1040
        // Current (buggy) formula omits leadingPadding entirely, landing at
        //                = sum(heights 0..9) = 1000
        // i.e. undershooting the correct target by exactly padding.top (40).
        const correctExpectedOffset = paddingTop + targetIndex * itemHeight;

        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(correctExpectedOffset, 1.0),
          reason: 'scrollTo() must land at the correct offset '
              '($correctExpectedOffset), which accounts for padding.top '
              '($paddingTop). The pre-ISC-63 formula omits leading padding '
              'and undershoots by exactly padding.top.',
        );
      },
    );

    testWidgets(
      'horizontal list with padding.left undershoots by exactly padding.left',
      (WidgetTester tester) async {
        const paddingLeft = 30.0;
        const itemWidth = 80.0;
        const targetIndex = 8;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 40,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: (index) => itemWidth,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: paddingLeft),
            guardLimit: 200,
          ),
        );

        final state =
            tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(targetIndex.toDouble(),
              duration: const Duration(milliseconds: 100)),
        );

        // Correct target = leadingPadding + sum(widths 0..7)
        //                = 30 + 8*80 = 670
        // Current (buggy) formula omits leadingPadding entirely, landing at
        //                = sum(widths 0..7) = 640
        // i.e. undershooting the correct target by exactly padding.left (30).
        const correctExpectedOffset = paddingLeft + targetIndex * itemWidth;

        final finalOffset = state.controller.position.pixels;
        expect(
          finalOffset,
          closeTo(correctExpectedOffset, 1.0),
          reason: 'scrollTo() must land at the correct offset '
              '($correctExpectedOffset), which accounts for padding.left '
              '($paddingLeft). The pre-ISC-63 formula omits leading padding '
              'and undershoots by exactly padding.left.',
        );
      },
    );
  });
}
