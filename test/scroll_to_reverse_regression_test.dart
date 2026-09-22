import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';
import 'support/scroll_harness.dart';

/// ISC-68: reverse regressions confirming that the search loop
/// ([IndexedScrollController]'s internal `_runAnimateTo`), `_clampToBounds`,
/// gesture-cancellation, and the fingerprint/selective-remeasurement mode are
/// all direction-neutral under `reverse: true`, exactly as the ISC-67 header
/// claims -- this file exists to confirm that, not merely assume it.
///
/// Every scenario uses a row-size function that returns a DIFFERENT size per
/// index (never a constant extent), so a formula that accidentally
/// double-inverts, or that inverts `priorItems` instead of only the alignment
/// term, cannot pass by coincidence the way it could on a uniform list.
void main() {
  // Deliberately irregular per-index extent: a constant stride (e.g. 20 + 5*i)
  // would still let a swapped pair of terms cancel out at some particular
  // target index. Multiplying by a small varying factor breaks that.
  double raggedExtent(int index, {double base = 40.0}) =>
      base + (index % 7) * 11.0 + (index.isEven ? 3.0 : 0.0);

  Future<IndexedScrollController> pumpReverseVertical(
    WidgetTester tester, {
    required int itemCount,
    required double Function(int) heightOf,
    EdgeInsets? padding,
  }) async {
    final controller = IndexedScrollController(
      scrollDuration: const Duration(milliseconds: 100),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            reverse: true,
            padding: padding,
            itemCount: itemCount,
            itemBuilder: (context, index) => controller.watch(
              index: index,
              child:
                  SizedBox(height: heightOf(index), child: Text('Item $index')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<IndexedScrollController> pumpReverseHorizontal(
    WidgetTester tester, {
    required int itemCount,
    required double Function(int) widthOf,
  }) async {
    final controller = IndexedScrollController(
      scrollDuration: const Duration(milliseconds: 100),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            scrollDirection: Axis.horizontal,
            reverse: true,
            itemCount: itemCount,
            itemBuilder: (context, index) => controller.watch(
              index: index,
              child:
                  SizedBox(width: widthOf(index), child: Text('Item $index')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  // Mirrors _clampToBounds: scrollTo's final target is always clamped to
  // [minScrollExtent, maxScrollExtent], so an expectation that omits this
  // would be wrong for any target near either physical edge (e.g. index 0
  // at alignment 0, where the raw formula asks for a negative offset).
  double expectedOffset({
    required double Function(int) extentOf,
    required int targetIndex,
    required double fraction,
    required double viewportExtent,
    required double alignment,
    double leadingPadding = 0.0,
    double? minScrollExtent,
    double? maxScrollExtent,
  }) {
    var priorItems = 0.0;
    for (var i = 0; i < targetIndex; i++) {
      priorItems += extentOf(i);
    }
    final extent = extentOf(targetIndex);
    final effectiveAlignment = 1.0 - alignment; // reverse: true
    final alignmentAdjust = -(viewportExtent - extent) * effectiveAlignment;
    final raw =
        leadingPadding + priorItems + extent * fraction + alignmentAdjust;
    if (minScrollExtent == null || maxScrollExtent == null) {
      return raw;
    }
    return raw.clamp(minScrollExtent, maxScrollExtent);
  }

  group('ISC-68: reverse regressions with ragged (non-uniform) extents', () {
    for (final alignment in [0.0, 0.5, 1.0]) {
      testWidgets(
        'vertical reverse, ragged heights: alignment=$alignment lands exactly',
        (WidgetTester tester) async {
          const itemCount = 50;
          const targetIndex = 22;
          double heightOf(int i) => raggedExtent(i, base: 30.0);

          final controller = await pumpReverseVertical(tester,
              itemCount: itemCount, heightOf: heightOf);
          final viewport = controller.position.viewportDimension;

          await pumpUntilComplete(
            tester,
            controller.scrollTo(targetIndex.toDouble(),
                duration: const Duration(milliseconds: 100),
                alignment: alignment),
          );

          final expected = expectedOffset(
            extentOf: heightOf,
            targetIndex: targetIndex,
            fraction: 0.0,
            viewportExtent: viewport,
            alignment: alignment,
          );
          expect(
            controller.position.pixels,
            closeTo(expected, 1.0),
            reason:
                'Non-uniform row heights must not cancel a swapped term in the offset formula.',
          );
        },
      );

      testWidgets(
        'horizontal reverse, ragged widths: alignment=$alignment lands exactly',
        (WidgetTester tester) async {
          const itemCount = 50;
          const targetIndex = 18;
          double widthOf(int i) => raggedExtent(i, base: 45.0);

          final controller = await pumpReverseHorizontal(tester,
              itemCount: itemCount, widthOf: widthOf);
          final viewport = controller.position.viewportDimension;

          await pumpUntilComplete(
            tester,
            controller.scrollTo(targetIndex.toDouble(),
                duration: const Duration(milliseconds: 100),
                alignment: alignment),
          );

          final expected = expectedOffset(
            extentOf: widthOf,
            targetIndex: targetIndex,
            fraction: 0.0,
            viewportExtent: viewport,
            alignment: alignment,
          );
          expect(
            controller.position.pixels,
            closeTo(expected, 1.0),
            reason:
                'Non-uniform column widths must not cancel a swapped term in the offset formula.',
          );
        },
      );
    }

    testWidgets(
      'vertical reverse: index 0 (first item) with ragged heights',
      (WidgetTester tester) async {
        const itemCount = 40;
        double heightOf(int i) => raggedExtent(i, base: 25.0);

        final controller = await pumpReverseVertical(tester,
            itemCount: itemCount, heightOf: heightOf);
        final viewport = controller.position.viewportDimension;

        await pumpUntilComplete(
          tester,
          controller.scrollTo(0.0, duration: const Duration(milliseconds: 100)),
        );

        final expected = expectedOffset(
          extentOf: heightOf,
          targetIndex: 0,
          fraction: 0.0,
          viewportExtent: viewport,
          alignment: 0.0,
          minScrollExtent: controller.position.minScrollExtent,
          maxScrollExtent: controller.position.maxScrollExtent,
        );
        expect(controller.position.pixels, closeTo(expected, 1.0));
      },
    );

    testWidgets(
      'vertical reverse: last index with ragged heights, alignment=1',
      (WidgetTester tester) async {
        const itemCount = 30;
        const lastIndex = itemCount - 1;
        double heightOf(int i) => raggedExtent(i, base: 35.0);

        final controller = await pumpReverseVertical(tester,
            itemCount: itemCount, heightOf: heightOf);
        final viewport = controller.position.viewportDimension;

        await pumpUntilComplete(
          tester,
          controller.scrollTo(lastIndex.toDouble(),
              duration: const Duration(milliseconds: 100), alignment: 1.0),
        );

        final unclamped = expectedOffset(
          extentOf: heightOf,
          targetIndex: lastIndex,
          fraction: 0.0,
          viewportExtent: viewport,
          alignment: 1.0,
        );
        final expected = unclamped.clamp(controller.position.minScrollExtent,
            controller.position.maxScrollExtent);
        expect(controller.position.pixels, closeTo(expected, 1.0));
      },
    );

    testWidgets(
      'vertical reverse: fractional target index with ragged heights',
      (WidgetTester tester) async {
        const itemCount = 45;
        const targetIndex = 15;
        const fraction = 0.5;
        double heightOf(int i) => raggedExtent(i, base: 50.0);

        final controller = await pumpReverseVertical(tester,
            itemCount: itemCount, heightOf: heightOf);
        final viewport = controller.position.viewportDimension;

        await pumpUntilComplete(
          tester,
          controller.scrollTo(
            targetIndex + fraction,
            duration: const Duration(milliseconds: 100),
            alignment: 0.5,
          ),
        );

        final expected = expectedOffset(
          extentOf: heightOf,
          targetIndex: targetIndex,
          fraction: fraction,
          viewportExtent: viewport,
          alignment: 0.5,
        );
        expect(controller.position.pixels, closeTo(expected, 1.0));
      },
    );

    testWidgets(
      'vertical reverse: Duration.zero jumps straight to the exact target',
      (WidgetTester tester) async {
        const itemCount = 35;
        const targetIndex = 9;
        double heightOf(int i) => raggedExtent(i, base: 55.0);

        final controller = await pumpReverseVertical(tester,
            itemCount: itemCount, heightOf: heightOf);
        final viewport = controller.position.viewportDimension;

        final future = controller.scrollTo(targetIndex.toDouble(),
            duration: Duration.zero, alignment: 0.5);
        await tester.pump();
        await future;

        final expected = expectedOffset(
          extentOf: heightOf,
          targetIndex: targetIndex,
          fraction: 0.0,
          viewportExtent: viewport,
          alignment: 0.5,
        );
        expect(controller.position.pixels, closeTo(expected, 1.0));
      },
    );

    testWidgets(
      'vertical reverse: search for an unmeasured target exercises _runAnimateTo\'s search loop',
      (WidgetTester tester) async {
        // A long list and a distant target ensure the already-measured fast
        // path in scrollTo cannot satisfy this call: most of the prefix is
        // unmeasured at the time scrollTo is issued, forcing the sequential
        // search-from-0 pass in _runAnimateTo (untouched by ISC-67) to run
        // under reverse: true.
        const itemCount = 200;
        const targetIndex = 140;
        double heightOf(int i) => raggedExtent(i, base: 20.0);

        final controller = await pumpReverseVertical(tester,
            itemCount: itemCount, heightOf: heightOf);
        expect(
          controller.measurementsSizes.containsKey(targetIndex),
          isFalse,
          reason:
              'Sanity check: the target must genuinely be unmeasured so this exercises the search loop.',
        );
        final viewport = controller.position.viewportDimension;

        await pumpUntilComplete(
          tester,
          controller.scrollTo(targetIndex.toDouble(),
              duration: const Duration(milliseconds: 100), alignment: 0.5),
          maxPumps: 500,
        );

        final expected = expectedOffset(
          extentOf: heightOf,
          targetIndex: targetIndex,
          fraction: 0.0,
          viewportExtent: viewport,
          alignment: 0.5,
        );
        expect(
          controller.position.pixels,
          closeTo(expected, 1.0),
          reason: 'The search loop (priorItems summation, clamp, and stall '
              'detection) must remain direction-neutral under reverse: '
              'true, exactly as the ISC-67 header claims.',
        );
      },
    );

    testWidgets(
      'horizontal reverse: search for an unmeasured target exercises _runAnimateTo\'s search loop',
      (WidgetTester tester) async {
        const itemCount = 150;
        const targetIndex = 100;
        double widthOf(int i) => raggedExtent(i, base: 30.0);

        final controller = await pumpReverseHorizontal(tester,
            itemCount: itemCount, widthOf: widthOf);
        expect(controller.measurementsSizes.containsKey(targetIndex), isFalse);
        final viewport = controller.position.viewportDimension;

        await pumpUntilComplete(
          tester,
          controller.scrollTo(targetIndex.toDouble(),
              duration: const Duration(milliseconds: 100), alignment: 0.0),
          maxPumps: 500,
        );

        final expected = expectedOffset(
          extentOf: widthOf,
          targetIndex: targetIndex,
          fraction: 0.0,
          viewportExtent: viewport,
          alignment: 0.0,
        );
        expect(controller.position.pixels, closeTo(expected, 1.0));
      },
    );

    testWidgets(
      'reverse + leading padding: vertical scrollTo includes padding.bottom (the reversed leading side)',
      (WidgetTester tester) async {
        // RenderSliverEdgeInsetsPadding.beforePadding already resolves the
        // leading side per-axis-direction (see the todo.md header): for
        // AxisDirection.up (vertical reverse: true) it returns
        // resolvedPadding.bottom, not .top -- confirmed directly against the
        // Flutter SDK source (rendering/sliver_padding.dart). So under
        // reverse: true, EdgeInsets.bottom is the "leading" (near
        // scrollOffset 0) side and EdgeInsets.top is the "trailing" one --
        // the mirror image of the non-reversed case. This is purely a
        // confirming test -- no lib/ logic is expected to need
        // reverse-specific padding handling.
        const paddingBottom = 37.0;
        const itemCount = 40;
        const targetIndex = 12;
        double heightOf(int i) => raggedExtent(i, base: 42.0);

        final controller = await pumpReverseVertical(
          tester,
          itemCount: itemCount,
          heightOf: heightOf,
          padding: const EdgeInsets.only(top: 90.0, bottom: paddingBottom),
        );
        final viewport = controller.position.viewportDimension;
        final leadingPadding = controller.leadingAxisPaddingForTesting;

        await pumpUntilComplete(
          tester,
          controller.scrollTo(targetIndex.toDouble(),
              duration: const Duration(milliseconds: 100), alignment: 0.5),
        );

        final expected = expectedOffset(
          extentOf: heightOf,
          targetIndex: targetIndex,
          fraction: 0.0,
          viewportExtent: viewport,
          alignment: 0.5,
          leadingPadding: leadingPadding,
        );
        expect(
          controller.position.pixels,
          closeTo(expected, 1.0),
          reason: 'reverse:true must include leading padding (resolved for '
              'the reversed axis direction by the Flutter SDK itself) and '
              'exclude trailing padding, exactly like the non-reversed case '
              '-- only which physical side counts as "leading" flips.',
        );
        expect(
          leadingPadding,
          closeTo(paddingBottom, 0.5),
          reason: 'Under reverse: true, beforePadding resolves to '
              'EdgeInsets.bottom, confirming the SDK resolved it for the '
              'reversed axis direction rather than defaulting to the '
              'non-reversed side.',
        );
      },
    );

    testWidgets(
      'reverse + leading padding: horizontal scrollTo includes padding.right (the reversed leading side)',
      (WidgetTester tester) async {
        // For a horizontal LTR list with reverse: true, AxisDirection is
        // `left`, whose beforePadding resolves to resolvedPadding.right
        // (see the vertical test's comment for the SDK source reference).
        const paddingRight = 28.0;
        const itemCount = 40;
        const targetIndex = 20;
        double widthOf(int i) => raggedExtent(i, base: 33.0);

        final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100));
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                scrollDirection: Axis.horizontal,
                reverse: true,
                padding: const EdgeInsets.only(left: 60.0, right: paddingRight),
                itemCount: itemCount,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(
                      width: widthOf(index), child: Text('Item $index')),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final viewport = controller.position.viewportDimension;
        final leadingPadding = controller.leadingAxisPaddingForTesting;

        await pumpUntilComplete(
          tester,
          controller.scrollTo(targetIndex.toDouble(),
              duration: const Duration(milliseconds: 100), alignment: 0.0),
        );

        final expected = expectedOffset(
          extentOf: widthOf,
          targetIndex: targetIndex,
          fraction: 0.0,
          viewportExtent: viewport,
          alignment: 0.0,
          leadingPadding: leadingPadding,
        );
        expect(controller.position.pixels, closeTo(expected, 1.0));
        expect(leadingPadding, closeTo(paddingRight, 0.5));
      },
    );

    testWidgets(
      'reverse: user gesture still cancels an in-flight scrollTo with ScrollCancelReason.userGesture',
      (WidgetTester tester) async {
        const itemCount = 200;
        double heightOf(int i) => raggedExtent(i, base: 28.0);

        final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 300));
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: IndexedScrollGestureDetector(
                controller: controller,
                child: ListView.builder(
                  controller: controller,
                  reverse: true,
                  itemCount: itemCount,
                  itemBuilder: (context, index) => controller.watch(
                    index: index,
                    child: SizedBox(
                        height: heightOf(index), child: Text('Item $index')),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        Object? error;
        unawaited(
          controller.scrollTo(150.0).catchError((Object e) {
            error = e;
            return null;
          }),
        );
        await tester.pump(const Duration(milliseconds: 16));

        // Under reverse: true a drag toward the bottom of the screen
        // (positive dy) increases controller.offset -- the mirror image of
        // the non-reversed case (test/scroll_user_drag_priority_test.dart
        // drags by negative dy) -- confirmed empirically against this
        // widget. The gesture-priority mechanism itself does not care about
        // sign; this only affects which direction this test's drag uses.
        final gesture = await tester.startGesture(const Offset(200, 300));
        await tester.pump();
        final before = controller.offset;
        for (var i = 0; i < 5; i++) {
          await gesture.moveBy(const Offset(0, 40));
          await tester.pump();
        }
        final moved = controller.offset - before;
        await gesture.up();
        await tester.pumpAndSettle();

        expect(
          moved,
          closeTo(200.0, 1.0),
          reason: 'The drag must keep moving the reversed list exactly as it '
              'would a non-reversed one -- gesture priority does not depend '
              'on axis direction.',
        );
        expect(error, isA<ScrollCancelledException>());
        expect((error! as ScrollCancelledException).reason,
            ScrollCancelReason.userGesture);
      },
    );

    testWidgets(
      'reverse + fingerprint mode: selective remeasurement recovers two changed rows without a full reset',
      (WidgetTester tester) async {
        const itemCount = 40;
        const firstChangedIndex = 3;
        const unchangedIndex = 12;
        const secondChangedIndex = 20;
        const targetIndex = 30;

        double baseHeight(int i) => raggedExtent(i, base: 24.0);
        final heights = List<double>.generate(itemCount, baseHeight);
        final fingerprints = List<int>.filled(itemCount, 0);
        late StateSetter rebuild;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
          itemCount: () => itemCount,
          contentFingerprint: (index) => fingerprints[index],
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: 220,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return ListView.builder(
                      controller: controller,
                      reverse: true,
                      itemCount: itemCount,
                      itemBuilder: (context, index) => controller.watch(
                        index: index,
                        child: SizedBox(
                            height: heights[index], child: Text('row $index')),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final initialScroll = controller.scrollTo(targetIndex.toDouble(),
            duration: Duration.zero);
        await tester.pumpAndSettle();
        await initialScroll;
        final generationBeforeRecovery = controller.measurementGeneration;
        expect(
            controller.measurementsSizes.containsKey(unchangedIndex), isTrue);

        const firstDelta = 55.0;
        const secondDelta = -9.0;
        rebuild(() {
          heights[firstChangedIndex] =
              baseHeight(firstChangedIndex) + firstDelta;
          fingerprints[firstChangedIndex] = 1;
          heights[secondChangedIndex] =
              baseHeight(secondChangedIndex) + secondDelta;
          fingerprints[secondChangedIndex] = 1;
        });
        await tester.pumpAndSettle();

        final recovery = controller.scrollTo(targetIndex.toDouble(),
            duration: Duration.zero);
        await tester.pumpAndSettle();
        await recovery;

        final expected = expectedOffset(
          extentOf: (i) => heights[i],
          targetIndex: targetIndex,
          fraction: 0.0,
          viewportExtent: controller.position.viewportDimension,
          alignment: 0.0,
        );
        expect(
          controller.position.pixels,
          closeTo(expected, 1.5),
          reason: 'The reverse-list recovered offset must equal the sum of '
              'current (post-mutation) row heights, computed the same way '
              'as the non-reversed selective-remeasurement acceptance test.',
        );
        expect(
          controller.measurementGeneration,
          generationBeforeRecovery,
          reason: 'A fingerprint mismatch must not clear the whole cache '
              'under reverse: true either -- selective recovery must stay '
              'selective regardless of axis direction.',
        );
      },
    );
  });
}
