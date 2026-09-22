import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';
import 'support/scroll_harness.dart';

void main() {
  group('ISC-67: visual alignment semantics for reverse: true', () {
    // ScrollHarness has no `reverse` parameter (and this task does not add
    // one), so these tests build the ListView.builder directly, mirroring
    // the harness's own build() but with reverse: true.
    Future<IndexedScrollController> pumpReverseVertical(
      WidgetTester tester, {
      required int itemCount,
      required double itemHeight,
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
              itemCount: itemCount,
              itemBuilder: (context, index) => controller.watch(
                index: index,
                child: SizedBox(height: itemHeight, child: Text('Item $index')),
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
      required double itemWidth,
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
                child: SizedBox(width: itemWidth, child: Text('Item $index')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    // priorItems/_leadingAxisPadding are unaffected by reverse (SliverList
    // does not invert indices, see the package's Dartdoc), so every expected
    // offset below still sums `targetIndex * itemExtent` exactly as the
    // non-reversed tests do. The only change under reverse is which side of
    // the viewport `alignment` measures from: effectiveAlignment =
    // 1.0 - alignment, so alignment=0 keeps meaning "visual start of the
    // list" (here, the bottom/right edge, where reverse's index 0 sits)
    // instead of flipping to mean "visual end".

    for (final alignment in [0.0, 0.5, 1.0]) {
      testWidgets(
        'vertical reverse: alignment=$alignment lands at the effectiveAlignment offset',
        (WidgetTester tester) async {
          const itemHeight = 60.0;
          const targetIndex = 20;

          final controller = await pumpReverseVertical(
            tester,
            itemCount: 40,
            itemHeight: itemHeight,
          );
          final viewportHeight = controller.position.viewportDimension;

          await pumpUntilComplete(
            tester,
            controller.scrollTo(
              targetIndex.toDouble(),
              duration: const Duration(milliseconds: 100),
              alignment: alignment,
            ),
          );

          // effectiveAlignment = 1.0 - alignment (reverse: true).
          // targetPixels = priorItems + alignmentAdjust
          //              = targetIndex * itemHeight
          //                - (viewportHeight - itemHeight) * (1.0 - alignment)
          final effectiveAlignment = 1.0 - alignment;
          final expected = targetIndex * itemHeight - (viewportHeight - itemHeight) * effectiveAlignment;
          expect(
            controller.position.pixels,
            closeTo(expected, 1.0),
            reason: 'Under reverse: true, alignment=$alignment must resolve '
                'through effectiveAlignment=$effectiveAlignment (1.0 - '
                'alignment), so alignment=0 keeps meaning the visual start '
                'of the list rather than flipping to the visual end. A '
                'formula that instead used raw alignment=$alignment here, '
                'or that additionally inverted priorItems, would land at a '
                'different, wrong offset.',
          );
        },
      );

      testWidgets(
        'horizontal reverse: alignment=$alignment lands at the effectiveAlignment offset',
        (WidgetTester tester) async {
          const itemWidth = 70.0;
          const targetIndex = 25;

          final controller = await pumpReverseHorizontal(
            tester,
            itemCount: 40,
            itemWidth: itemWidth,
          );
          final viewportWidth = controller.position.viewportDimension;

          await pumpUntilComplete(
            tester,
            controller.scrollTo(
              targetIndex.toDouble(),
              duration: const Duration(milliseconds: 100),
              alignment: alignment,
            ),
          );

          final effectiveAlignment = 1.0 - alignment;
          final expected = targetIndex * itemWidth - (viewportWidth - itemWidth) * effectiveAlignment;
          expect(
            controller.position.pixels,
            closeTo(expected, 1.0),
            reason: 'Under reverse: true on the horizontal axis, '
                'alignment=$alignment must resolve through '
                'effectiveAlignment=$effectiveAlignment (1.0 - alignment), '
                'the same visual semantics as the vertical case above.',
          );
        },
      );
    }

    testWidgets(
      'vertical reverse: fractional index combines effectiveAlignment with the fast path',
      (WidgetTester tester) async {
        const itemHeight = 50.0;

        final controller = await pumpReverseVertical(
          tester,
          itemCount: 60,
          itemHeight: itemHeight,
        );
        final viewportHeight = controller.position.viewportDimension;

        // Warm the already-measured fast path first, mirroring the
        // non-reversed horizontal tests' pattern, so this exercises
        // scrollTo's fast-path formula rather than the search loop.
        await pumpUntilComplete(
          tester,
          controller.scrollTo(20.0, duration: const Duration(milliseconds: 100)),
        );
        expect(controller.measurementsSizes.containsKey(20), isTrue);

        const alignment = 0.5;
        await pumpUntilComplete(
          tester,
          controller.scrollTo(
            12.5,
            duration: const Duration(milliseconds: 100),
            alignment: alignment,
          ),
        );

        const effectiveAlignment = 1.0 - alignment; // 0.5, self-symmetric
        final expected = 12 * itemHeight + itemHeight * 0.5 - (viewportHeight - itemHeight) * effectiveAlignment;
        expect(
          controller.position.pixels,
          closeTo(expected, 1.0),
          reason: 'A fractional target on the already-measured fast path '
              'must apply the same effectiveAlignment correction as the '
              'search-loop path exercised by the other tests in this file, '
              'so the two formula sites stay identical under reverse.',
        );
      },
    );
  });
}
