import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'support/scroll_harness.dart';

/// ISC-81: regression coverage for the four claims README.md's "Lists with
/// separators" section makes about separator-list behavior, none of which
/// had a test before this file (confirmed by search: no `separated` mention
/// anywhere under test/ prior to ISC-81). All four expected numbers were
/// measured during ISC-76's acceptance and are reproduced here as fixed
/// values, not re-derived.
///
/// Item height 80px, separator height 20px throughout, so the primary form's
/// combined row height is 100px and a scroll to logical index 10 (10 whole
/// rows preceding it) lands at 1000.0px.
void main() {
  group('ISC-81: primary form — ListView.builder, one watch() per row, separator inside the row', () {
    testWidgets('scrollTo(10) reaches exactly 1000.0 and the target row\'s top sits at the viewport top', (tester) async {
      final controller = IndexedScrollController(scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      const itemCount = 20;
      const itemExtent = 80.0;
      const separatorExtent = 20.0;
      const rowKey = Key('target-row');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemCount: itemCount,
              itemBuilder: (context, index) => controller.watch(
                index: index,
                child: Column(
                  key: index == 10 ? rowKey : null,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: itemExtent),
                    if (index < itemCount - 1) const SizedBox(height: separatorExtent),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await pumpUntilComplete(tester, controller.scrollTo(10.0, duration: const Duration(milliseconds: 100)));

      // README's exact claim: scrollTo(10) with 80px items + 20px separators
      // reaches 1000.0 (10 whole preceding rows of 100px each).
      expect(controller.position.pixels, closeTo(1000.0, 1.0));

      // "top of row at top of viewport" is a visual claim -- a completed
      // Future proves the offset landed, not that the row's Rect is where
      // alignment: 0 (the default) promises. Verify the actual on-screen
      // position, per this project's rule that visual-position claims need
      // tester.getRect(), not just an awaited scrollTo().
      final viewportTop = tester.getTopLeft(find.byType(ListView)).dy;
      final rowTop = tester.getTopLeft(find.byKey(rowKey)).dy;
      expect(rowTop, closeTo(viewportTop, 1.0));
    });
  });

  group('ISC-81: fallback form — ListView.separated with both items and separators wrapped by physical slot', () {
    testWidgets('watch() on physical slot 20 (item index 10) reaches exactly 1000.0', (tester) async {
      final controller = IndexedScrollController(scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      const itemCount = 20;
      const itemExtent = 80.0;
      const separatorExtent = 20.0;

      // The fallback form README documents: wrap BOTH items and separators
      // by their physical slot (2 * index for items, 2 * index + 1 for
      // separators), then scrollTo() also takes a physical slot, not a
      // logical item index. This is a distinct, older mechanism from ISC-79's
      // separator() -- plain watch() calls on every physical child, with no
      // separator() involved at all.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.separated(
              controller: controller,
              itemCount: itemCount,
              separatorBuilder: (context, i) => controller.watch(
                index: 2 * i + 1,
                child: const SizedBox(height: separatorExtent),
              ),
              itemBuilder: (context, i) => controller.watch(
                index: 2 * i,
                child: const SizedBox(height: itemExtent),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // README's exact claim: slot 20 (item index 10, 2 * 10) reaches 1000.0.
      await pumpUntilComplete(tester, controller.scrollTo(20.0, duration: const Duration(milliseconds: 100)));
      expect(controller.position.pixels, closeTo(1000.0, 1.0));
    });

    testWidgets('wrapping only items in ListView.separated (the documented anti-pattern) throws StateError, not a silently wrong offset',
        (tester) async {
      final controller = IndexedScrollController(scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      const itemCount = 20;
      const itemExtent = 80.0;
      const separatorExtent = 20.0;

      // README's explicit "do not" case: only itemBuilder calls watch(),
      // separatorBuilder builds a plain, unwrapped Divider. watch() indices
      // then skip every odd physical slot (0, 1, 2, 3... vs. physical
      // 0, 2, 4, 6...), which the continuity contract rejects.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.separated(
              controller: controller,
              itemCount: itemCount,
              separatorBuilder: (context, i) => const SizedBox(height: separatorExtent),
              itemBuilder: (context, i) => controller.watch(
                index: i,
                child: const SizedBox(height: itemExtent),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The mismatch is only observable once _hasCompletePrefix(10) holds --
      // logical indices 0..19 are contiguous in _sizes despite each one's
      // physical slot being 2 * index, so the search loop must actually run
      // (a bare unpumped await never resolves) before the mismatch check
      // can fire on the fast path.
      Object? error;
      var settled = false;
      unawaited(
        controller.scrollTo(10.0, duration: const Duration(milliseconds: 100)).then(
          (_) => settled = true,
          onError: (Object e) {
            error = e;
            settled = true;
          },
        ),
      );
      for (int i = 0; i < 300 && !settled; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      // Measured at ISC-76's acceptance: this misuse gives StateError, not a
      // silently-wrong offset of 500.0 (10 * 80.0, ignoring the separators
      // watch() never saw).
      expect(error, isA<StateError>(),
          reason: 'Wrapping only items in ListView.separated must fail loudly, not silently land at the wrong (separator-blind) offset.');
      expect(controller.position.pixels, isNot(closeTo(500.0, 1.0)),
          reason: 'The documented anti-pattern must not silently succeed at the separator-blind offset.');
    });
  });

  group('ISC-81: primary form, alignment: 1 measures against the whole row, separator included', () {
    testWidgets('alignment: 1 puts the item\'s bottom one separator-height above the viewport bottom', (tester) async {
      final controller = IndexedScrollController(scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      const itemCount = 20;
      const itemExtent = 80.0;
      const separatorExtent = 20.0;
      const itemKey = Key('target-item');

      // Same primary form as the first group, but the target index's own
      // child SizedBox is keyed (not the wrapping Column) so its Rect
      // measures the item alone, distinct from the row (item + separator)
      // that alignment is actually computed against here -- alignmentTarget
      // is left at its default (row), which is what this test asserts about.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemCount: itemCount,
              itemBuilder: (context, index) => controller.watch(
                index: index,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(key: index == 10 ? itemKey : null, height: itemExtent),
                    if (index < itemCount - 1) const SizedBox(height: separatorExtent),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await pumpUntilComplete(tester, controller.scrollTo(10.0, alignment: 1.0, duration: const Duration(milliseconds: 100)));

      final viewport = tester.getRect(find.byType(ListView));
      final itemRect = tester.getRect(find.byKey(itemKey));

      // Measured at ISC-76's acceptance: alignment: 1 on the whole-row
      // default puts the ITEM's bottom exactly one separator-height (20px)
      // above the viewport bottom, because alignment measures against the
      // row (item + trailing separator), not the item alone -- the
      // separator "eats" 20px of what alignment: 1 would otherwise give the
      // item. (ISC-79's alignmentTarget: item exists specifically to change
      // this; this test is the pre-ISC-79 baseline default behavior.)
      final deltaBottom = itemRect.bottom - viewport.bottom;
      expect(deltaBottom, closeTo(-separatorExtent, 1.0));
    });
  });
}
