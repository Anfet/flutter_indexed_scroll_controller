import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'support/scroll_harness.dart';

/// ISC-79: separator() as a standalone controller entity, with ScrollAlignmentTarget
/// letting scrollTo's alignment measure against the item alone instead of the
/// row+separator whole.
///
/// Covers the accepted API surface described in todo.md: the sibling-slot
/// `ListView.separated` form (item at physical slot `2*i`, separator at
/// `2*i + 1`, both registered through their own controller methods), the
/// physical-slot mismatch check (conflict 1's resolution), and the rejected
/// nested-marker misuse (conflict 2's resolution).
void main() {
  group('ISC-79: separator() basic registration', () {
    testWidgets(
        'separator(index: i) registers a size independent of watch(index: i)',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await tester.pumpWidget(_SeparatedHarness(
          controller: controller,
          itemCount: 5,
          itemExtent: 80.0,
          separatorExtent: 20.0));
      await tester.pumpAndSettle();

      expect(controller.measurementsSizes[0]?.height, closeTo(80.0, 0.5),
          reason:
              'watch(index: 0) must register only the item, not the item+separator.');
      expect(controller.hasSeparatorFor(0), isTrue);
      expect(controller.separatorSizes[0]?.height, closeTo(20.0, 0.5));
    });

    testWidgets(
        'last item has no separator, and that is legitimate (no StateError from registration)',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await tester.pumpWidget(_SeparatedHarness(
          controller: controller,
          itemCount: 5,
          itemExtent: 80.0,
          separatorExtent: 20.0));
      await tester.pumpAndSettle();

      expect(controller.hasSeparatorFor(4), isFalse,
          reason:
              'ListView.separated never builds a trailing separator after the last item.');
    });

    testWidgets(
        'a marker with an empty child registers a legitimate zero-size separator, distinct from no marker at all',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _SeparatedHarness(
            controller: controller,
            itemCount: 5,
            itemExtent: 80.0,
            separatorExtent: 0.0),
      );
      await tester.pumpAndSettle();

      expect(controller.hasSeparatorFor(0), isTrue,
          reason: 'The marker reported, even though its child was zero-size.');
      expect(controller.separatorSizes[0]?.height, closeTo(0.0, 0.5));
    });
  });

  group('ISC-79: prefix sum includes separators regardless of alignmentTarget',
      () {
    testWidgets(
        'scrollTo(itemIndex) with the sibling-slot form reaches the offset that includes preceding separators',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      const itemExtent = 80.0;
      const separatorExtent = 20.0;
      await tester.pumpWidget(
        _SeparatedHarness(
            controller: controller,
            itemCount: 20,
            itemExtent: itemExtent,
            separatorExtent: separatorExtent),
      );
      await tester.pumpAndSettle();

      await pumpUntilComplete(
          tester,
          controller.scrollTo(10.0,
              duration: const Duration(milliseconds: 100)));

      // 10 preceding items (80px) + 10 preceding separators (20px) = 1000.0,
      // matching the number the architect's decision measured for this form.
      expect(controller.position.pixels, closeTo(1000.0, 1.0));
    });

    testWidgets(
        'alignmentTarget: item and alignmentTarget: row agree in the sibling-slot form',
        (tester) async {
      final controllerRow = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      final controllerItem = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controllerRow.dispose);
      addTearDown(controllerItem.dispose);

      const itemExtent = 80.0;
      const separatorExtent = 20.0;
      await tester.pumpWidget(_SeparatedHarness(
          controller: controllerRow,
          itemCount: 20,
          itemExtent: itemExtent,
          separatorExtent: separatorExtent));
      await tester.pumpAndSettle();
      await pumpUntilComplete(
          tester,
          controllerRow.scrollTo(10.0,
              alignment: 1.0, duration: const Duration(milliseconds: 100)));
      final rowOffset = controllerRow.position.pixels;

      await tester.pumpWidget(_SeparatedHarness(
          controller: controllerItem,
          itemCount: 20,
          itemExtent: itemExtent,
          separatorExtent: separatorExtent));
      await tester.pumpAndSettle();
      await pumpUntilComplete(
        tester,
        controllerItem.scrollTo(10.0,
            alignment: 1.0,
            alignmentTarget: ScrollAlignmentTarget.item,
            duration: const Duration(milliseconds: 100)),
      );
      final itemOffset = controllerItem.position.pixels;

      expect(itemOffset, closeTo(rowOffset, 0.5),
          reason:
              'In the sibling-slot form, a row\'s own _sizes entry never includes its separator, so both targets read the same extent.');
    });
  });

  group('ISC-79: conflict 1 — physical slot mismatch under separator mode', () {
    testWidgets(
        'a row that passes its physical slot instead of its logical index still trips the mismatch check',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      // A derangement of logical indices 0..2 across physical item slots
      // 0, 2, 4 (ListView.separated's item slots), same technique as
      // test/scroll_watch_index_order_test.dart's plain-list version: every
      // logical index 0..2 is still present in _sizes (so this is not a
      // missing-prefix scenario the search loop would stall on), just
      // attached to the wrong physical row. No slot maps to its own index.
      //   physical item slot 0 (logical 0's slot) -> logical index 1
      //   physical item slot 2 (logical 1's slot) -> logical index 0
      //   physical item slot 4 (logical 2's slot) -> logical index 2 (kept
      //     fixed: a 2-cycle derangement of {0, 1} already suffices for a
      //     3-item list, and this test only needs indices 0 and 1 to be
      //     swapped -- see the comment on scrollTo(1.0) below).
      const slotItemToLogical = [1, 0, 2];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.separated(
              controller: controller,
              itemCount: 3,
              separatorBuilder: (context, i) => controller.separator(
                  index: i, child: const SizedBox(height: 20.0)),
              itemBuilder: (context, slotPosition) {
                final logicalIndex = slotItemToLogical[slotPosition];
                return controller.watch(
                    index: logicalIndex,
                    child: SizedBox(
                        height: 80.0,
                        child:
                            Text('slot=$slotPosition logical=$logicalIndex')));
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Logical indices 0 and 1 are both present in _sizes (swapped, not
      // missing), so _hasCompletePrefix(1) is already true and this
      // resolves on the fast path -- scrollTo(1.0) alone is enough to force
      // _checkNoWatchIndexMismatch to inspect both.
      Object? error;
      await controller
          .scrollTo(1.0, duration: const Duration(milliseconds: 100))
          .catchError((Object e) {
        error = e;
      });

      expect(error, isA<StateError>(),
          reason:
              'A full permutation of logical indices across separated-mode item slots must still be caught.');
    });

    testWidgets(
        'an ordinary (non-separated) list is unaffected by the 2*index slot check',
        (tester) async {
      // Guards against the slot-comparison change accidentally weakening the
      // plain ListView.builder case: no separator ever registers here, so
      // _separatorModeActive stays false and physical must equal logical,
      // same as before ISC-79.
      await tester.pumpWidget(
        ScrollHarness(itemCount: 30, itemHeightBuilder: (_) => 50.0),
      );
      final state =
          tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      await pumpUntilComplete(
          tester,
          state.controller
              .scrollTo(10.0, duration: const Duration(milliseconds: 100)));
      expect(state.controller.position.pixels, closeTo(500.0, 1.0));
    });
  });

  group('ISC-79: conflict 2 — nested separator is rejected, not double-counted',
      () {
    testWidgets(
        'separator(index: i) nested inside watch(index: i)\'s own subtree throws StateError instead of double-counting',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      // A single row: performLayout() throws once per offending row, and
      // Flutter's test framework cannot recover a single StateError out of
      // several simultaneous RenderObject layout failures ("Multiple
      // exceptions (N) were detected") the way it can from exactly one.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemCount: 1,
              itemBuilder: (context, i) => controller.watch(
                index: i,
                // Misuse: separator() wrapped INSIDE the same row's watch()
                // subtree, which is the ISC-76 form's shape, not the
                // sibling-slot form separator() is for.
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 80.0, child: Text('Item')),
                    controller.separator(
                        index: i, child: const SizedBox(height: 20.0)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final exception = tester.takeException();
      expect(exception, isA<StateError>());
      expect((exception as StateError).message, contains('nested inside'));
    });
  });

  group('ISC-79: invalidateMeasurements clears the separator cache', () {
    testWidgets(
        'separator sizes and separator mode reset on invalidateMeasurements',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await tester.pumpWidget(_SeparatedHarness(
          controller: controller,
          itemCount: 5,
          itemExtent: 80.0,
          separatorExtent: 20.0));
      await tester.pumpAndSettle();
      expect(controller.hasSeparatorFor(0), isTrue);

      controller.invalidateMeasurements();
      expect(controller.separatorSizes.isEmpty, isTrue,
          reason:
              'A stale separator entry must not survive invalidateMeasurements(), or alignmentTarget: item could reuse a size that belongs to a discarded data version.');

      // A live separator still on screen re-registers on its next layout.
      await tester.pump();
      expect(controller.hasSeparatorFor(0), isTrue,
          reason:
              'The still-live separator relays out and re-registers after invalidation.');
    });
  });

  group(
      'ISC-79: a missing separator between existing rows is an error, not a silent zero',
      () {
    testWidgets(
        'separatorBuilder that forgets separator() for one index throws StateError, not offset 0',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      const itemCount = 5;
      const itemExtent = 80.0;
      const separatorExtent = 20.0;
      // Every item registers (0..4 are all present in _sizes, so this is not
      // a missing-prefix scenario), but separatorBuilder forgets to wrap
      // index 1's separator with separator(index: 1, ...) -- it builds a
      // plain Divider instead, so _separatorSizes never gets an entry for 1,
      // even though item 2 (the next row) is known to exist.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.separated(
              controller: controller,
              itemCount: itemCount,
              separatorBuilder: (context, i) => i == 1
                  ? const SizedBox(height: separatorExtent)
                  : controller.separator(
                      index: i, child: const SizedBox(height: separatorExtent)),
              itemBuilder: (context, i) => controller.watch(
                  index: i, child: const SizedBox(height: itemExtent)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.hasSeparatorFor(1), isFalse,
          reason: 'Sanity check: index 1 truly has no registered separator.');
      expect(controller.measurementsSizes.containsKey(2), isTrue,
          reason: 'Sanity check: item 2 (the next row) is known to exist.');

      Object? error;
      await controller
          .scrollTo(3.0, duration: const Duration(milliseconds: 100))
          .catchError((Object e) {
        error = e;
      });

      expect(error, isA<StateError>(),
          reason:
              'A separator missing between two rows that both exist must throw, not silently contribute zero to the prefix sum.');
      expect((error as StateError).message, contains('index 1'));
    });
  });

  group('ISC-79: separator() with no matching watch() is rejected', () {
    testWidgets(
        'separator(index: i) for an index this list never builds throws StateError on the next scrollTo',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      // itemBuilder only ever calls watch() for indices 0..2 (itemCount: 3),
      // but a separate, unrelated marker registers a separator for index 50
      // -- an index this list never builds a row for at all. An orphaned
      // separator's index can never itself fall inside a prefix
      // _hasCompletePrefix already found complete (that would require
      // watch() to have run for it too, which is the opposite of orphaned),
      // so _checkNoOrphanSeparators scans the whole separator map on every
      // scrollTo call, regardless of that call's own target -- confirmed
      // here with a small, easily-reached target (0.0) that has nothing to
      // do with index 50 itself.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  height: 400,
                  child: ListView.separated(
                    controller: controller,
                    itemCount: 3,
                    separatorBuilder: (context, i) => controller.separator(
                        index: i, child: const SizedBox(height: 20.0)),
                    itemBuilder: (context, i) => controller.watch(
                        index: i, child: const SizedBox(height: 80.0)),
                  ),
                ),
                controller.separator(
                    index: 50, child: const SizedBox(height: 20.0)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.hasSeparatorFor(50), isTrue,
          reason: 'Sanity check: the orphaned separator did register.');
      expect(controller.measurementsSizes.containsKey(50), isFalse,
          reason: 'Sanity check: no row exists at index 50.');

      Object? error;
      await controller
          .scrollTo(0.0, duration: const Duration(milliseconds: 100))
          .catchError((Object e) {
        error = e;
      });

      expect(error, isA<StateError>(),
          reason:
              'A separator registered for an index with no matching watch() must be rejected, not silently ignored.');
      expect((error as StateError).message, contains('index 50'));
    });
  });

  group('ISC-79: two separator() registrations for the same index are rejected',
      () {
    testWidgets(
        'a second, different separator render object under the same index throws StateError',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      // Two independent separator() markers, both claiming index 0, built as
      // siblings in the same frame -- neither is a relayout of the other
      // (different GlobalKeys keep Flutter from reusing one RenderObject for
      // both), so this is a genuine ambiguous double-registration, not an
      // ordinary rebuild.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(
                    height: 80.0,
                    child: controller.watch(
                        index: 0, child: const SizedBox(height: 80.0))),
                KeyedSubtree(
                  key: const ValueKey('sep-a'),
                  child: controller.separator(
                      index: 0, child: const SizedBox(height: 20.0)),
                ),
                KeyedSubtree(
                  key: const ValueKey('sep-b'),
                  child: controller.separator(
                      index: 0, child: const SizedBox(height: 30.0)),
                ),
              ],
            ),
          ),
        ),
      );

      final exception = tester.takeException();
      expect(exception, isA<StateError>());
      expect((exception as StateError).message,
          contains('Two different separator'));
    });
  });

  group('ISC-79: alignmentTarget: item is unavailable without separator mode',
      () {
    testWidgets(
        'requesting item alignment on a list that never used separator() throws StateError',
        (tester) async {
      await tester.pumpWidget(
        ScrollHarness(itemCount: 20, itemHeightBuilder: (_) => 100.0),
      );
      final state =
          tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      Object? error;
      await state.controller
          .scrollTo(5.0,
              alignmentTarget: ScrollAlignmentTarget.item,
              duration: const Duration(milliseconds: 100))
          .catchError((Object e) {
        error = e;
      });

      expect(error, isA<StateError>());
      expect((error as StateError).message, contains('alignmentTarget'));
    });
  });
}

/// A minimal `ListView.separated` harness wired through
/// [IndexedScrollController.watch]/[IndexedScrollController.separator], per
/// the ISC-79 accepted API form.
class _SeparatedHarness extends StatelessWidget {
  final IndexedScrollController controller;
  final int itemCount;
  final double itemExtent;
  final double separatorExtent;

  const _SeparatedHarness({
    required this.controller,
    required this.itemCount,
    required this.itemExtent,
    required this.separatorExtent,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView.separated(
          controller: controller,
          itemCount: itemCount,
          separatorBuilder: (context, i) => controller.separator(
            index: i,
            child: SizedBox(height: separatorExtent),
          ),
          itemBuilder: (context, i) => controller.watch(
            index: i,
            child: SizedBox(height: itemExtent, child: Text('Item $i')),
          ),
        ),
      ),
    );
  }
}
