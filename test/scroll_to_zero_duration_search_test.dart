import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group('ISC-15B: scrollTo with Duration.zero through the search loop', () {
    testWidgets(
      'scrollTo(duration: Duration.zero) on an unmeasured index settles via jumpTo, not animateTo',
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
                itemCount: 200,
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

        // The default test viewport (600) only lays out items 0-5 during the
        // initial pumpAndSettle, so index 80 is far outside what is measured
        // and reaching it must drive the sequential search/measuring loop in
        // _runAnimateTo, not just the final single-step jump.
        expect(controller.measurementsSizes.containsKey(80), isFalse,
            reason: 'Index 80 must start unmeasured so the search loop runs');

        var settled = false;
        final future = controller.scrollTo(80.0, duration: Duration.zero)
          ..then((_) => settled = true);

        // If any search-loop step regresses back to animateTo with
        // duration: Duration.zero, Flutter drives a real
        // DrivenScrollActivity that needs many animation frames to settle.
        // Bound the pump count tightly: jumpTo needs at most one endOfFrame
        // per search step, so this must resolve in a handful of pumps, never
        // by falling back to pumpAndSettle-style unbounded animation frames.
        for (var i = 0; i < 30 && !settled; i++) {
          await tester.pump();
        }

        await future;
        expect(settled, isTrue);

        expect(controller.position.pixels, 8000.0,
            reason: 'scrollTo(80.0, duration: Duration.zero) should settle '
                'exactly at index 80 (80 * 100px)');
        expect(controller.measurementsSizes.containsKey(80), isTrue);
      },
    );
  });
}
