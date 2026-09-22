import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group(
    'ISC-40: reordering with watch(index: slotPosition) -- the CORRECT usage under '
    'ISC-27\'s contract -- reaches the exact new offset with no StateError',
    () {
      // This is the positive-branch counterpart to
      // test/scroll_to_mutated_data_test.dart's scenario A (and
      // render_object_registration_test.dart test 3 / scroll_watch_index_order_test.dart
      // tests 1/2/4): those tests all deliberately pass watch(index: logicalIndex) --
      // a stable content id that moves between physical slots on reorder -- to prove
      // ISC-28's mismatch detector rejects that misuse with StateError.
      //
      // This test does the opposite: after the reorder, itemBuilder still calls
      // watch(index: slotPosition), i.e. the same value ListView.builder passes as its
      // own `index` parameter -- the row's physical slot, not any stored content id.
      // Under ISC-27's contract ("watch(index:) must equal the row's physical slot"),
      // that is not a mismatch at all: every row's watch(index:) always equals its own
      // SliverMultiBoxAdaptorParentData.index by construction, reorder or not. So
      // invalidateMeasurements() followed immediately by scrollTo() (no external
      // jumpTo(0), per ISC-30/31's recovery contract) must complete successfully and
      // land on the exact offset implied by the NEW post-reorder height order.
      testWidgets(
        'reorder + invalidateMeasurements() + immediate scrollTo() lands on the exact '
        'post-reorder offset, no StateError',
        (WidgetTester tester) async {
          const itemCount = 5;
          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );

          // Same heights as scroll_to_mutated_data_test.dart scenario A, so the
          // arithmetic below is directly comparable to that test's documented
          // buggy/StateError numbers (360.0 / 750.0 for the negative branch).
          final heights = [100.0, 260.0, 310.0, 150.0, 240.0]; // sum = 1060
          List<int> currentOrder = [0, 1, 2, 3, 4];
          late StateSetter setOrder;

          // A viewport shorter than the total content (1060px) is required: the
          // default test surface is 800x600, and 600 alone would leave only 460px of
          // maxScrollExtent -- less than the 750.0px target offset computed below, so
          // scrollTo(4) would silently clamp to maxScrollExtent instead of reaching
          // the intended offset. 200px keeps maxScrollExtent (860px) comfortably above
          // every offset this test probes.
          const viewportHeight = 200.0;

          Widget buildList() {
            return MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: viewportHeight,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      setOrder = setState;
                      return ListView.builder(
                        controller: controller,
                        itemCount: itemCount,
                        itemBuilder: (context, slotPosition) {
                          // CORRECT usage: watch(index: slotPosition) always equals the
                          // builder's own `index` argument -- the row's physical slot --
                          // regardless of which logical/content row currently occupies
                          // that slot. This is what makes this the positive-branch test:
                          // there is no stored id being threaded through watch(); the
                          // identity that travels with the row is looked up ONLY to pick
                          // the height/label, never passed to watch().
                          final logicalIndex = currentOrder[slotPosition];
                          return controller.watch(
                            index: slotPosition,
                            child: Container(
                              height: heights[logicalIndex],
                              color: Colors.teal,
                              child: Center(
                                  child: Text(
                                      'slot=$slotPosition logical=$logicalIndex')),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            );
          }

          // Step 1: render and fully measure the original order [0,1,2,3,4] --
          // watch(index: slotPosition) with slotPosition == logicalIndex here, so this
          // step also matches the "before" half of scenario A byte-for-byte.
          await tester.pumpWidget(buildList());
          await tester.pumpAndSettle();

          unawaited(controller.scrollTo(4.0,
              duration: const Duration(milliseconds: 100)));
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          var measurements = controller.measurementsSizes;
          expect(
            measurements.length,
            equals(itemCount),
            reason: 'All 5 slots must be measured before the reorder.',
          );
          expect(measurements[0]?.height, closeTo(100.0, 1.0));
          expect(measurements[1]?.height, closeTo(260.0, 1.0));
          expect(measurements[2]?.height, closeTo(310.0, 1.0));
          expect(measurements[3]?.height, closeTo(150.0, 1.0));
          expect(measurements[4]?.height, closeTo(240.0, 1.0));

          controller.jumpTo(0.0);
          await tester.pumpAndSettle();

          // Step 2: reorder the underlying data -- same currentOrder swap as scenario
          // A -- so logical index 4 (h=240) now shows at slot 0, etc. Because
          // itemBuilder always calls watch(index: slotPosition), no row's watch()
          // value changes identity: slot 0 still calls watch(index: 0), it just now
          // renders different content (logical 4 instead of logical 0) at a different
          // height (240 instead of 100).
          setOrder(() {
            currentOrder = [4, 3, 0, 1, 2];
          });
          await tester.pumpAndSettle();

          // Post-reorder, per-slot heights (indexed by physical slot, i.e. what
          // watch(index:) now means for measurement purposes) are:
          //   slot 0 -> logical 4 -> 240.0
          //   slot 1 -> logical 3 -> 150.0
          //   slot 2 -> logical 0 -> 100.0
          //   slot 3 -> logical 1 -> 260.0
          //   slot 4 -> logical 2 -> 310.0
          // Because watch(index: slotPosition) never mismatches
          // SliverMultiBoxAdaptorParentData.index (it IS that index by construction),
          // ISC-28's _watchIndexMismatches stays empty throughout -- there is nothing
          // for _checkNoWatchIndexMismatch to reject.

          // Step 3: invalidate, then IMMEDIATELY scrollTo() -- no external jumpTo(0),
          // matching ISC-30/31's recovery contract (the controller performs its own
          // internal jumpTo(0) + forward search when the 0..target prefix is
          // incomplete after invalidation).
          controller.invalidateMeasurements();

          // Target: slot 4 (the last slot). Expected offset is the sum of the NEW
          // per-slot heights for slots 0..3:
          //   240.0 (slot 0) + 150.0 (slot 1) + 100.0 (slot 2) + 260.0 (slot 3)
          //   = 750.0 px
          // This is exactly the "true visual offset" number scenario A's own comment
          // computes and explicitly rejects via StateError for the buggy
          // watch(index: logicalIndex) pattern -- here, with the correct
          // watch(index: slotPosition) pattern, scrollTo() must reach that same
          // 750.0 px successfully instead.
          const expectedOffset = 240.0 + 150.0 + 100.0 + 260.0; // 750.0

          Object? scrollError;
          bool scrollCompleted = false;
          unawaited(
            controller
                .scrollTo(4.0, duration: const Duration(milliseconds: 100))
                .then(
              (_) => scrollCompleted = true,
              onError: (Object e) {
                scrollError = e;
                scrollCompleted = true;
              },
            ),
          );

          for (int i = 0; i < 300 && !scrollCompleted; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          expect(
            scrollCompleted,
            isTrue,
            reason:
                'scrollTo() must settle (success or error) within the frame budget.',
          );
          expect(
            scrollError,
            isNull,
            reason:
                'ISC-27\'s contract: watch(index: slotPosition) always equals the row\'s '
                'physical position, reorder or not, so ISC-28\'s mismatch check must stay '
                'a no-op here -- this scrollTo() must NOT throw StateError.',
          );
          expect(
            controller.position.pixels,
            closeTo(expectedOffset, 1.0),
            reason:
                'scrollTo(4) after the reorder must land on the offset implied by the '
                'NEW post-reorder height order (240+150+100+260 = 750.0 px), computed '
                'purely from the correctly-updated positional watch(index:) values.',
          );
        },
      );
    },
  );
}
