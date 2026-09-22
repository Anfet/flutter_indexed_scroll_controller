import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';
import 'support/scroll_harness.dart';

void main() {
  group('ISC-64: axis-padding regressions', () {
    testWidgets(
      'symmetric padding: both top and bottom set, only top (leading) contributes',
      (WidgetTester tester) async {
        const paddingTop = 20.0;
        const paddingBottom = 20.0;
        const itemHeight = 60.0;
        const targetIndex = 7;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 40,
            itemHeightBuilder: (index) => itemHeight,
            padding: const EdgeInsets.symmetric(vertical: paddingTop),
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

        // Symmetric padding contributes only via its leading (top) side;
        // padding.bottom must not be summed in even though it is numerically
        // equal here, which would otherwise mask a double-counting bug.
        const expected = paddingTop + targetIndex * itemHeight;
        expect(
          state.controller.position.pixels,
          closeTo(expected, 1.0),
          reason: 'Symmetric padding must contribute only its leading '
              '(top) side ($paddingTop), not both sides '
              '(${paddingTop + paddingBottom}).',
        );
      },
    );

    testWidgets(
      'trailing-only padding (bottom) does not affect the offset',
      (WidgetTester tester) async {
        const itemHeight = 60.0;
        const targetIndex = 7;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 40,
            itemHeightBuilder: (index) => itemHeight,
            padding: const EdgeInsets.only(bottom: 90.0),
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

        const expected = targetIndex * itemHeight;
        expect(
          state.controller.position.pixels,
          closeTo(expected, 1.0),
          reason: 'padding.bottom is a trailing/"after" inset for a '
              'non-reversed vertical list and must not shift the computed '
              'offset at all.',
        );
      },
    );

    for (final alignment in [0.0, 0.5, 1.0]) {
      testWidgets(
        'alignment=$alignment combined with padding.top lands at the correct offset',
        (WidgetTester tester) async {
          const paddingTop = 35.0;
          const itemHeight = 100.0;

          await tester.pumpWidget(
            ScrollHarness(
              itemCount: 60,
              itemHeightBuilder: (index) => itemHeight,
              padding: const EdgeInsets.only(top: paddingTop),
              guardLimit: 300,
            ),
          );

          final state =
              tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
          await tester.pumpAndSettle();
          final viewportHeight = state.controller.position.viewportDimension;

          // Fractional index 12.5 exercises alignment and padding together.
          await pumpUntilComplete(
            tester,
            state.controller.scrollTo(
              12.5,
              duration: const Duration(milliseconds: 100),
              alignment: alignment,
            ),
          );

          final expected = paddingTop +
              12 * itemHeight +
              itemHeight * 0.5 -
              (viewportHeight - itemHeight) * alignment;
          expect(
            state.controller.position.pixels,
            closeTo(expected, 1.0),
            reason: 'padding.top ($paddingTop) and alignment ($alignment) '
                'must combine additively: padding shifts the whole target, '
                'alignment adjusts within the viewport, neither should '
                'cancel or double-count the other.',
          );
        },
      );
    }

    testWidgets(
      'Duration.zero jumps straight to the padded target',
      (WidgetTester tester) async {
        const paddingTop = 45.0;
        const itemHeight = 80.0;
        const targetIndex = 4;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 30,
            itemHeightBuilder: (index) => itemHeight,
            padding: const EdgeInsets.only(top: paddingTop),
            guardLimit: 200,
          ),
        );

        final state =
            tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        final future = state.controller
            .scrollTo(targetIndex.toDouble(), duration: Duration.zero);
        await tester.pump();
        await future;

        const expected = paddingTop + targetIndex * itemHeight;
        expect(
          state.controller.position.pixels,
          closeTo(expected, 1.0),
          reason: 'A zero-duration jump must land at the same '
              'padding-inclusive target as an animated scroll.',
        );
      },
    );

    testWidgets(
      'target near the end of the list: padding and final clamp interact correctly',
      (WidgetTester tester) async {
        // Reviewer note (ISC-64 follow-up): the original version of this
        // test compared the final offset against
        // `state.controller.position.maxScrollExtent`, which Flutter itself
        // computes from the real (padding-inclusive) layout. That made the
        // assertion tautological -- both the pre-ISC-63 buggy formula
        // (paddingTop omitted: target 900) and the fixed one (target 950)
        // clamp to the SAME maxScrollExtent for a viewport this short, so
        // the test could not have told a regression apart from a fix; it
        // would stay green either way.
        //
        // This version instead pins every dimension to literal numbers
        // (viewport=150, itemHeight=100, paddingTop=100, itemCount=10) that
        // put the buggy and fixed unclamped targets on OPPOSITE sides of
        // maxScrollExtent (950):
        //   buggy target   = 9 * 100             = 900  (< 950, would NOT
        //                                                 have needed
        //                                                 clamping at all)
        //   correct target = 100 + 9 * 100        = 1000 (> 950, clamps
        //                                                 down TO 950)
        // So a regression to the pre-ISC-63 formula would land at 900.0
        // here -- a full 50px away from the expected 950.0, not merely
        // "still equal to maxScrollExtent by construction".
        const paddingTop = 100.0;
        const itemHeight = 100.0;
        const viewportHeight = 150.0;
        const itemCount = 10;
        const lastIndex = itemCount - 1;

        const buggyUnclampedTarget = lastIndex * itemHeight; // 900.0
        const correctUnclampedTarget =
            paddingTop + lastIndex * itemHeight; // 1000.0
        const expectedMaxScrollExtent =
            paddingTop + itemCount * itemHeight - viewportHeight; // 950.0
        // Sanity-check the constants themselves so a future edit to them
        // cannot silently collapse the scenario back into the tautological
        // case this test was written to replace.
        expect(buggyUnclampedTarget, lessThan(expectedMaxScrollExtent));
        expect(correctUnclampedTarget, greaterThan(expectedMaxScrollExtent));

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                height: viewportHeight,
                width: 300.0,
                child: ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.only(top: paddingTop),
                  itemCount: itemCount,
                  itemBuilder: (context, index) => controller.watch(
                    index: index,
                    child: SizedBox(
                        height: itemHeight, child: Text('Item $index')),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(controller.position.viewportDimension, viewportHeight);

        await pumpUntilComplete(
          tester,
          controller.scrollTo(lastIndex.toDouble(),
              duration: const Duration(milliseconds: 100)),
        );

        expect(
          controller.position.maxScrollExtent,
          closeTo(expectedMaxScrollExtent, 1.0),
          reason: 'Sanity check on the harness itself before trusting the '
              'assertion below.',
        );
        expect(
          controller.position.pixels,
          closeTo(expectedMaxScrollExtent, 1.0),
          reason: 'Scrolling to the last item must land at 950.0 -- the '
              'padding-inclusive target (1000.0) clamped down to '
              'maxScrollExtent. Landing at 900.0 instead would mean '
              'padding.top was silently dropped again (the pre-ISC-63 bug).',
        );
      },
    );

    testWidgets(
      'horizontal axis: padding.left included, padding.right excluded, combined with alignment',
      (WidgetTester tester) async {
        const paddingLeft = 22.0;
        const itemWidth = 70.0;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: 50,
            itemHeightBuilder: (index) => 80.0,
            itemWidthBuilder: (index) => itemWidth,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: paddingLeft, right: 90.0),
            guardLimit: 300,
          ),
        );

        final state =
            tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();
        final viewportWidth = state.controller.position.viewportDimension;

        await pumpUntilComplete(
          tester,
          state.controller.scrollTo(15.5,
              duration: const Duration(milliseconds: 100), alignment: 0.5),
        );

        final expected = paddingLeft +
            15 * itemWidth +
            itemWidth * 0.5 -
            (viewportWidth - itemWidth) * 0.5;
        expect(
          state.controller.position.pixels,
          closeTo(expected, 1.0),
          reason: 'Horizontal scrollTo must include padding.left (leading) '
              'and exclude padding.right (trailing), combined correctly '
              'with alignment=0.5 centering on item width.',
        );
      },
    );
  });
}
