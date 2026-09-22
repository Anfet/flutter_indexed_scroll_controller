import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-42: reproduces the defect the automatic fingerprint mode (ISC-41/45/46)
/// exists to fix, using the [IndexedScrollController.itemCount]/
/// [IndexedScrollController.contentFingerprint] constructor surface added by
/// ISC-44.
///
/// An off-screen row's content changes to a different height with no
/// intervening rebuild of that row and, critically, no call to
/// `invalidateMeasurements()`. `scrollTo()` does not yet consult
/// `contentFingerprint` (that lands in ISC-46), so it still sums the row's
/// stale, pre-mutation size. This test asserts BOTH the currently-observed
/// (stale, wrong) offset and the true post-mutation offset numerically, so it
/// fails loudly -- red -- until ISC-46 makes `scrollTo()` detect the
/// fingerprint mismatch and re-measure before completing.
///
/// No `jumpTo(0)` (or any other rebuild of the mutated row) appears anywhere
/// in this test before the probing `scrollTo()`: doing so would force a fresh
/// layout of the stale row and silently fix the very staleness this test
/// exists to observe.
void main() {
  testWidgets(
    'ISC-42: off-screen row content change is not detected without invalidateMeasurements()',
    (WidgetTester tester) async {
      const itemCount = 30;
      const viewportHeight = 600.0;
      const defaultHeight = 100.0;
      const mutatedIndex = 2;
      const oldHeight = defaultHeight;
      const newHeight = 400.0;

      final heights = List<double>.filled(itemCount, defaultHeight);
      final fingerprints = List<int>.filled(itemCount, 0);

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
        contentFingerprint: (index) => fingerprints[index],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: viewportHeight,
              child: ListView.builder(
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  return controller.watch(
                    index: index,
                    child: SizedBox(
                      height: heights[index],
                      child: Text('index=$index'),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Step 1: measure `mutatedIndex` at its original height by scrolling to it.
      unawaited(
        controller.scrollTo(mutatedIndex.toDouble(),
            duration: const Duration(milliseconds: 100)),
      );
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        controller.measurementsSizes[mutatedIndex]?.height,
        closeTo(oldHeight, 1.0),
        reason:
            'Index $mutatedIndex must be measured at its original height before mutation.',
      );

      // Step 2: scroll far away so `mutatedIndex` is off-screen and unbuilt.
      unawaited(controller.scrollTo(25.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        controller.position.pixels,
        greaterThan(viewportHeight),
        reason:
            'Must have scrolled far enough that index $mutatedIndex is off-screen.',
      );

      // Step 3: mutate the off-screen row's height AND its fingerprint, with no
      // rebuild of that row and no invalidateMeasurements() call. A caller
      // using the automatic mode is expected to bump the fingerprint whenever
      // the row's on-axis size may have changed; this is exactly that case.
      heights[mutatedIndex] = newHeight;
      fingerprints[mutatedIndex] = 1;

      expect(
        controller.measurementsSizes[mutatedIndex]?.height,
        closeTo(oldHeight, 1.0),
        reason:
            'Directly observed: _sizes[$mutatedIndex] still holds the stale '
            'height $oldHeight immediately after the off-screen mutation, since '
            'nothing rebuilt that row.',
      );

      // Step 4: probe with scrollTo() targeting an already-measured index past
      // the mutation, with NO jumpTo(0) or other rebuild of mutatedIndex in
      // between. This is the already-measured fast path: it sums _sizes
      // directly without a search pass.
      const staleOffset = mutatedIndex * defaultHeight + oldHeight;
      const correctOffset = mutatedIndex * defaultHeight + newHeight;

      unawaited(
        controller.scrollTo((mutatedIndex + 1).toDouble(),
            duration: const Duration(milliseconds: 100)),
      );
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final observedOffset = controller.position.pixels;

      expect(
        observedOffset,
        closeTo(correctOffset, 1.0),
        reason: 'ISC-42 (red until ISC-46): scrollTo() must detect that '
            "contentFingerprint($mutatedIndex) changed and re-measure before "
            'completing, reaching the true post-mutation offset $correctOffset '
            'px (using the new height $newHeight). Today it still sums the '
            'stale cached size and lands at $staleOffset px instead, because '
            'scrollTo() does not yet call contentFingerprint at all (ISC-46).',
      );
    },
  );
}
