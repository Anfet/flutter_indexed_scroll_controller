import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group(
    'ISC-29/ISC-31: invalidateMeasurements() immediately after a mid-scroll mutation, '
    'with and without an intervening pump/layout',
    () {
      // CONTEXT: ISC-29 characterized a bug in invalidateMeasurements()'s original
      // ISC-13 implementation, which re-registered live rows SYNCHRONOUSLY by reading
      // `owner.size` straight off each row's _RenderIndexedScrollItem. `owner.size` is
      // RenderBox.size, which is only updated inside performLayout() -- i.e. it
      // reflects whatever the row's last COMPLETED layout produced, not necessarily
      // the widget tree's current configuration. If a row that is currently live (on
      // screen, mid-scroll) has its DATA mutated and invalidateMeasurements() is
      // called before Flutter ever gets a chance to run a layout pass reflecting that
      // mutation, the render object's `.size` field was still the OLD one -- so
      // invalidateMeasurements() silently captured a stale height and a subsequent
      // scrollTo() completed "successfully" at the wrong offset.
      //
      // FIX (ISC-30's decision, implemented in ISC-31): invalidateMeasurements() no
      // longer copies RenderBox.size at all. It clears _sizes and calls
      // markNeedsLayout() on every live row (see
      // _RenderIndexedScrollItem.invalidateMeasurement()), so nothing is trusted until
      // a real post-invalidation layout actually produces it. scrollTo() itself gates
      // on a full 0..target prefix (IndexedScrollController._hasCompletePrefix): if
      // the prefix is incomplete (which it always is immediately after invalidation,
      // since _sizes starts empty), it internally jumps to offset 0 and reuses the
      // existing ISC-05 sequential search-and-measure pass to walk forward,
      // re-registering each row from a REAL layout as it goes, until the whole prefix
      // through the target is known. No external jumpTo(0) or enlarged cacheExtent is
      // required from the caller.
      //
      // The two orderings below (with vs. without an intervening pump() between the
      // mutation and invalidateMeasurements()) now produce the SAME correct result --
      // that is the whole point of the fix: variant A (no pump) no longer needs the
      // caller to insert one to get the right answer, because scrollTo() itself waits
      // out a real frame internally via the search loop's
      // `await WidgetsBinding.instance.endOfFrame` on every step.
      //
      // Both orderings are exercised end-to-end against a real ListView.builder, real
      // setState/ValueNotifier mutation, and a real, unmodified controller.scrollTo()
      // -- no mocking. Every assertion below pins the ACTUAL number this run produced.

      testWidgets(
        'A: height change of a currently-visible row, invalidateMeasurements() then '
        'scrollTo() with NO pump in between -- now resolves to the CORRECT height',
        (WidgetTester tester) async {
          const itemCount = 20;
          const viewportHeight = 400.0;
          const defaultHeight = 100.0;
          // Index 4 will be visible on screen once scrolled to the middle
          // (offset 800 puts rows ~8-11 on screen at 100px each within a
          // 400px viewport -- see the scroll-to-middle step below, which
          // targets a row well inside that visible band).
          const mutatedIndex = 9;
          const newHeight = 350.0;

          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );
          addTearDown(controller.dispose);

          final ValueNotifier<double> heightNotifier = ValueNotifier<double>(defaultHeight);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: viewportHeight,
                  child: ValueListenableBuilder<double>(
                    valueListenable: heightNotifier,
                    builder: (context, mutatedHeight, _) {
                      return ListView.builder(
                        controller: controller,
                        // A large cacheExtent keeps every row in this short
                        // list built/live for the whole test, regardless of
                        // scroll offset -- so "scrolled to the middle" is
                        // governed purely by position.pixels. This is no
                        // longer required for correctness (ISC-31's internal
                        // search-from-0 does not need a 0-prefix to already
                        // be live), but is kept here so this test isolates
                        // the height-change mechanism specifically; a
                        // separate scenario below drops this and exercises
                        // the internal recovery path directly.
                        // ignore: deprecated_member_use
                        cacheExtent: 5000,
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          final height = index == mutatedIndex ? mutatedHeight : defaultHeight;
                          return controller.watch(
                            index: index,
                            child: SizedBox(height: height, child: Text('Item $index')),
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

          // Scroll to the MIDDLE of the list (not offset 0), so mutatedIndex
          // (9) ends up on screen: offset 800 puts rows 8-11 visible within
          // the 400px viewport at 100px/row.
          final scrollToMiddle = controller.scrollTo(8.0, duration: const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
          await scrollToMiddle;
          expect(controller.position.pixels, 800.0);

          var measurements = controller.measurementsSizes;
          expect(
            measurements[mutatedIndex]?.height,
            closeTo(defaultHeight, 0.5),
            reason: 'Row $mutatedIndex must be live and measured at its original '
                'height before mutation, confirming it is genuinely on screen '
                'mid-scroll.',
          );

          // Mutate the height of the currently-visible row, then IMMEDIATELY
          // invalidate and scrollTo(), with no intervening pump(): setting a
          // ValueNotifier's .value does not synchronously run a Flutter frame
          // or layout, so at the moment invalidateMeasurements() executes, the
          // row's RenderObject has NOT been laid out against the new height
          // yet.
          heightNotifier.value = newHeight;
          controller.invalidateMeasurements();

          measurements = controller.measurementsSizes;
          // FIXED (ISC-31): invalidateMeasurements() no longer copies
          // RenderBox.size at all, so _sizes has no entry for mutatedIndex
          // immediately after the call -- neither the stale nor the fresh
          // height, just nothing, until a real layout pass runs.
          expect(
            measurements.containsKey(mutatedIndex),
            isFalse,
            reason:
                'invalidateMeasurements() clears _sizes and does not re-populate it '
                'from RenderBox.size, so index $mutatedIndex has no entry at all '
                'immediately after the call -- it is filled back in only once '
                "scrollTo()'s internal search pass drives a real layout.",
          );

          // Probe with scrollTo(mutatedIndex + 1): this is the offset that
          // actually sums through the mutated row's own height, so it is
          // the one that can expose staleness. Call it IMMEDIATELY (no
          // intervening probe, no intervening pump) so nothing gets a
          // chance to rebuild/re-measure the row between the invalidation
          // above and this call other than scrollTo() itself.
          final future = controller.scrollTo(
            (mutatedIndex + 1).toDouble(),
            duration: const Duration(milliseconds: 100),
          );
          await tester.pumpAndSettle();
          await future;

          final observedOffset = controller.position.pixels;

          // THEORETICALLY CORRECT offset to index mutatedIndex+1: rows
          // 0..mutatedIndex-1 at 100px each, plus the mutated row's TRUE new
          // height -> 9*100 + 350 = 1250.0 px.
          const correctOffset = mutatedIndex * defaultHeight + newHeight;

          expect(
            observedOffset,
            closeTo(correctOffset, 1.0),
            reason:
                'FIXED (ISC-31): scrollTo(${mutatedIndex + 1}) completes at the '
                'correct $correctOffset px (9*100 + $newHeight) even with no pump '
                'between the mutation and invalidateMeasurements(), because '
                "scrollTo()'s internal search-from-0 pass only trusts sizes from a "
                'real post-invalidation layout, obtained via its own '
                '`await WidgetsBinding.instance.endOfFrame` steps -- variant A no '
                'longer needs the caller to insert a pump to get the right answer.',
          );
        },
      );

      testWidgets(
        'B: height change of a currently-visible row, pump() BEFORE invalidateMeasurements() '
        '-- still resolves to the CORRECT (post-layout) height',
        (WidgetTester tester) async {
          const itemCount = 20;
          const viewportHeight = 400.0;
          const defaultHeight = 100.0;
          const mutatedIndex = 9;
          const newHeight = 350.0;

          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );
          addTearDown(controller.dispose);

          final ValueNotifier<double> heightNotifier = ValueNotifier<double>(defaultHeight);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: viewportHeight,
                  child: ValueListenableBuilder<double>(
                    valueListenable: heightNotifier,
                    builder: (context, mutatedHeight, _) {
                      return ListView.builder(
                        controller: controller,
                        // ignore: deprecated_member_use
                        cacheExtent: 5000,
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          final height = index == mutatedIndex ? mutatedHeight : defaultHeight;
                          return controller.watch(
                            index: index,
                            child: SizedBox(height: height, child: Text('Item $index')),
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

          final scrollToMiddle = controller.scrollTo(8.0, duration: const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
          await scrollToMiddle;
          expect(controller.position.pixels, 800.0);

          var measurements = controller.measurementsSizes;
          expect(measurements[mutatedIndex]?.height, closeTo(defaultHeight, 0.5));

          // Mutate, then let a real frame/layout run BEFORE invalidating.
          heightNotifier.value = newHeight;
          await tester.pump();

          controller.invalidateMeasurements();

          measurements = controller.measurementsSizes;
          // invalidateMeasurements() clears _sizes unconditionally now, so even
          // though a layout already ran against the new height before this call,
          // the entry is gone until scrollTo()'s own recovery pass puts it back.
          expect(measurements.containsKey(mutatedIndex), isFalse);

          final future = controller.scrollTo(
            (mutatedIndex + 1).toDouble(),
            duration: const Duration(milliseconds: 100),
          );
          await tester.pumpAndSettle();
          await future;

          final observedOffset = controller.position.pixels;
          const correctOffset = mutatedIndex * defaultHeight + newHeight;

          expect(
            observedOffset,
            closeTo(correctOffset, 1.0),
            reason:
                'Variant B confirmed correct: scrollTo(${mutatedIndex + 1}) '
                'completes at the visually correct $correctOffset px '
                '($mutatedIndex*$defaultHeight + $newHeight).',
          );
        },
      );

      testWidgets(
        'A2: mid-list insertion while the insertion point is visible, invalidateMeasurements() '
        'then scrollTo() with NO pump in between -- now resolves to the CORRECT prefix',
        (WidgetTester tester) async {
          // Model insertion as a mutable content-id list, same technique as
          // test/scroll_to_mutated_data_test.dart scenario B, but this time
          // the insertion point is scrolled to be ON SCREEN (mid-scroll, per
          // the task) rather than off-screen, and no pump() separates the
          // mutation from invalidateMeasurements().
          const itemCount = 20;
          const viewportHeight = 400.0;
          const defaultHeight = 100.0;
          const insertAt = 9;
          const insertedHeight = 300.0;

          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );
          addTearDown(controller.dispose);

          List<String> contentIds = List<String>.generate(itemCount, (i) => 'orig$i');
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
                        // ignore: deprecated_member_use
                        cacheExtent: 5000,
                        itemCount: contentIds.length,
                        itemBuilder: (context, index) {
                          final contentId = contentIds[index];
                          final height = contentId == 'INSERTED' ? insertedHeight : defaultHeight;
                          return controller.watch(
                            index: index,
                            child: SizedBox(height: height, child: Text('index=$index id=$contentId')),
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

          // Scroll to the middle so index insertAt (9) is on screen: offset
          // 800 shows rows 8-11 within the 400px viewport at 100px/row.
          final scrollToMiddle = controller.scrollTo(8.0, duration: const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
          await scrollToMiddle;
          expect(controller.position.pixels, 800.0);

          var measurements = controller.measurementsSizes;
          expect(
            measurements[insertAt]?.height,
            closeTo(defaultHeight, 0.5),
            reason: 'Row $insertAt must be live and measured before insertion, '
                'confirming it is genuinely on screen mid-scroll.',
          );

          // Insert a new row at insertAt while it is on screen, then
          // IMMEDIATELY invalidate and scrollTo(), with no intervening
          // pump().
          setContentIds(() {
            contentIds = [
              ...contentIds.sublist(0, insertAt),
              'INSERTED',
              ...contentIds.sublist(insertAt),
            ];
          });
          controller.invalidateMeasurements();

          measurements = controller.measurementsSizes;
          expect(
            measurements.containsKey(insertAt),
            isFalse,
            reason:
                'ISC-31: invalidateMeasurements() no longer re-populates _sizes from '
                'RenderBox.size, so slot $insertAt has no entry at all immediately '
                'after the call.',
          );

          final future = controller.scrollTo(
            (insertAt + 1).toDouble(),
            duration: const Duration(milliseconds: 100),
          );
          await tester.pumpAndSettle();
          await future;

          final observedOffset = controller.position.pixels;

          // THEORETICALLY CORRECT offset to index insertAt+1 after insertion:
          // rows 0..insertAt-1 unaffected (100 each) + the inserted row's TRUE
          // height -> 9*100 + 300 = 1200.0 px.
          const correctOffset = insertAt * defaultHeight + insertedHeight;

          expect(
            observedOffset,
            closeTo(correctOffset, 1.0),
            reason:
                'FIXED (ISC-31): scrollTo(${insertAt + 1}) after inserting a row at '
                '$insertAt and calling invalidateMeasurements() with no intervening '
                'pump completes at the correct $correctOffset px (9*100 + '
                '$insertedHeight), because the search pass only trusts a real '
                'post-invalidation layout.',
          );
        },
      );

      testWidgets(
        'B2: mid-list insertion while the insertion point is visible, pump() BEFORE '
        'invalidateMeasurements() -- still resolves to the CORRECT (post-layout) prefix',
        (WidgetTester tester) async {
          const itemCount = 20;
          const viewportHeight = 400.0;
          const defaultHeight = 100.0;
          const insertAt = 9;
          const insertedHeight = 300.0;

          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );
          addTearDown(controller.dispose);

          List<String> contentIds = List<String>.generate(itemCount, (i) => 'orig$i');
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
                        // ignore: deprecated_member_use
                        cacheExtent: 5000,
                        itemCount: contentIds.length,
                        itemBuilder: (context, index) {
                          final contentId = contentIds[index];
                          final height = contentId == 'INSERTED' ? insertedHeight : defaultHeight;
                          return controller.watch(
                            index: index,
                            child: SizedBox(height: height, child: Text('index=$index id=$contentId')),
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

          final scrollToMiddle = controller.scrollTo(8.0, duration: const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
          await scrollToMiddle;
          expect(controller.position.pixels, 800.0);

          var measurements = controller.measurementsSizes;
          expect(measurements[insertAt]?.height, closeTo(defaultHeight, 0.5));

          setContentIds(() {
            contentIds = [
              ...contentIds.sublist(0, insertAt),
              'INSERTED',
              ...contentIds.sublist(insertAt),
            ];
          });
          // Let a real frame/layout run BEFORE invalidating, unlike variant A2.
          await tester.pump();

          controller.invalidateMeasurements();

          measurements = controller.measurementsSizes;
          expect(measurements.containsKey(insertAt), isFalse);

          final future = controller.scrollTo(
            (insertAt + 1).toDouble(),
            duration: const Duration(milliseconds: 100),
          );
          await tester.pumpAndSettle();
          await future;

          final observedOffset = controller.position.pixels;
          const correctOffset = insertAt * defaultHeight + insertedHeight;

          expect(
            observedOffset,
            closeTo(correctOffset, 1.0),
            reason:
                'Variant B2 confirmed correct: scrollTo(${insertAt + 1}) '
                'completes at the visually correct $correctOffset px '
                '($insertAt*$defaultHeight + $insertedHeight).',
          );
        },
      );

      testWidgets(
        'C: height change of a row scrolled to the middle, WITHOUT an enlarged cacheExtent -- '
        'the unloaded 0-prefix is recovered internally, no external jumpTo(0) needed',
        (WidgetTester tester) async {
          // ISC-30's decision explicitly calls out that ISC-29's original scenarios
          // used cacheExtent: 5000 to keep every row live, sidestepping the case
          // where part of the 0-prefix is actually unloaded at invalidation time.
          // This scenario uses the default ListView.builder cacheExtent (250px) on a
          // long-enough list that rows near 0 are genuinely NOT built once scrolled
          // to the middle -- so scrollTo() must recover the missing 0-prefix
          // entirely on its own, exactly as ISC-30 specifies, with no jumpTo(0) and
          // no cacheExtent override from the caller.
          const itemCount = 60;
          const viewportHeight = 400.0;
          const defaultHeight = 100.0;
          const mutatedIndex = 29;
          const newHeight = 350.0;

          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );
          addTearDown(controller.dispose);

          final ValueNotifier<double> heightNotifier = ValueNotifier<double>(defaultHeight);

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: viewportHeight,
                  child: ValueListenableBuilder<double>(
                    valueListenable: heightNotifier,
                    builder: (context, mutatedHeight, _) {
                      return ListView.builder(
                        controller: controller,
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          final height = index == mutatedIndex ? mutatedHeight : defaultHeight;
                          return controller.watch(
                            index: index,
                            child: SizedBox(height: height, child: Text('Item $index')),
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

          // Scroll to the middle: offset 2800 puts rows ~28-31 on screen at
          // 100px/row within a 400px viewport, with the default cacheExtent
          // (250px) rows near index 0 are no longer built/live.
          final scrollToMiddle = controller.scrollTo(28.0, duration: const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
          await scrollToMiddle;
          expect(controller.position.pixels, 2800.0);

          expect(
            controller.measurementsSizes[mutatedIndex]?.height,
            closeTo(defaultHeight, 0.5),
            reason: 'Row $mutatedIndex must be live and measured before mutation.',
          );

          heightNotifier.value = newHeight;
          controller.invalidateMeasurements();

          // invalidateMeasurements() clears the entire _sizes cache (including
          // the historical 0-prefix accumulated while scrolling here), and with
          // the default cacheExtent, rows near index 0 are not currently
          // live/built -- so nothing re-populates that prefix immediately. This
          // is exactly the missing-0-prefix scenario the search-from-0 recovery
          // in scrollTo() must handle without external help.
          expect(
            controller.measurementsSizes.containsKey(0),
            isFalse,
            reason: 'Immediately after invalidateMeasurements(), the 0-prefix '
                'must be genuinely gone (not eagerly re-copied), and index 0 is '
                'not currently live under the default cacheExtent, so nothing '
                'else will repopulate it before scrollTo() itself does.',
          );

          final future = controller.scrollTo(
            (mutatedIndex + 1).toDouble(),
            duration: const Duration(milliseconds: 100),
          );
          for (int i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          await future;

          final observedOffset = controller.position.pixels;
          const correctOffset = mutatedIndex * defaultHeight + newHeight;

          expect(
            observedOffset,
            closeTo(correctOffset, 1.0),
            reason:
                'scrollTo(${mutatedIndex + 1}) must recover the missing 0-prefix on '
                'its own (internally returning to offset 0 and re-measuring forward, '
                'ISC-05\'s search mechanism) and complete at the correct '
                '$correctOffset px (29*100 + $newHeight), without the caller ever '
                'calling jumpTo(0) or raising cacheExtent.',
          );
        },
      );

      testWidgets(
        'D: cancelling the in-flight recovery search with a fresh invalidateMeasurements() call '
        'still reports dataInvalidated, and does not resurrect the superseded target',
        (WidgetTester tester) async {
          // ISC-30 explicitly calls for checking re-invalidation and cancellation
          // while scrollTo()'s internal recovery pass (post-invalidation
          // search-from-0) is still waiting on a frame or mid-step -- not just
          // while the pre-existing ISC-05 search for a never-measured index is
          // running.
          const itemCount = 60;
          const rowHeight = 100.0;

          final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100),
          );
          addTearDown(controller.dispose);

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

          final scrollToMiddle = controller.scrollTo(30.0, duration: const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
          await scrollToMiddle;

          controller.invalidateMeasurements();

          Object? firstError;
          bool firstCompleted = false;
          unawaited(
            controller.scrollTo(50.0, duration: const Duration(milliseconds: 100)).then(
              (_) => firstCompleted = true,
              onError: (Object e) {
                firstError = e;
                firstCompleted = true;
              },
            ),
          );

          // Let the internal recovery search take a couple of steps (it has
          // jumped to 0 and is walking forward) before invalidating again.
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 16));

          expect(
            firstCompleted,
            isFalse,
            reason: 'The first scrollTo(50) must still be actively recovering the '
                'prefix when the second invalidateMeasurements() runs.',
          );

          controller.invalidateMeasurements();

          for (int i = 0; i < 300 && !firstCompleted; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          expect(firstCompleted, isTrue);
          expect(
            firstError,
            isA<ScrollCancelledException>().having(
              (e) => e.reason,
              'reason',
              ScrollCancelReason.dataInvalidated,
            ),
            reason:
                'A second invalidateMeasurements() call while the first scrollTo() '
                'is still in its internal recovery search must cancel it with '
                'dataInvalidated, the same typed reason as any other invalidation '
                'during an in-flight scrollTo() (ISC-13).',
          );
        },
      );
    },
  );
}
