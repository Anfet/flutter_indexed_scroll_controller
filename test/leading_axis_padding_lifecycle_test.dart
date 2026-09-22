import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group('ISC-62: leading axis padding self-maintains across the layout lifecycle', () {
    testWidgets(
      'reads zero before the first frame and the correct value after it',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        // Before pumpWidget, no row has ever laid out -- confirms the
        // documented "no padding" default rather than an uninitialized or
        // stale value.
        expect(controller.leadingAxisPaddingForTesting, 0.0);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                padding: const EdgeInsets.only(top: 33.0),
                itemCount: 20,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(height: 50.0, child: Text('Item $index')),
                ),
              ),
            ),
          ),
        );

        // Still unset immediately after pumpWidget returns is not
        // asserted -- pumpWidget itself drives a full frame, including
        // layout, so by the time it returns the first row has already laid
        // out and registered its padding. This is the observable contract
        // callers depend on: padding is available "after the first frame".
        await tester.pump();

        expect(
          controller.leadingAxisPaddingForTesting,
          33.0,
          reason: 'After the first completed layout, the controller must '
              'reflect the SliverPadding actually in effect.',
        );
      },
    );

    testWidgets(
      'updates after padding changes at runtime, once invalidateMeasurements() forces a relayout',
      (WidgetTester tester) async {
        // A leading-padding-only change does not by itself change any row's
        // BoxConstraints (padding shifts the sliver's own scroll-offset
        // math, not the constraints it hands to its children), so Flutter's
        // ordinary dirty-layout tracking does not re-run performLayout() on
        // already-laid-out rows purely because padding changed -- confirmed
        // empirically: registrationCountFor(0) does not increase from a
        // padding-only rebuild alone. This is the same category of change
        // invalidateMeasurements()'s own Dartdoc already documents (e.g.
        // switching scrollDirection): a layout-affecting change the
        // controller cannot detect on its own, so the caller must call
        // invalidateMeasurements() after changing `padding` at runtime, same
        // as after any other such mutation.
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        late StateSetter setPadding;
        var padding = const EdgeInsets.only(top: 10.0);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  setPadding = setState;
                  return ListView.builder(
                    controller: controller,
                    padding: padding,
                    itemCount: 20,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(height: 50.0, child: Text('Item $index')),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(controller.leadingAxisPaddingForTesting, 10.0);

        setPadding(() {
          padding = const EdgeInsets.only(top: 77.0);
        });
        controller.invalidateMeasurements();
        await tester.pumpAndSettle();

        expect(
          controller.leadingAxisPaddingForTesting,
          77.0,
          reason: 'Once invalidateMeasurements() forces every live row '
              'through a fresh performLayout(), the next registration '
              'picks up the new padding value, self-maintaining from that '
              'point on with no separate padding-specific mechanism.',
        );
      },
    );
  });
}
