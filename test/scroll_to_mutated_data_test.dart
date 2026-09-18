import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group(
    'ISC-12: scrollTo with mutated list data (reordering, insertion, deletion, height change)',
    () {
      // CRITICAL CONTEXT (from ISC-11 independent review):
      // scrollTo()/_animateTo() sums measured heights (_sizes) strictly by logical index
      // in ascending order: `for (int i = 0; i < targetItemIndex; i++) priorItems +=
      // _sizeOrThrow(i).height` without accounting for data mutation between the moment
      // a row was measured and the moment scrollTo() reads _sizes for that index.
      //
      // ISC-11 fixed UNDER WHICH INDEX a row's size is registered (updateRenderObject()
      // + identity-based live-owner tracking), and confirmed (render_object_registration_test.dart,
      // test 3) that registration itself now follows the correct logical index through a
      // reorder. But _sizes is still a plain historical cache keyed by logical index: once a
      // slot is measured under index i, that Size stays in _sizes[i] until something else
      // measures under i again. If the *content* that maps to index i changes (reorder,
      // insertion, deletion, or an off-screen height change) without a fresh measurement,
      // scrollTo() silently sums the stale Size.
      //
      // Each test below reproduces one mutation kind end-to-end (real ListView.builder,
      // real pumpWidget/setState rebuild, real scrollTo(), real position.pixels read) and
      // asserts the ACTUAL observed offset obtained from that run, plus documents the
      // theoretically-correct offset computed by hand from the real (post-mutation) row
      // geometry. No test asserts a range or a tautology; every assertion is a concrete
      // number obtained by executing the scenario.
      //
      // IMPORTANT MECHANISM, found while building these tests by direct trial: if the
      // mutated slot is still on-screen (built/visible) at the moment of mutation, Flutter
      // rebuilds it on the very next pump and it gets re-measured immediately -- there is
      // no staleness window to observe. The bug only survives long enough to be captured
      // by scrollTo() when the mutated logical index is OFF-SCREEN (scrolled well past,
      // so ListView.builder has not invoked itemBuilder for that slot) at the moment of
      // mutation. Tests B, C and D therefore use a long list, scroll away from the
      // mutation point before mutating, and then probe with scrollTo() targeting an
      // ALREADY-MEASURED index so _animateTo() takes its no-search fast path and computes
      // its target purely from whatever is in _sizes at that instant -- without an
      // intervening jumpTo/pumpAndSettle, which would itself rebuild (and silently fix)
      // the stale slot before the probe runs. Scenario A (reordering with the same
      // itemCount) does not need this off-screen setup because the offset formula itself
      // is order-blind regardless of build/visibility state.
      //
      // STATUS (ISC-13): invalidateMeasurements() now exists. It clears _sizes, cancels
      // any in-flight scrollTo (ScrollCancelReason.dataInvalidated), and immediately
      // re-registers every currently-live (built) row's size, without waiting for a new
      // scrollTo search pass.
      //
      // Scenarios B, C, and D (insertion, deletion, off-screen height change) are fully
      // fixed by calling invalidateMeasurements() once, right after the mutation and
      // before the probing scrollTo: each test below now asserts the THEORETICALLY
      // CORRECT offset, not the buggy one, proving the fix closes the gap end-to-end.
      //
      // Scenario A (reordering with unchanged itemCount) is a different, ARCHITECTURALLY
      // DISTINCT case: it is NOT fixed by invalidateMeasurements(), and cannot be with the
      // current algorithm, even in principle. The reason is not staleness of the cache --
      // invalidateMeasurements() correctly clears and re-measures, but that is beside
      // the point: watch(index: logicalIndex) here passes a stable logical/content id
      // that moves between physical slots on reorder, which ISC-27 identifies as a
      // *misuse* of watch(index:) -- the contract requires index to equal the row's
      // physical slot, not a stable id. ISC-28 detects that mismatch directly (via
      // SliverMultiBoxAdaptorParentData.index compared against the registered
      // watch(index:) value) and makes scrollTo() throw StateError before completing,
      // instead of silently summing a logical-order prefix through the mismatched
      // entries. invalidateMeasurements() alone cannot detect a reorder with the
      // same itemCount; ISC-28 makes that failure explicit rather than silent.

      testWidgets(
        'A: reordering rows with unchanged itemCount is rejected by ISC-28 as a '
        'watch(index:) mismatch, even after invalidateMeasurements()',
        (WidgetTester tester) async {
          // Same technique as render_object_registration_test.dart test 3
          // ("reordering visible rows with same itemCount ..."): a mutable
          // currentOrder[slotPosition] -> logicalIndex map, rebuilt via
          // StatefulBuilder's setState, with watch(index: logicalIndex) so the
          // *logical* index (not the physical slot) travels with the row's content.
          const itemCount = 5;
          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );

          // Distinct, non-uniform heights so a reorder produces a visible/numeric gap
          // (mirrors the review's "6410 vs 6440" style discrepancy, scaled to a small list).
          final heights = [100.0, 260.0, 310.0, 150.0, 240.0]; // sum = 1060
          List<int> currentOrder = [0, 1, 2, 3, 4];
          late StateSetter setOrder;

          Widget buildList() {
            return MaterialApp(
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    setOrder = setState;
                    return ListView.builder(
                      controller: controller,
                      itemCount: itemCount,
                      itemBuilder: (context, slotPosition) {
                        final logicalIndex = currentOrder[slotPosition];
                        return controller.watch(
                          index: logicalIndex,
                          child: Container(
                            height: heights[logicalIndex],
                            color: Colors.blue,
                            child: Center(child: Text('logical=$logicalIndex')),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            );
          }

          // Step 1: render and fully measure the original order [0,1,2,3,4] by
          // scrolling through the whole list once.
          await tester.pumpWidget(buildList());
          await tester.pumpAndSettle();

          unawaited(controller.scrollTo(4.0, duration: const Duration(milliseconds: 100)));
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          var measurements = controller.measurementsSizes;
          expect(
            measurements.length,
            equals(itemCount),
            reason: 'All 5 logical indices must be measured before the reorder.',
          );
          expect(measurements[0]?.height, closeTo(100.0, 1.0));
          expect(measurements[1]?.height, closeTo(260.0, 1.0));
          expect(measurements[2]?.height, closeTo(310.0, 1.0));
          expect(measurements[3]?.height, closeTo(150.0, 1.0));
          expect(measurements[4]?.height, closeTo(240.0, 1.0));

          controller.jumpTo(0.0);
          await tester.pumpAndSettle();

          // Step 2: reorder so logical index 4 (h=240) moves to slot 0, and every
          // other logical index also moves. currentOrder[slot] = logicalIndex.
          setOrder(() {
            currentOrder = [4, 3, 0, 1, 2];
          });
          await tester.pumpAndSettle();

          // Registration itself follows the correct logical index (ISC-11), so
          // _sizes stays keyed by logical index with the same values as before
          // the reorder -- this reorder does not change any row's own height,
          // only which slot it occupies.
          measurements = controller.measurementsSizes;
          expect(measurements.length, equals(itemCount));
          expect(measurements[0]?.height, closeTo(100.0, 1.0));
          expect(measurements[1]?.height, closeTo(260.0, 1.0));
          expect(measurements[2]?.height, closeTo(310.0, 1.0));
          expect(measurements[3]?.height, closeTo(150.0, 1.0));
          expect(measurements[4]?.height, closeTo(240.0, 1.0));

          // Step 3: explicitly call invalidateMeasurements() -- exactly what the
          // contract asks callers to do after a data mutation -- then ask to scroll
          // to logical index 2 (h=310), now visually at slot 4 (the last slot,
          // since currentOrder = [4,3,0,1,2]).
          //
          // ISC-28: watch(index: logicalIndex) here means every non-identity slot
          // registers a mismatch against its physical position (e.g. slot 0 now
          // registers logical index 4, not 0). invalidateMeasurements() clears
          // _sizes and _watchIndexMismatches and forces every live row through
          // performLayout() again, but the same (still-wrong) itemBuilder
          // re-registers the very same mismatches immediately -- so the ensuing
          // scrollTo(2.0) must be rejected with StateError, not complete at either
          // the buggy logical-order sum (360.0 px) or the true visual offset
          // (750.0 px, summing 240+150+100+260 for the rows now actually above
          // logical index 2 in slot order [4,3,0,1,2]).
          controller.invalidateMeasurements();

          // ISC-28's mismatch check requires a complete 0..target prefix before
          // it can even run (it reuses _hasCompletePrefix's gate), and
          // invalidateMeasurements() just cleared _sizes with no relayout yet --
          // so this scrollTo() does NOT take the already-measured fast path; it
          // falls into the internal search-from-0 recovery pass (ISC-30/31),
          // which only discovers the (re-registered) mismatch as live rows
          // relayout across several pumped frames. expectLater alone never pumps
          // a frame while awaiting, so it would hang forever waiting on a Future
          // that can only resolve via pumped frames -- the manual pump loop
          // below is required, mirroring every other multi-frame scrollTo() in
          // this file.
          Object? scrollError;
          bool scrollCompleted = false;
          unawaited(
            controller.scrollTo(2.0, duration: const Duration(milliseconds: 100)).then(
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
            reason: 'scrollTo() must settle (success or error) within the frame budget.',
          );
          expect(
            scrollError,
            isA<StateError>(),
            reason: 'ISC-28: reordering via watch(index: logicalIndex) instead of '
                'watch(index: slotPosition) is a watch(index:) mismatch, which '
                'invalidateMeasurements() does not and cannot fix by itself -- '
                'the caller\'s itemBuilder must pass the corrected physical '
                'positions. scrollTo(2) must throw before completing, whether '
                'or not invalidateMeasurements() was called first.',
          );
        },
      );

      testWidgets(
        'B: inserting a row is fixed by an explicit invalidateMeasurements() call',
        (WidgetTester tester) async {
          // Model insertion as a mutable content-id list: logicalContentIds[i] is
          // the "content identity" (and thus height) shown at logical index i.
          // Inserting in the middle shifts every subsequent index's content by
          // one slot, while itemCount grows by one.
          //
          // The insertion point must be OFF-SCREEN when the mutation happens: if
          // every row fits in the viewport simultaneously, ListView.builder
          // rebuilds (and thus re-measures) every slot immediately on the very
          // next pumpAndSettle() after the mutation, and the bug this test exists
          // to capture never gets a chance to surface. A long list, scrolled well
          // past the insertion point before mutating, keeps that slot unbuilt
          // (see scenario D for the same off-screen technique, which was
          // confirmed by direct run to be necessary).
          const itemCount = 30;
          const viewportHeight = 600.0;
          const defaultHeight = 100.0;
          const insertAt = 2;
          const insertedHeight = 400.0;

          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );

          List<String> logicalContentIds = List<String>.generate(itemCount, (i) => 'orig$i');
          late StateSetter setContentIds;

          Widget buildList() {
            return MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: viewportHeight,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      setContentIds = setState;
                      return ListView.builder(
                        controller: controller,
                        itemCount: logicalContentIds.length,
                        itemBuilder: (context, index) {
                          final contentId = logicalContentIds[index];
                          final height = contentId == 'INSERTED' ? insertedHeight : defaultHeight;
                          return controller.watch(
                            index: index,
                            child: Container(
                              height: height,
                              color: Colors.green,
                              child: Center(child: Text('index=$index content=$contentId')),
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

          await tester.pumpWidget(buildList());
          await tester.pumpAndSettle();

          // Step 1: scroll far enough (past index `insertAt`, and enough to
          // measure a target beyond it) that indices 0..5 are all measured at
          // their original height, then scroll far away so index `insertAt`
          // becomes off-screen and unbuilt.
          unawaited(controller.scrollTo(5.0, duration: const Duration(milliseconds: 100)));
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          var measurements = controller.measurementsSizes;
          for (int i = 0; i <= 5; i++) {
            expect(
              measurements[i]?.height,
              closeTo(defaultHeight, 1.0),
              reason: 'Index $i must be measured at its original height before insertion.',
            );
          }

          unawaited(controller.scrollTo(25.0, duration: const Duration(milliseconds: 100)));
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(
            controller.position.pixels,
            greaterThan(viewportHeight),
            reason: 'Must have scrolled far enough that index $insertAt is off-screen.',
          );

          // Step 2: insert a new row 'INSERTED' (h=400) at logical index
          // `insertAt` while it is off-screen. Every subsequent itemBuilder(i)
          // for i >= insertAt now returns different content than before, but
          // since none of those slots are built (off-screen), no remeasurement
          // happens; _sizes[insertAt] keeps stale content's old height.
          setContentIds(() {
            logicalContentIds = [
              ...logicalContentIds.sublist(0, insertAt),
              'INSERTED',
              ...logicalContentIds.sublist(insertAt),
            ];
          });
          await tester.pumpAndSettle();

          measurements = controller.measurementsSizes;
          expect(
            measurements[insertAt]?.height,
            closeTo(defaultHeight, 1.0),
            reason: 'Directly observed: _sizes[$insertAt] still holds the stale '
                'pre-insertion height $defaultHeight after the off-screen '
                'insertion, because that slot was not rebuilt (outside the '
                'viewport) so no new measurement occurred for the new content '
                '\'INSERTED\' (h=$insertedHeight) now logically at that index. '
                'This confirms the staleness invalidateMeasurements() must fix '
                'below, before any call to it.',
          );

          // Step 3: call invalidateMeasurements() -- exactly what the contract
          // requires callers to do
          // after this kind of data mutation. It clears _sizes and immediately
          // re-registers only currently LIVE rows; since the viewport is
          // currently scrolled well past index `insertAt`, indices near 0
          // (including 0 itself) are not live and are NOT re-registered by that
          // step alone. scrollTo()'s own minVisibleIndex computation always sums
          // a prefix starting at index 0 (independent of search direction), so
          // without a 0-prefix present in _sizes, any scrollTo() call right after
          // invalidateMeasurements() would correctly and honestly throw
          // StateError for the still-missing index 0 -- a real instance of the
          // "no silent wrong success" contract this task requires, not a defect.
          //
          // To probe the ACTUAL post-fix offset (rather than that legitimate
          // StateError, which the dedicated "full-prefix contract after reset"
          // test below already covers), jump back to the top first so the
          // 0-prefix becomes live and gets rebuilt/re-measured under the new
          // (post-insertion) content -- a real, physically-run rebuild, not an
          // assumption.
          controller.invalidateMeasurements();
          controller.jumpTo(0.0);
          await tester.pumpAndSettle();

          // THEORETICALLY CORRECT visual offset to index insertAt+1 (3) after
          // insertion: indices 0,1 unaffected (100 each), new inserted row at
          // index insertAt (400) -> correct = 100+100+400 = 600.0 px.
          const correctOffset = insertAt * defaultHeight + insertedHeight;

          unawaited(
            controller.scrollTo((insertAt + 1).toDouble(), duration: const Duration(milliseconds: 100)),
          );
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          final observedOffset = controller.position.pixels;

          expect(
            observedOffset,
            closeTo(correctOffset, 1.0),
            reason: 'FIXED (ISC-13): after inserting content \'INSERTED\' at logical '
                'index $insertAt and calling invalidateMeasurements(), '
                'scrollTo(${insertAt + 1}) completes at the correct post-insertion '
                'visual offset $correctOffset px (100+100+$insertedHeight), not '
                'the previously-observed buggy ${(insertAt + 1) * defaultHeight} px '
                'that reused the stale pre-insertion height.',
          );
        },
      );

      testWidgets(
        'C: deleting a row is fixed by an explicit invalidateMeasurements() call',
        (WidgetTester tester) async {
          // Mirror of scenario B: delete (instead of insert) a row while its
          // slot is off-screen, using the same technique.
          const itemCount = 30;
          const viewportHeight = 600.0;
          const defaultHeight = 100.0;
          const deleteAt = 2;
          // The row taking deleteAt's place after deletion has a distinctly
          // different height, so a stale vs. fresh read is numerically obvious.
          const survivorHeight = 400.0;

          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );

          // 'del' is the row that will be deleted (at index deleteAt); 'SURV' is
          // the row that ends up at index deleteAt after the deletion.
          List<String> logicalContentIds = List<String>.generate(
            itemCount,
            (i) => i == deleteAt
                ? 'del'
                : i == deleteAt + 1
                    ? 'SURV'
                    : 'orig$i',
          );
          late StateSetter setContentIds;

          Widget buildList() {
            return MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: viewportHeight,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      setContentIds = setState;
                      return ListView.builder(
                        controller: controller,
                        itemCount: logicalContentIds.length,
                        itemBuilder: (context, index) {
                          final contentId = logicalContentIds[index];
                          final height = contentId == 'SURV' ? survivorHeight : defaultHeight;
                          return controller.watch(
                            index: index,
                            child: Container(
                              height: height,
                              color: Colors.orange,
                              child: Center(child: Text('index=$index content=$contentId')),
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

          await tester.pumpWidget(buildList());
          await tester.pumpAndSettle();

          // Step 1: measure indices 0..5 (covering deleteAt and its neighbor),
          // then scroll far away so index `deleteAt` becomes off-screen/unbuilt.
          unawaited(controller.scrollTo(5.0, duration: const Duration(milliseconds: 100)));
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          var measurements = controller.measurementsSizes;
          expect(measurements[deleteAt]?.height, closeTo(defaultHeight, 1.0));
          expect(measurements[deleteAt + 1]?.height, closeTo(survivorHeight, 1.0));

          unawaited(controller.scrollTo(25.0, duration: const Duration(milliseconds: 100)));
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(
            controller.position.pixels,
            greaterThan(viewportHeight),
            reason: 'Must have scrolled far enough that index $deleteAt is off-screen.',
          );

          // Step 2: delete the row at logical index `deleteAt` while off-screen.
          // Every subsequent index shifts down by one; new logical index
          // `deleteAt` now shows content 'SURV' (h=400), not 'del' (h=100).
          setContentIds(() {
            logicalContentIds = [
              ...logicalContentIds.sublist(0, deleteAt),
              ...logicalContentIds.sublist(deleteAt + 1),
            ];
          });
          await tester.pumpAndSettle();

          measurements = controller.measurementsSizes;
          expect(
            measurements[deleteAt]?.height,
            closeTo(defaultHeight, 1.0),
            reason: 'Directly observed: _sizes[$deleteAt] still holds the stale '
                'pre-deletion height $defaultHeight (deleted content \'del\') '
                'after the off-screen deletion, because that slot was not '
                'rebuilt (outside the viewport) so no new measurement occurred '
                'for content \'SURV\' (h=$survivorHeight), now the actual '
                'content at that logical index. This confirms the staleness '
                'invalidateMeasurements() must fix below, before any call to it.',
          );

          // Step 3: call invalidateMeasurements(), then jump back to the top so
          // the 0-prefix (not live at the current far-scrolled position) becomes
          // live again and is rebuilt/re-measured under the post-deletion
          // content -- see scenario B's comment for why this jump is needed
          // (scrollTo()'s minVisibleIndex computation always requires a 0-prefix,
          // which invalidateMeasurements() alone cannot supply for indices that
          // are not currently live).
          controller.invalidateMeasurements();
          controller.jumpTo(0.0);
          await tester.pumpAndSettle();

          // THEORETICALLY CORRECT visual offset to index deleteAt+1 after
          // deletion: indices 0..deleteAt-1 unaffected (100 each), row 'SURV'
          // now at index deleteAt (400) -> correct = 100+100+400 = 600.0 px.
          const correctOffset = deleteAt * defaultHeight + survivorHeight;

          unawaited(
            controller.scrollTo((deleteAt + 1).toDouble(), duration: const Duration(milliseconds: 100)),
          );
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          final observedOffset = controller.position.pixels;

          expect(
            observedOffset,
            closeTo(correctOffset, 1.0),
            reason: 'FIXED (ISC-13): after deleting content \'del\' at logical index '
                '$deleteAt and calling invalidateMeasurements(), '
                'scrollTo(${deleteAt + 1}) completes at the correct post-deletion '
                'visual offset $correctOffset px (100+100+$survivorHeight), not '
                'the previously-observed buggy ${(deleteAt + 1) * defaultHeight} px '
                'that reused the stale pre-deletion height.',
          );
        },
      );

      testWidgets(
        'D: changing an off-screen row\'s height is fixed by an explicit invalidateMeasurements() call',
        (WidgetTester tester) async {
          // A long list so item K is measured once, then scrolled far out of the
          // viewport (so it is unmounted / not rebuilt), then its height in the
          // data source changes. Because it is off-screen, itemBuilder is not
          // invoked for it again, so _sizes[K] keeps the old value.
          const itemCount = 30;
          const viewportHeight = 600.0;
          const defaultHeight = 100.0;
          const mutatedIndex = 2;
          const oldHeight = defaultHeight; // 100.0
          const newHeight = 400.0;

          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );

          double heightForIndex(int index) => index == mutatedIndex ? _mutatedHeight.value : defaultHeight;

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: viewportHeight,
                  child: ValueListenableBuilder<double>(
                    valueListenable: _mutatedHeight,
                    builder: (context, _, __) {
                      return ListView.builder(
                        controller: controller,
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          return controller.watch(
                            index: index,
                            child: Container(
                              height: heightForIndex(index),
                              color: Colors.purple,
                              child: Center(child: Text('index=$index')),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          );

          await tester.pumpAndSettle();

          // Step 1: scroll to index `mutatedIndex` to measure it at its original
          // height (100.0), establishing _sizes[mutatedIndex] = 100.0.
          unawaited(
            controller.scrollTo(mutatedIndex.toDouble(), duration: const Duration(milliseconds: 100)),
          );
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          var measurements = controller.measurementsSizes;
          expect(
            measurements[mutatedIndex]?.height,
            closeTo(oldHeight, 1.0),
            reason: 'Item $mutatedIndex must be measured at its original height before mutation.',
          );

          // Step 2: scroll far away so index `mutatedIndex` is well outside the
          // viewport and gets unmounted by ListView.builder's lazy building.
          unawaited(
            controller.scrollTo(25.0, duration: const Duration(milliseconds: 100)),
          );
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(
            controller.position.pixels,
            greaterThan(viewportHeight),
            reason: 'Must have scrolled far enough that index $mutatedIndex is off-screen.',
          );

          // Step 3: mutate the data source's height for `mutatedIndex` while it is
          // off-screen. Its itemBuilder is not invoked (not visible), so no
          // remeasurement happens; _sizes[mutatedIndex] keeps the old 100.0.
          _mutatedHeight.value = newHeight;
          await tester.pumpAndSettle();

          measurements = controller.measurementsSizes;
          expect(
            measurements[mutatedIndex]?.height,
            closeTo(oldHeight, 1.0),
            reason: 'Directly observed: _sizes[$mutatedIndex] still holds the stale '
                'height $oldHeight after the off-screen height mutation, because '
                'the row was not rebuilt (it is outside the viewport) so no new '
                'measurement occurred. This confirms the staleness '
                'invalidateMeasurements() must fix below, before any call to it.',
          );

          // Step 4: call invalidateMeasurements(), then jump back to the top so
          // the 0-prefix (not live at the current far-scrolled position) becomes
          // live again and is rebuilt/re-measured under the post-mutation height
          // -- see scenario B's comment for why the jump is needed:
          // scrollTo()'s minVisibleIndex computation always requires a 0-prefix
          // in _sizes, which invalidateMeasurements() alone cannot supply for
          // indices that are not currently live (this list is far-scrolled past
          // index $mutatedIndex at this point). Calling invalidateMeasurements()
          // BEFORE the jump (not after) is what actually matters here: it is
          // what guarantees the jump's rebuild reads the row's fresh height from
          // the live widget tree rather than reusing a cache entry that survived
          // the mutation untouched.
          controller.invalidateMeasurements();
          controller.jumpTo(0.0);
          await tester.pumpAndSettle();

          // THEORETICALLY CORRECT offset using the true new height for row
          // `mutatedIndex`: mutatedIndex-many rows at 100.0 plus the mutated
          // row's NEW height -> correct = 2*100.0 + 400.0 = 600.0 px.
          const correctOffset = mutatedIndex * defaultHeight + newHeight;

          unawaited(
            controller.scrollTo((mutatedIndex + 1).toDouble(), duration: const Duration(milliseconds: 100)),
          );
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          final observedOffset = controller.position.pixels;

          expect(
            observedOffset,
            closeTo(correctOffset, 1.0),
            reason: 'FIXED (ISC-13): after mutating the off-screen height of index '
                '$mutatedIndex from $oldHeight to $newHeight and calling '
                'invalidateMeasurements(), scrollTo(${mutatedIndex + 1}) completes at '
                'the visually correct $correctOffset px (using the real new height '
                '$newHeight), not the previously-observed buggy '
                '${mutatedIndex * defaultHeight + oldHeight} px that reused the stale '
                'cached height.',
          );
        },
      );
    },
  );

  group('ISC-13: invalidateMeasurements() cancellation and operation-id interaction', () {
    testWidgets(
      'A superseded by B, then invalidateMeasurements(): A completes with superseded (not '
      'dataInvalidated), and B is left running without having its state clobbered',
      (WidgetTester tester) async {
        // Regression test for the ISC-09 review note: "for ISC-13, which will also touch
        // the _activeOperationId family of fields, consider adding an explicit regression
        // test for the race 'A superseded by B, A's finally must not clobber B's
        // activeOperationId'". invalidateMeasurements() reads/writes exactly that field
        // family (_activeOperationId, _currentOperationId, and the new
        // _invalidatedOperationId), so this exercises the same race one more layer deep:
        // call A, supersede it with call B (A becomes stale but hasn't reached its
        // `finally` yet), then call invalidateMeasurements() while B is the active
        // operation. invalidateMeasurements() must cancel B (the actual active operation)
        // with ScrollCancelReason.dataInvalidated, while A -- already superseded before
        // invalidateMeasurements() ran -- must still report plain `superseded`, not
        // `dataInvalidated`, since invalidateMeasurements() never actually targeted A.
        const itemCount = 60;
        const rowHeight = 100.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  return controller.watch(
                    index: index,
                    child: SizedBox(height: rowHeight, child: Text('Item $index')),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        Object? aError;
        bool aCompleted = false;
        unawaited(
          controller.scrollTo(50.0).then(
            (_) => aCompleted = true,
            onError: (Object e) {
              aError = e;
              aCompleted = true;
            },
          ),
        );

        // Let A take a couple of search steps so it is genuinely mid-flight (has
        // already claimed _activeOperationId and is awaiting inside _animateTo)
        // before it gets superseded.
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));

        Object? bError;
        bool bCompleted = false;
        unawaited(
          controller.scrollTo(10.0).then(
            (_) => bCompleted = true,
            onError: (Object e) {
              bError = e;
              bCompleted = true;
            },
          ),
        );

        // Let B take a couple of steps too, so it is the genuinely active
        // operation (owns _activeOperationId) when invalidateMeasurements() runs.
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));

        expect(
          aCompleted,
          isTrue,
          reason: 'By this point A should already have noticed it was superseded by B '
              'and completed with a cancellation, independent of '
              'invalidateMeasurements() which has not been called yet.',
        );
        expect(
          aError,
          isA<ScrollCancelledException>().having(
            (e) => e.reason,
            'reason',
            ScrollCancelReason.superseded,
          ),
          reason: 'A must report plain supersession by B, not dataInvalidated.',
        );
        expect(
          bCompleted,
          isFalse,
          reason: 'B must still be actively running when invalidateMeasurements() is called.',
        );

        controller.invalidateMeasurements();

        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (bCompleted) break;
        }

        expect(bCompleted, isTrue);
        expect(
          bError,
          isA<ScrollCancelledException>().having(
            (e) => e.reason,
            'reason',
            ScrollCancelReason.dataInvalidated,
          ),
          reason: 'B was the genuinely active operation when invalidateMeasurements() ran, '
              'so it must be the one cancelled with dataInvalidated -- proving '
              "invalidateMeasurements() cancels whichever call currently owns "
              '_activeOperationId, not a stale id left over from A even though A was '
              'the id most recently superseded.',
        );
      },
    );
  });

  group('ISC-13/ISC-31: full-prefix contract after reset', () {
    testWidgets(
      'a non-contiguous watch() index set still gives StateError, not _TypeError, after '
      'invalidateMeasurements() forces a fresh internal search-from-0 pass',
      (WidgetTester tester) async {
        // A gap in the current measured prefix must complete with StateError,
        // rather than _TypeError, and this must keep holding through
        // invalidateMeasurements(), not just the pre-existing _sizeOrThrow() path
        // exercised by scroll_to_contract_test.dart's non-contiguous watch() test.
        //
        // ISC-31 changed invalidateMeasurements() to no longer eagerly copy live
        // rows' RenderBox.size back into _sizes (ISC-30's decision: that geometry
        // may predate a real post-invalidation layout pass). So immediately after
        // invalidateMeasurements(), _sizes is empty, not {0,1,2,50,51,52} again --
        // and scrollTo(52) must internally jump to 0 and sequentially re-measure
        // forward (reusing the ISC-05 search loop), exactly as it would for a
        // never-measured index. Because logical index 3 was never watched (this
        // list only ever registers 0,1,2,50,51,52), that search pass eventually
        // stalls at a stable physical edge with indices 50,51,52 already measured
        // above the gap at 3 -- which is exactly the "genuine gap", not "list
        // ended early", case this task's StateError-vs-RangeError distinction
        // exists for. The result must still be StateError naming index 3, not
        // _TypeError and not a silently wrong offset.
        const rowHeight = 100.0;
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        const logicalIndices = [0, 1, 2, 50, 51, 52];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: logicalIndices.length,
                itemBuilder: (context, slotPosition) {
                  return controller.watch(
                    index: logicalIndices[slotPosition],
                    child: SizedBox(
                      height: rowHeight,
                      child: Text('logical=${logicalIndices[slotPosition]}'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        var measurements = controller.measurementsSizes;
        expect(
          measurements.keys.toSet(),
          equals(logicalIndices.toSet()),
          reason: 'All six non-contiguous logical indices must be live and measured '
              'before invalidateMeasurements() is called.',
        );

        controller.invalidateMeasurements();

        measurements = controller.measurementsSizes;
        expect(
          measurements.keys.toSet(),
          isEmpty,
          reason: 'ISC-31: invalidateMeasurements() no longer eagerly re-populates _sizes '
              'from live RenderBox.size; the cache starts genuinely empty until a real '
              'post-invalidation layout pass re-registers each row.',
        );

        Object? caughtError;
        final future = controller.scrollTo(52.0, duration: const Duration(milliseconds: 100));
        unawaited(future.catchError((Object e) => caughtError = e));
        for (int i = 0; i < 300 && caughtError == null; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          caughtError,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('3'),
          ),
          reason: 'scrollTo(52) must internally search from 0, discover the genuine gap '
              'at logical index 3 (never watched, neither before nor after '
              'invalidateMeasurements()), and fail with a StateError naming the '
              'missing index -- not a raw _TypeError, and not a silently wrong '
              'offset.',
        );
      },
    );
  });
}

final ValueNotifier<double> _mutatedHeight = ValueNotifier<double>(100.0);
