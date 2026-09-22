import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group('ISC-14: scrollTo edge cases and clamping', () {
    // Scenario 1: scrollTo(0.5, alignment: 1) -> offset 0
    // Already observed as correct clamping behavior at list start.
    testWidgets(
      'scrollTo(0.5, alignment: 1) clamps to offset 0 at list start',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 5,
                itemBuilder: (context, i) {
                  return controller.watch(
                    index: i,
                    child: SizedBox(
                      height: 100.0,
                      child: Text('Item $i'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Item 0 at top. scrollTo(0.5) = halfway through item 0.
        // alignment=1 means item bottom aligned to viewport bottom.
        // Formula: targetPixels = 0 + 50 + (-(viewport-100)*1) = -450
        // Clamped to 0
        final future = controller.scrollTo(0.5, alignment: 1.0);
        await tester.pumpAndSettle();
        await future;

        expect(controller.position.pixels, 0.0, reason: 'scrollTo(0.5, alignment: 1) should clamp to offset 0');
      },
    );

    // Scenario 2: Fractional index at the last element
    testWidgets(
      'scrollTo with fractional index at last element clamps correctly',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 10,
                itemBuilder: (context, i) {
                  return controller.watch(
                    index: i,
                    child: SizedBox(
                      height: 100.0,
                      child: Text('Item $i'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final future = controller.scrollTo(9.5, alignment: 0.0);
        await tester.pumpAndSettle();
        await future;

        final offset = controller.position.pixels;
        expect(offset, lessThanOrEqualTo(controller.position.maxScrollExtent), reason: 'scrollTo(9.5) should clamp to maxScrollExtent');
        expect(offset, greaterThanOrEqualTo(0.0));
      },
    );

    // Scenario 3: Zero duration
    testWidgets(
      'scrollTo with duration: Duration.zero jumps immediately',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 10,
                itemBuilder: (context, i) {
                  return controller.watch(
                    index: i,
                    child: SizedBox(
                      height: 100.0,
                      child: Text('Item $i'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(controller.position.pixels, 0.0);

        // The default test viewport (600) already lays out and measures
        // items 0-8 during the initial pumpAndSettle above (10 items * 100px
        // = 1000px of content only partly fits), so index 5 is already known
        // before scrollTo runs and Duration.zero's jumpTo path does not need
        // a multi-frame search pass to reach it.
        //
        // The raw offset formula puts index 5 at 5 * 100 = 500, but 1000px of
        // content in a 600px viewport caps maxScrollExtent at 400 -- 500 is
        // past the physical end of the list and no amount of scrolling can
        // show it. This assertion previously read 500.0 because it sampled
        // position.pixels inside the one-frame window before Flutter's own
        // layout correction pulled the position back to the bound; the
        // scrollable always settled at 400. scrollTo() now clamps the final
        // target itself, so the documented "physical list bounds take
        // priority over the requested alignment" contract holds at the
        // moment the Future resolves rather than a frame later.
        final future = controller.scrollTo(5.0, duration: Duration.zero);
        await tester.pump(); // One frame to process jumpTo
        await future;

        expect(controller.position.pixels, 400.0,
            reason: 'scrollTo(5.0, duration: Duration.zero) should jump '
                'straight to the clamped target for index 5: the raw offset '
                '(500) is beyond maxScrollExtent (400), and the position '
                'must already be in bounds when the Future resolves');
        expect(controller.position.pixels, controller.position.maxScrollExtent);
      },
    );

    // Scenario 4: Negative duration
    testWidgets(
      'scrollTo with negative duration throws ArgumentError',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 10,
                itemBuilder: (context, i) {
                  return controller.watch(
                    index: i,
                    child: SizedBox(
                      height: 100.0,
                      child: Text('Item $i'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          () => controller.scrollTo(5.0, duration: const Duration(milliseconds: -50)),
          throwsA(isA<ArgumentError>()),
          reason: 'Negative duration must throw ArgumentError',
        );
      },
    );

    // Scenario 5: NaN in scrollToIndex
    testWidgets(
      'scrollTo(double.nan) throws ArgumentError',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 10,
                itemBuilder: (context, i) {
                  return controller.watch(
                    index: i,
                    child: SizedBox(
                      height: 100.0,
                      child: Text('Item $i'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          () => controller.scrollTo(double.nan),
          throwsA(isA<ArgumentError>()),
          reason: 'NaN scrollToIndex must throw ArgumentError',
        );
      },
    );

    // Scenario 6: Infinite scrollToIndex
    testWidgets(
      'scrollTo(double.infinity) throws ArgumentError',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 10,
                itemBuilder: (context, i) {
                  return controller.watch(
                    index: i,
                    child: SizedBox(
                      height: 100.0,
                      child: Text('Item $i'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          () => controller.scrollTo(double.infinity),
          throwsA(isA<ArgumentError>()),
          reason: 'Infinite scrollToIndex must throw ArgumentError',
        );
      },
    );

    // Scenario 7: Negative alignment
    testWidgets(
      'scrollTo with alignment < 0 throws ArgumentError',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 10,
                itemBuilder: (context, i) {
                  return controller.watch(
                    index: i,
                    child: SizedBox(
                      height: 100.0,
                      child: Text('Item $i'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          () => controller.scrollTo(5.0, alignment: -0.5),
          throwsA(isA<ArgumentError>()),
          reason: 'Negative alignment must throw ArgumentError',
        );
      },
    );

    // Scenario 8: Alignment > 1
    testWidgets(
      'scrollTo with alignment > 1 throws ArgumentError',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 10,
                itemBuilder: (context, i) {
                  return controller.watch(
                    index: i,
                    child: SizedBox(
                      height: 100.0,
                      child: Text('Item $i'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          () => controller.scrollTo(5.0, alignment: 1.5),
          throwsA(isA<ArgumentError>()),
          reason: 'Alignment > 1 must throw ArgumentError',
        );
      },
    );

    // Scenario 9: Two attached positions (ISC-03 gap: "add test on positions.length != 1")
    testWidgets(
      'scrollTo with two attached ScrollPositions throws StateError',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      controller: controller,
                      itemCount: 10,
                      itemBuilder: (context, i) {
                        return controller.watch(
                          index: i,
                          child: SizedBox(
                            height: 100.0,
                            child: Text('View1 Item $i'),
                          ),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: controller,
                      itemCount: 10,
                      itemBuilder: (context, i) {
                        return controller.watch(
                          index: i,
                          child: SizedBox(
                            height: 100.0,
                            child: Text('View2 Item $i'),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(controller.positions.length, 2, reason: 'Controller should have 2 positions');

        expect(
          () => controller.scrollTo(5.0),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('exactly one'),
          )),
          reason: 'scrollTo with 2 positions must throw StateError',
        );
      },
    );

    // Scenario 10: Viewport size changes between two scrollTo calls.
    //
    // scrollTo reads position.viewportDimension fresh at the start of each
    // call (it is not cached across calls), so a resize between calls must
    // be picked up by the next call rather than reusing a stale value from
    // the first one.
    testWidgets(
      'scrollTo picks up a viewport resize that happens between calls',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        double viewportHeight = 300;
        late StateSetter setViewportState;

        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                setViewportState = setState;
                return Scaffold(
                  body: SizedBox(
                    height: viewportHeight,
                    child: ListView.builder(
                      controller: controller,
                      itemCount: 20,
                      itemBuilder: (context, i) {
                        return controller.watch(
                          index: i,
                          child: SizedBox(height: 100.0, child: Text('Item $i')),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(controller.position.viewportDimension, 300.0);

        // alignment: 0 puts the item's top at the viewport's top, so this
        // target offset (5 * 100 = 500) does not itself depend on
        // viewportSize; it isolates whether a resize is observed at all
        // from whether the alignment formula reacts to it (scenario 11
        // covers the latter, via alignment: 1).
        final firstScroll = controller.scrollTo(5.0, alignment: 0.0);
        await tester.pumpAndSettle();
        await firstScroll;
        expect(controller.position.pixels, 500.0);

        setViewportState(() {
          viewportHeight = 600;
        });
        await tester.pumpAndSettle();
        expect(controller.position.viewportDimension, 600.0, reason: 'Resize must be reflected before the next scrollTo call');

        // alignment: 1 puts the item's bottom at the viewport's bottom, so
        // its target offset is priorItems - (viewportSize - height)
        // = 500 - (600 - 100) = 0: this value is only correct if scrollTo
        // re-read the resized viewportDimension (600) rather than reusing
        // the 300 captured by the first call (which would instead give
        // 500 - (300 - 100) = 300).
        final secondScroll = controller.scrollTo(5.0, alignment: 1.0);
        await tester.pumpAndSettle();
        await secondScroll;
        expect(controller.position.pixels, 0.0,
            reason: 'scrollTo must use the resized viewport (600), not the '
                'stale one (300) from the previous call, when computing the '
                'alignment: 1 offset');
      },
    );

    // Scenario 10b: Viewport shrinks while a scrollTo search pass is still
    // in flight (mid-animation, not just between calls).
    //
    // The library captures viewportSize once per scrollTo call and only uses
    // it to size search steps during the multi-frame measurement pass; the
    // final target offset is recomputed from measured item heights once the
    // target is found, independent of the viewport at that moment. This
    // regression test locks in that a mid-flight resize does not hang, throw,
    // or desync the search - the call still completes and settles on the
    // exact expected offset for a distant target once the shrink happens.
    testWidgets(
      'scrollTo tolerates a viewport shrink mid-search and reaches the exact target',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 300),
        );
        addTearDown(controller.dispose);

        double viewportHeight = 300;
        late StateSetter setViewportState;

        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                setViewportState = setState;
                return Scaffold(
                  body: SizedBox(
                    height: viewportHeight,
                    child: ListView.builder(
                      controller: controller,
                      itemCount: 100,
                      itemBuilder: (context, i) {
                        return controller.watch(
                          index: i,
                          child: SizedBox(height: 100.0, child: Text('Item $i')),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        final future = controller.scrollTo(80.0, alignment: 0.0);
        // Let the search pass begin (a couple of steps at viewportSize=300)
        // before shrinking the viewport out from under it.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));

        setViewportState(() {
          viewportHeight = 150;
        });
        await tester.pumpAndSettle();
        await future;

        expect(controller.position.pixels, 8000.0,
            reason: 'scrollTo should still land exactly on index 80 (80 * '
                '100) after the viewport shrinks mid-search, not hang or '
                'throw');
      },
    );

    // Scenario 11: ListView padding.
    //
    // ISC-63: the offset formula in _runAnimateTo/scrollTo now adds
    // _leadingAxisPadding (the resolved leading-side EdgeInsets read off the
    // ListView's SliverPadding, see indexed_scroll_item.dart) to the summed
    // item extents, closing the gap between position.pixels (viewport-
    // relative) and the prior priorItems-only sum (content-relative). This
    // test now locks in the FIXED behavior: a symmetric padding.top/bottom
    // shifts the target by exactly padding.top, and padding.bottom (a
    // trailing/"after" inset) must not affect it at all.
    testWidgets(
      'scrollTo accounts for ListView padding when computing the target offset',
      (WidgetTester tester) async {
        final controllerNoPadding = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controllerNoPadding.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controllerNoPadding,
                itemCount: 20,
                itemBuilder: (context, i) {
                  return controllerNoPadding.watch(
                    index: i,
                    child: SizedBox(height: 100.0, child: Text('Item $i')),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final noPaddingScroll = controllerNoPadding.scrollTo(5.0, alignment: 0.0);
        await tester.pumpAndSettle();
        await noPaddingScroll;
        expect(controllerNoPadding.position.pixels, 500.0, reason: 'Baseline without padding: offset is exactly 5 * 100');

        final controllerWithPadding = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controllerWithPadding.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controllerWithPadding,
                padding: const EdgeInsets.symmetric(vertical: 50),
                itemCount: 20,
                itemBuilder: (context, i) {
                  return controllerWithPadding.watch(
                    index: i,
                    child: SizedBox(height: 100.0, child: Text('Item $i')),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final paddedScroll = controllerWithPadding.scrollTo(5.0, alignment: 0.0);
        await tester.pumpAndSettle();
        await paddedScroll;

        // The 50px top pad shifts every item's actual position in the
        // scrollable's coordinate space down by 50px, so the correct target
        // is 500 + 50 (padding.top) = 550. padding.bottom (a trailing
        // inset) must not contribute -- only the leading side does.
        expect(controllerWithPadding.position.pixels, 550.0,
            reason: 'scrollTo must account for the ListView\'s leading '
                'padding (padding.top = 50): the target is 500 + 50 = 550, '
                'not the unpadded 500.0. The trailing padding.bottom (also '
                '50) must not affect the offset at all.');
      },
    );
  });
}
