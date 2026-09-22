import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-26/ISC-28: `watch()` indices that form the full `0..n-1` set, but in
/// the WRONG order relative to physical slot position.
///
/// ISC-27 fixed the contract: `watch(index:)` must equal the physical
/// position of the row as passed to `itemBuilder`. The existing continuity
/// check (`_sizeOrThrow`, ISC-03/ISC-12A) only verifies that every logical
/// index from 0 up to the scroll target is *present* in `_sizes`; it cannot
/// tell that an index was registered by the wrong physical slot -- a
/// permutation of `0..n-1` leaves every key present, just attached to the
/// wrong row.
///
/// ISC-28 closes that gap: `_RenderIndexedScrollItem.performLayout()`
/// (lib/src/indexed_scroll_item.dart) reads its own physical slot from
/// `SliverMultiBoxAdaptorParentData.index` on `parentData` and passes it to
/// `IndexedScrollController._registerSize`, which records a mismatch
/// against the logical index whenever the two disagree
/// (`_watchIndexMismatches`, lib/src/indexed_scroll_controller.dart).
/// `scrollTo()` checks that record (`_checkNoWatchIndexMismatch`) once a
/// prefix is otherwise complete, on both the already-measured fast path and
/// after the internal search pass, and throws `StateError` before summing a
/// mismatched prefix into an offset -- instead of the silent wrong-success
/// documented for reordering in test/scroll_to_mutated_data_test.dart
/// (scenario A) and test/render_object_registration_test.dart (test 3).
/// `invalidateMeasurements()` does NOT fix a permutation by itself: the
/// caller must pass the corrected physical positions to `watch(index:)`.
void main() {
  group('ISC-26: watch() index permutation of 0..n-1 (full set, wrong order)',
      () {
    // Five rows, distinct non-uniform heights so a scrambled order produces a
    // numerically obvious discrepancy between "sum by logical index" (what
    // the current code does) and "sum by physical slot" (the true on-screen
    // offset). heights[logicalIndex] is the height of the row whose content
    // identity is `logicalIndex`.
    const itemCount = 5;
    final heights = [100.0, 200.0, 300.0, 150.0, 250.0]; // sum = 1000

    // Physical slot -> logical index, a permutation of 0..4 where NO slot
    // maps to its own index (a derangement), so this cannot be mistaken for
    // a partial/no-op reorder. Built directly into the itemBuilder from the
    // very first pump, not introduced by a later setState -- this is the
    // "full set 0..n-1, but wrong order" case the task asks for, distinct
    // from the mutated_data test's runtime reorder scenario.
    //   slot 0 -> logical 4 (h=250)
    //   slot 1 -> logical 0 (h=100)
    //   slot 2 -> logical 3 (h=150)
    //   slot 3 -> logical 1 (h=200)
    //   slot 4 -> logical 2 (h=300)
    const slotToLogical = [4, 0, 3, 1, 2];

    Widget buildPermutedList(IndexedScrollController controller) {
      return MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: itemCount,
            itemBuilder: (context, slotPosition) {
              final logicalIndex = slotToLogical[slotPosition];
              return controller.watch(
                index: logicalIndex,
                child: Container(
                  height: heights[logicalIndex],
                  color: Colors.blue,
                  child: Center(
                      child: Text('slot=$slotPosition logical=$logicalIndex')),
                ),
              );
            },
          ),
        ),
      );
    }

    testWidgets(
      'full 0..n-1 set is present in _sizes despite wrong order -- the existing '
      'continuity check does not and cannot catch a permutation',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await tester.pumpWidget(buildPermutedList(controller));
        await tester.pumpAndSettle();

        final measurements = controller.measurementsSizes;

        // All five items fit in the default test viewport (600px tall,
        // 1000px content) simultaneously, so every slot builds and measures
        // on the first pump -- no scrolling/search pass needed to observe
        // the full set.
        expect(
          measurements.keys.toSet(),
          equals({0, 1, 2, 3, 4}),
          reason: 'Every logical index 0..4 is present exactly once: the '
              'permutation registers each key under its own logical index '
              '(ISC-11 fix), so the map is indistinguishable, by key set '
              'alone, from the non-permuted identity mapping.',
        );

        // Each size is keyed correctly by logical index -- registration
        // itself (ISC-11) is not in question here, only what scrollTo() does
        // with a logically-correct-but-visually-scrambled map.
        expect(measurements[0]?.height, closeTo(100.0, 1.0));
        expect(measurements[1]?.height, closeTo(200.0, 1.0));
        expect(measurements[2]?.height, closeTo(300.0, 1.0));
        expect(measurements[3]?.height, closeTo(150.0, 1.0));
        expect(measurements[4]?.height, closeTo(250.0, 1.0));
      },
    );

    testWidgets(
      'scrollTo() to an already-measured permuted index throws StateError before '
      'completing, instead of silently landing at the wrong (logical-order) offset',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await tester.pumpWidget(buildPermutedList(controller));
        await tester.pumpAndSettle();

        // Ask for logical index 2 (h=300), which the permutation places at
        // physical slot 4 -- the LAST slot on screen.
        //
        // TRUE visual offset would be the sum of heights of rows actually
        // ABOVE slot 4 in physical order [4,0,3,1,2] -> slots 0..3 -> logical
        // 4,0,3,1 -> heights 250+100+150+200 = 700.0 px. scrollTo()'s fast
        // path (already measured, no search needed) sums `_sizes[i]` for i
        // in `0..<targetItemIndex` -- i.e. by LOGICAL index order, not
        // physical slot order -- which would silently land at 300.0px
        // instead. ISC-28's mismatch check fires before that summation ever
        // happens: slot 1 registered logical index 0 (mismatch: physical 1
        // != logical 0), so scrollTo(2) must fail loudly instead of reaching
        // either 300.0px or 700.0px.
        final initialOffset = controller.position.pixels;

        await expectLater(
          controller.scrollTo(2.0, duration: const Duration(milliseconds: 100)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('watch(index: 0)'),
            ),
          ),
        );

        expect(
          controller.position.pixels,
          equals(initialOffset),
          reason: 'The rejected call must not move the position at all -- the '
              'mismatch is caught before any offset is applied, on the '
              'already-measured fast path.',
        );
      },
    );

    testWidgets(
      'a single transposition inside 0..n-1: both the search-pass target (past the '
      'swap) and the already-measured fast-path target (inside the swap) throw '
      'StateError instead of completing at a wrong offset',
      (WidgetTester tester) async {
        // Use a taller list so the target is off-screen at first pump and a
        // genuine multi-step search pass (not the already-measured fast
        // path) is exercised -- distinct code path from the previous test.
        const searchItemCount = 20;
        const rowHeight = 100.0;
        const tallRowHeight = 300.0;

        // Single transposition: only slots 5 and 6 swap their logical
        // indices (5<->6); every other slot, including the target's slot
        // and everything before it, is identity (slot == logical). This is
        // still a genuine full 0..n-1 permutation with no fixed point at
        // the swap itself, but -- unlike a reversal or a pair-swap-
        // everywhere scheme -- it keeps logical index 0 visible at the very
        // first pump (slot 0 is untouched), which scrollTo()'s
        // minVisibleIndex computation requires to even start (it walks
        // _sizes from index 0), AND it keeps the scan window
        // 0..<targetIndex free of any *gap* (every slot from 0 up to the
        // target's slot is still visited and measured on the way, just two
        // of them carry swapped identities). A pair-swap-everywhere scheme
        // was tried first and produced a genuine contiguity gap (StateError
        // on index 14) rather than isolating the permutation mechanism this
        // test exists to characterize. Row 6 (the row that ends up carrying
        // logical index 5, after the swap) is given a distinct height so
        // the swap changes the summed total, not just which two entries
        // contribute to it -- a swap of two equal-height rows would leave
        // the logical-order sum numerically identical to the correct one by
        // coincidence, which would not demonstrate anything.
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        double heightForSlot(int slot) => slot == 6 ? tallRowHeight : rowHeight;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: searchItemCount,
                itemBuilder: (context, slotPosition) {
                  final logicalIndex = slotPosition == 5
                      ? 6
                      : slotPosition == 6
                          ? 5
                          : slotPosition;
                  return controller.watch(
                    index: logicalIndex,
                    child: SizedBox(
                      height: heightForSlot(slotPosition),
                      child: Center(
                          child:
                              Text('slot=$slotPosition logical=$logicalIndex')),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Ask for logical index 12, which sits at slot 12 (untouched by the
        // swap, comfortably off-screen -- only ~6 of the 20 rows fit in the
        // default 600px test viewport -- forcing the multi-step search
        // pass, not the already-measured fast path). The search pass walks
        // forward from slot 0, measuring every row along the way, including
        // slots 5 and 6 -- where the transposition lives. By the time the
        // search reaches slot 12, _watchIndexMismatches already holds
        // entries for logical indices 5 and 6 (registered by slots 6 and 5
        // respectively), so _checkNoWatchIndexMismatch must reject the call
        // before it ever sums a prefix, regardless of whether the target
        // itself sits before or after the swap.
        const beforeSwapTarget = 12.0;

        // The target is off-screen, so this exercises the multi-step search
        // pass, not the already-measured fast path -- it only makes progress
        // across pumped frames (each step awaits a real layout), so this uses
        // the manual pump loop, not expectLater alone (which never pumps a
        // frame while awaiting and would hang forever on a Future that can
        // only resolve via pumped frames).
        Object? scrollError;
        bool scrollCompleted = false;
        unawaited(
          controller
              .scrollTo(beforeSwapTarget,
                  duration: const Duration(milliseconds: 100))
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
          isA<StateError>(),
          reason: 'A transposition strictly before the target index would have '
              'changed which _sizes entries get summed but not their total '
              '(the pre-ISC-28 code coincidentally landed on the correct '
              '1400.0px here) -- but ISC-28 rejects the call outright once '
              'the search pass measures the mismatched slots 5/6, before any '
              'coincidence about the sum can even be reached.',
        );

        // Now target logical index 6, which the swap physically relocated
        // to slot 5 -- INSIDE the swapped pair, where (pre-ISC-28) the two
        // sums would have actually diverged. jumpTo(0) first and re-settle
        // so this second scrollTo() exercises the already-measured fast
        // path cleanly (every index up to 6 was already measured by the
        // first scrollTo's search pass above, even though that call itself
        // was rejected -- the search still advanced the scroll position and
        // populated _sizes before throwing).
        controller.jumpTo(0.0);
        await tester.pumpAndSettle();

        const targetLogicalIndex = 6.0;
        final offsetBeforeSecondAttempt = controller.position.pixels;

        await expectLater(
          controller.scrollTo(targetLogicalIndex,
              duration: const Duration(milliseconds: 100)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('watch(index: 5)'),
            ),
          ),
          reason:
              'Index $targetLogicalIndex was already measured by the earlier '
              'search pass, so this call takes the already-measured fast '
              'path -- and it must still reject rather than complete at the '
              'buggy 800.0px (which would have included the tall 300px row '
              'registered under logical index 5) or coincidentally reach the '
              'true 500.0px visual offset. The mismatch on logical index 5 '
              '(registered by physical slot 6) is what the fast path must '
              'catch.',
        );

        expect(
          controller.position.pixels,
          equals(offsetBeforeSecondAttempt),
          reason: 'The rejected fast-path call must not move the position.',
        );
      },
    );

    testWidgets(
      'invalidateMeasurements() does not fix the permutation -- scrollTo() keeps '
      'throwing StateError before and after, because the mismatch record is '
      're-derived from the same still-wrong watch(index:) values, not stale cache data',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await tester.pumpWidget(buildPermutedList(controller));
        await tester.pumpAndSettle();

        // Baseline, mirroring the second test above: without invalidation,
        // scrollTo(2) is rejected by the mismatch check on logical index 0
        // (registered by physical slot 1).
        final offsetBeforeAttempt = controller.position.pixels;
        await expectLater(
          controller.scrollTo(2.0, duration: const Duration(milliseconds: 100)),
          throwsA(isA<StateError>()),
        );
        final offsetBeforeInvalidate = controller.position.pixels;
        expect(
          offsetBeforeInvalidate,
          equals(offsetBeforeAttempt),
          reason: 'The rejected baseline call must not move the position.',
        );

        // Every permuted row is still on screen (5 rows, 600px viewport), so
        // invalidateMeasurements() immediately re-registers all five live
        // rows under their (unchanged) logical indices -- the reset is real,
        // not a no-op, but it re-derives exactly the same logically-keyed
        // map, and the same mismatches, as before, because the permutation
        // itself never changed and registration was already correct by
        // logical index (ISC-11) -- only the physical/logical *relationship*
        // is wrong, and invalidation cannot fix that on its own.
        controller.invalidateMeasurements();
        await tester.pump();

        final measurementsAfterInvalidate = controller.measurementsSizes;
        expect(
          measurementsAfterInvalidate.keys.toSet(),
          equals({0, 1, 2, 3, 4}),
          reason:
              'invalidateMeasurements() re-registers the full live set immediately.',
        );
        expect(measurementsAfterInvalidate[0]?.height, closeTo(100.0, 1.0));
        expect(measurementsAfterInvalidate[1]?.height, closeTo(200.0, 1.0));

        final offsetBeforeSecondAttempt = controller.position.pixels;
        await expectLater(
          controller.scrollTo(2.0, duration: const Duration(milliseconds: 100)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('watch(index: 0)'),
            ),
          ),
          reason: 'invalidateMeasurements() does NOT fix the permutation: the '
              'same watch(index: 0) mismatch (physical slot 1) is '
              're-registered from the same, still-wrong itemBuilder, so '
              'scrollTo(2) is rejected the same way as before invalidation. '
              'This matches ISC-27\'s finding for reordering (test/'
              'scroll_to_mutated_data_test.dart scenario A) and ISC-13\'s '
              'finding before it: the gap is not stale cache data -- '
              'invalidateMeasurements() correctly clears and re-measures -- '
              'it is that the caller\'s watch(index:) values never changed. '
              'A cache reset cannot fix an itemBuilder that is still wrong.',
        );
        expect(
          controller.position.pixels,
          equals(offsetBeforeSecondAttempt),
          reason:
              'The rejected post-invalidation call must not move the position either.',
        );
      },
    );
  });
}
