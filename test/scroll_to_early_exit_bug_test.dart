import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'support/scroll_harness.dart';

void main() {
  group('ISC-02A: scrollTo early exit bug with fixed item heights', () {
    // Configuration: rows 100px, viewport 600px (6 items visible)
    // Scenario: starting at offset 0, indices 0-5 are visible (6 rows = 600px)
    // Previously, scrollTo(6) incorrectly returned Future.value() at offset 0 instead of 600.
    // The early-exit check compares target pixels instead of visible indices.

    testWidgets(
      'scrollTo(5) reaches offset 500 - regression control',
      (WidgetTester tester) async {
        const rowHeight = 100.0;
        const itemCount = 20;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (index) => rowHeight,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        unawaited(
          state.controller.scrollTo(
            5.0,
            duration: const Duration(milliseconds: 100),
          ),
        );

        // Pump many frames to allow scroll to complete
        for (int i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          state.controller.position.pixels,
          closeTo(500.0, 1.0),
          reason: 'scrollTo(5) should reach offset 500 (5 rows * 100px)',
        );
      },
    );

    testWidgets(
      'scrollTo(7) reaches offset 700 - regression control',
      (WidgetTester tester) async {
        const rowHeight = 100.0;
        const itemCount = 20;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (index) => rowHeight,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        unawaited(
          state.controller.scrollTo(
            7.0,
            duration: const Duration(milliseconds: 100),
          ),
        );

        // Pump many frames to allow scroll to complete
        for (int i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          state.controller.position.pixels,
          closeTo(700.0, 1.0),
          reason: 'scrollTo(7) should reach offset 700 (7 rows * 100px)',
        );
      },
    );

    testWidgets(
      'scrollTo(6) reaches offset 600 - regression test for early exit bug (ISC-02B)',
      (WidgetTester tester) async {
        // Fixed by ISC-02B: the early exit used to compare maxVisibleIndex to scrollToIndex
        // by index equality. Since row 6 was partially in the "visible" range (due to the
        // flawed logic), scrollTo(6) returned Future.value() at offset 0 instead of scrolling
        // to offset 600. The early exit now compares the computed target offset in pixels to
        // the current position, so this scenario correctly moves the list.
        // A partially visible row must not complete scrollTo before reaching its
        // computed target offset.

        const rowHeight = 100.0;
        const itemCount = 20;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (index) => rowHeight,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        // Verify initial state: offset 0, indices 0-5 visible (6 rows = 600px)
        expect(
          state.controller.position.pixels,
          closeTo(0.0, 1.0),
          reason: 'Initial offset should be 0',
        );

        unawaited(
          state.controller.scrollTo(
            6.0,
            duration: const Duration(milliseconds: 100),
          ),
        );

        // Pump many frames to allow scroll to complete
        for (int i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final finalOffset = state.controller.position.pixels;

        expect(
          finalOffset,
          closeTo(600.0, 1.0),
          reason: 'scrollTo(6) should reach offset 600 (6 rows * 100px). Before ISC-02B, '
              'index 6 was considered "visible" by the flawed maxVisibleIndex check, so '
              'Future completed without actual scroll. The fix compares target pixels '
              'instead of indices.',
        );
      },
    );

    testWidgets(
      'scrollTo(0) after scrollTo to end returns to beginning - regression test for fully-measured-list bug (ISC-02B)',
      (WidgetTester tester) async {
        // Fixed by ISC-02B: when the entire list was already measured (e.g. after
        // scrollTo(15) on 20 rows), the old visible-range scan loop never reached its break
        // condition (scrolledWidgetHeights + size.height > heightWidthViewport was never true
        // for this config). Therefore maxVisibleIndex stayed at its initialization value 0.0,
        // which falsely matched scrollToIndex=0 under the old index-equality early exit,
        // causing early exit without actual scroll. The early exit now compares the
        // computed target offset in pixels to the current position.

        const rowHeight = 100.0;
        const itemCount = 20;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (index) => rowHeight,
            guardLimit: 300,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        // First, scroll to a far index (e.g., index 15) to fully measure the list
        unawaited(
          state.controller.scrollTo(
            15.0,
            duration: const Duration(milliseconds: 100),
          ),
        );

        // Pump frames for first scroll
        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final midOffset = state.controller.position.pixels;
        expect(
          midOffset,
          greaterThan(1000.0),
          reason: 'After scrollTo(15), offset should be around 1500 (15*100)',
        );

        // Then scroll back to beginning (index 0) with a fully measured list.
        // Before ISC-02B this triggered the bug: scan loop never broke, maxVisibleIndex
        // stayed 0.0, matched scrollToIndex 0 → false early exit at offset 1500.
        unawaited(
          state.controller.scrollTo(
            0.0,
            duration: const Duration(milliseconds: 100),
          ),
        );

        // Pump frames for second scroll
        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final finalOffset = state.controller.position.pixels;

        expect(
          finalOffset,
          closeTo(0.0, 1.0),
          reason: 'scrollTo(0) after scrollTo(15) should return to offset 0. Before ISC-02B, '
              'when the entire list was already measured, the visible-range scan loop never '
              'reached break, so maxVisibleIndex stayed at default 0.0, which falsely matched '
              'scrollToIndex=0, causing Future.value() completion without actual scroll. This '
              'was the second path of the defect, fixed by comparing target pixels '
              'instead of indices.',
        );
      },
    );

    testWidgets(
      'scrollTo(1) after scrollTo to end returns close to beginning - regression control',
      (WidgetTester tester) async {
        const rowHeight = 100.0;
        const itemCount = 20;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (index) => rowHeight,
            guardLimit: 300,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        // First, scroll to a far index (e.g., index 15)
        unawaited(
          state.controller.scrollTo(
            15.0,
            duration: const Duration(milliseconds: 100),
          ),
        );

        // Pump frames for first scroll
        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final midOffset = state.controller.position.pixels;
        expect(
          midOffset,
          greaterThan(1000.0),
          reason: 'After scrollTo(15), offset should be around 1500 (15*100)',
        );

        // Then scroll back to beginning (index 1, avoids the fully-measured-list bug)
        unawaited(
          state.controller.scrollTo(
            1.0,
            duration: const Duration(milliseconds: 100),
          ),
        );

        // Pump frames for second scroll
        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          state.controller.position.pixels,
          closeTo(100.0, 1.0),
          reason: 'scrollTo(1) after scrollTo(15) should return to offset ~100',
        );
      },
    );

    testWidgets(
      'scrollTo(3) reaches offset 300 - regression control',
      (WidgetTester tester) async {
        const rowHeight = 100.0;
        const itemCount = 20;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (index) => rowHeight,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        unawaited(
          state.controller.scrollTo(
            3.0,
            duration: const Duration(milliseconds: 100),
          ),
        );

        // Pump many frames to allow scroll to complete
        for (int i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          state.controller.position.pixels,
          closeTo(300.0, 1.0),
          reason: 'scrollTo(3) should reach offset 300 (3 rows * 100px)',
        );
      },
    );

    testWidgets(
      'scrollTo(4) reaches offset 400 - regression control',
      (WidgetTester tester) async {
        const rowHeight = 100.0;
        const itemCount = 20;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (index) => rowHeight,
            guardLimit: 200,
          ),
        );

        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        unawaited(
          state.controller.scrollTo(
            4.0,
            duration: const Duration(milliseconds: 100),
          ),
        );

        // Pump many frames to allow scroll to complete
        for (int i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          state.controller.position.pixels,
          closeTo(400.0, 1.0),
          reason: 'scrollTo(4) should reach offset 400 (4 rows * 100px)',
        );
      },
    );
  });
}
