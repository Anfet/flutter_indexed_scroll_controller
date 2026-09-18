import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group('ISC-10/ISC-11: RenderObject registration with index/controller changes', () {
    // The core issue: IndexedScrollItem.createRenderObject() creates _RenderIndexedScrollItem
    // with final fields `index` and `controller`. There is no updateRenderObject() override,
    // so when Flutter framework reuses an existing RenderObject (e.g. via GlobalKey),
    // the old index/controller are never updated. performLayout() then registers the old
    // index, not the new one that the widget now carries.
    //
    // ISC-11 implemented updateRenderObject() (mutable index/controller fields plus
    // markNeedsLayout()), so the tests below now assert the fixed behavior: the reused
    // RenderObject picks up the new index/controller and registers under it.

    testWidgets(
      'changing index on same IndexedScrollItem with GlobalKey registers under new index (ISC-11 fix)',
      (WidgetTester tester) async {
        // Setup: use a GlobalKey to force Flutter to reuse the same RenderObject
        // even when we rebuild the IndexedScrollItem widget with a different index.
        const rowHeight = 100.0;
        const itemCount = 20;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        // GlobalKey to force RenderObject reuse
        final trackedItemKey = GlobalKey();

        // Wrapper that rebuilds the watched item with a changing index,
        // while keeping the same GlobalKey to force RenderObject reuse.
        late StateSetter setItemIndex;
        int currentItemIndex = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  setItemIndex = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        // This is our tracked item with GlobalKey
                        return controller.watch(
                          index: currentItemIndex,
                          child: Container(
                            key: trackedItemKey,
                            height: rowHeight,
                            color: Colors.blue,
                            child: Center(
                              child: Text('Tracked Item (index=$currentItemIndex)'),
                            ),
                          ),
                        );
                      } else {
                        return Container(
                          height: rowHeight,
                          color: Colors.grey,
                          child: Center(child: Text('Item $index')),
                        );
                      }
                    },
                  );
                },
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Snapshot 1: initial state, currentItemIndex = 0
        var measurements = controller.measurementsSizes;
        expect(
          measurements.containsKey(0),
          isTrue,
          reason: 'Initial state should have measured index 0',
        );

        // Now change currentItemIndex to 5 by rebuilding the widget tree,
        // but the RenderObject (with GlobalKey at index 0 in the list) will be reused
        setItemIndex(() {
          currentItemIndex = 5;
        });
        await tester.pumpAndSettle();

        // Snapshot 2: after changing currentItemIndex to 5
        measurements = controller.measurementsSizes;

        // FIXED (ISC-11): updateRenderObject() now updates the reused RenderObject's
        // mutable `index` field to 5 and calls markNeedsLayout(), so performLayout()
        // runs again and registers under the new logical index 5. The old entry at
        // index 0 is left in _sizes untouched (ordinary reuse does not erase history;
        // that is a distinct data structure from the live-owner tracking that would
        // fire on an actual unmount), so it is still present too.

        expect(
          measurements.containsKey(0),
          isTrue,
          reason: 'ISC-11: the earlier measurement at index 0 is retained in _sizes; '
              'updateRenderObject() only changes what the *live* RenderObject '
              'registers going forward, it does not purge prior history.',
        );

        expect(
          measurements.containsKey(5),
          isTrue,
          reason: 'ISC-11 fix: updateRenderObject() updates the reused RenderObject\'s '
              'mutable index field to 5 and calls markNeedsLayout(), so the next '
              'performLayout() registers under the new logical index 5.',
        );
      },
    );

    testWidgets(
      'changing controller on same IndexedScrollItem registers in new controller (ISC-11 fix)',
      (WidgetTester tester) async {
        // Setup: have two controllers and switch between them while keeping
        // the IndexedScrollItem widget key the same (or at same position in tree).
        const rowHeight = 100.0;
        const itemCount = 10;

        final controller1 = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        final controller2 = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        late StateSetter setActiveController;
        IndexedScrollController activeController = controller1;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  setActiveController = setState;
                  return ListView.builder(
                    controller: activeController,
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        // Watched item with key to potentially force RenderObject reuse
                        return activeController.watch(
                          index: index,
                          child: Container(
                            height: rowHeight,
                            color: Colors.red,
                            child: const Center(
                              child: Text('Item 0 (controller-tracked)'),
                            ),
                          ),
                        );
                      } else {
                        return Container(
                          height: rowHeight,
                          color: Colors.yellow,
                          child: Center(child: Text('Item $index')),
                        );
                      }
                    },
                  );
                },
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Snapshot 1: controller1 is active, should have measured index 0
        expect(
          controller1.measurementsSizes.containsKey(0),
          isTrue,
          reason: 'controller1 should have measured index 0 initially',
        );

        expect(
          controller2.measurementsSizes.containsKey(0),
          isFalse,
          reason: 'controller2 should not have measurements yet',
        );

        // Now switch to controller2
        setActiveController(() {
          activeController = controller2;
        });
        await tester.pumpAndSettle();

        // Snapshot 2: after switching to controller2
        // FIXED (ISC-11): updateRenderObject() updates the reused RenderObject's
        // mutable `controller` field to controller2 and calls markNeedsLayout(), so
        // the next performLayout() registers with controller2 instead of controller1.

        expect(
          controller2.measurementsSizes.containsKey(0),
          isTrue,
          reason: 'ISC-11 fix: updateRenderObject() updates the reused RenderObject to '
              'hold controller2 and triggers a relayout, so index 0 is now '
              'registered in controller2.',
        );

        expect(
          controller1.measurementsSizes.containsKey(0),
          isTrue,
          reason: 'ISC-11: controller1 keeps its earlier measurement — switching the '
              'live owner to controller2 does not retroactively erase controller1\'s '
              '_sizes history, only the same RenderObject\'s live-owner entry moves.',
        );
      },
    );

    testWidgets(
      'reordering visible rows with same itemCount registers heights under the correct logical index (ISC-11 fix; visual-order scrollTo is ISC-12/13)',
      (WidgetTester tester) async {
        // Reordering with the same itemCount previously gave a silent 30px
        // error and a successful Future.
        //
        // Reproducing the actual bug mechanism (same pattern validated by review for
        // test 1 above) requires the *logical* index passed to watch() to move to a
        // different physical slot than the one it started on, while each physical slot
        // in ListView.builder (identified by its builder position, not by the data it
        // currently displays) keeps reusing the same _RenderIndexedScrollItem. Because
        // that RenderObject's `index` field is final and there is no
        // updateRenderObject(), performLayout() keeps registering measurements under the
        // slot's *original* index, not the logical index the widget now carries.
        //
        // A naive reorder where watch(index: displayIndex) always equals the physical
        // slot (as in the original version of this test) can never expose the bug: the
        // "stale" index is then always identical to the "correct" one. Here, watch() is
        // given the true logical index (currentOrder[slotPosition]), which moves between
        // slots on reorder, so the stale registration and the correct one diverge.

        const itemCount = 5;
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        // Row heights indexed by logical index (total 1000).
        final originalHeights = [100.0, 200.0, 300.0, 150.0, 250.0];
        late StateSetter setRowOrder;
        // currentOrder[slotPosition] = logical index currently shown in that slot.
        List<int> currentOrder = [0, 1, 2, 3, 4];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  setRowOrder = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, slotPosition) {
                      final logicalIndex = currentOrder[slotPosition];
                      final height = originalHeights[logicalIndex];

                      return controller.watch(
                        index: logicalIndex,
                        child: Container(
                          height: height,
                          color: Colors.blue,
                          child: Center(
                            child: Text(
                              'slot=$slotPosition logical=$logicalIndex h=$height',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Snapshot 1: identity order, so slot position equals logical index and
        // measurements match originalHeights exactly.
        var measurements = controller.measurementsSizes;
        expect(measurements.length, equals(itemCount));
        expect(measurements[0]?.height, closeTo(100.0, 1.0));
        expect(measurements[1]?.height, closeTo(200.0, 1.0));
        expect(measurements[2]?.height, closeTo(300.0, 1.0));
        expect(measurements[3]?.height, closeTo(150.0, 1.0));
        expect(measurements[4]?.height, closeTo(250.0, 1.0));

        // Reorder so logical index 2 (height 300, originally at slot 2) moves to
        // slot 4, and every other logical index also changes slot.
        setRowOrder(() {
          currentOrder = [4, 3, 0, 1, 2];
        });
        await tester.pumpAndSettle();

        // Snapshot 2: each physical slot's RenderObject is reused (same identity),
        // and ISC-11's updateRenderObject() now updates its `index` field to the
        // *new* logical index the widget carries at that slot and calls
        // markNeedsLayout(), so performLayout() re-registers under the correct
        // logical index rather than the stale slot position:
        //   slot 0 now shows logical 4 (h=250) -> registers under key 4
        //   slot 1 now shows logical 3 (h=150) -> registers under key 3
        //   slot 2 now shows logical 0 (h=100) -> registers under key 0
        //   slot 3 now shows logical 1 (h=200) -> registers under key 1
        //   slot 4 now shows logical 2 (h=300) -> registers under key 2
        // i.e. measurementsSizes stays keyed by logical index 0..4, matching
        // originalHeights exactly, same as snapshot 1.
        measurements = controller.measurementsSizes;
        expect(measurements.length, equals(itemCount));
        expect(measurements[0]?.height, closeTo(100.0, 1.0));
        expect(measurements[1]?.height, closeTo(200.0, 1.0));
        expect(measurements[2]?.height, closeTo(300.0, 1.0));
        expect(measurements[3]?.height, closeTo(150.0, 1.0));
        expect(measurements[4]?.height, closeTo(250.0, 1.0));

        // Ask to scroll to logical index 2 (height 300).
        //
        // Registration is now correct: _sizes is keyed by true logical index, not
        // stale slot position (asserted above). But watch(index: logicalIndex) here
        // is, per ISC-27's contract, itself a misuse: `watch(index:)` must equal the
        // row's physical slot, not a stable logical/content id that moves between
        // slots on reorder. ISC-28 detects exactly this mismatch (via
        // SliverMultiBoxAdaptorParentData.index, compared against the watch(index:)
        // value at registration) and makes scrollTo() throw StateError before
        // completing, instead of the silent wrong-offset success (300.0 px, not the
        // true 700.0 px) this test originally pinned as an accepted ISC-11-vs-ISC-12
        // scope boundary. Registration correctness (measurements[] above) is
        // unaffected by ISC-28; only scrollTo()'s completion behavior for this
        // specific misuse changed.
        final offsetBeforeAttempt = controller.position.pixels;

        await expectLater(
          controller.scrollTo(
            2.0,
            duration: const Duration(milliseconds: 100),
          ),
          throwsA(isA<StateError>()),
          reason: 'ISC-28: watch(index: 0) was registered by physical slot 2 (a '
              'mismatch), so scrollTo(2) must be rejected before it can sum a '
              'prefix through that mismatched entry, instead of completing at '
              'the logical-order sum of 300.0 px.',
        );

        expect(
          controller.position.pixels,
          equals(offsetBeforeAttempt),
          reason: 'The rejected call must not move the position.',
        );
      },
    );

    testWidgets(
      'same IndexedScrollItem widget, different logical indices via watch(), keeps history while live registration follows the new index (ISC-11)',
      (WidgetTester tester) async {
        // Additional scenario: directly pass different logical indices through watch()
        // to the same widget, and observe that (due to missing updateRenderObject)
        // the measurements get polluted and inconsistent.

        const rowHeight = 100.0;
        const itemCount = 10;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        late StateSetter setLogicalIndex;
        int logicalIndex = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  setLogicalIndex = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        // Always show a widget at position 0, but pass different logical indices
                        return controller.watch(
                          index: logicalIndex,
                          child: Container(
                            height: rowHeight,
                            color: Colors.green,
                            child: Center(
                              child: Text('Logical Index $logicalIndex'),
                            ),
                          ),
                        );
                      } else {
                        return Container(
                          height: rowHeight,
                          color: Colors.grey,
                          child: Center(child: Text('Item $index')),
                        );
                      }
                    },
                  );
                },
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Snapshot 1: logicalIndex = 0
        expect(
          controller.measurementsSizes.containsKey(0),
          isTrue,
          reason: 'Should have measurement for logical index 0',
        );

        // Change logicalIndex to 1
        setLogicalIndex(() {
          logicalIndex = 1;
        });
        await tester.pumpAndSettle();

        // Snapshot 2: logicalIndex = 1
        //
        // ISC-11 contract: updateRenderObject() moves the *live* registration to
        // index 1 (confirmed by the new entry appearing there), but does not erase
        // _sizes[0] — an ordinary index change on a still-mounted row is not an
        // unmount, so the previously measured height at 0 is retained by design
        // An ordinary row removal does not clear its retained measurement.
        // This is not measurement pollution: index 0's value is stale-but-valid
        // history, and index 1 now holds the current live measurement.

        expect(
          controller.measurementsSizes.containsKey(0),
          isTrue,
          reason: 'ISC-11: index 0\'s earlier measurement is retained in _sizes; only '
              'the live-owner tracking moves when the same RenderObject is reused '
              'for a different index, not the measurement history.',
        );
        expect(
          controller.measurementsSizes.containsKey(1),
          isTrue,
          reason: 'ISC-11 fix: updateRenderObject() updates the RenderObject\'s mutable '
              'index field to 1 and calls markNeedsLayout(), so the next '
              'performLayout() registers a fresh measurement under index 1.',
        );

        // Change logicalIndex to 2
        setLogicalIndex(() {
          logicalIndex = 2;
        });
        await tester.pumpAndSettle();

        // Snapshot 3: logicalIndex = 2
        // Same pattern: history at 0 and 1 is retained, and the live registration
        // now follows the same RenderObject to index 2.

        expect(
          controller.measurementsSizes.containsKey(0),
          isTrue,
          reason: 'ISC-11: index 0\'s history is still retained after a second index change.',
        );
        expect(
          controller.measurementsSizes.containsKey(1),
          isTrue,
          reason: 'ISC-11: index 1\'s history is still retained after a second index change.',
        );
        expect(
          controller.measurementsSizes.containsKey(2),
          isTrue,
          reason: 'ISC-11 fix: the live registration keeps following the same '
              'RenderObject as its index keeps changing, landing on index 2 now.',
        );
      },
    );
  });
}
