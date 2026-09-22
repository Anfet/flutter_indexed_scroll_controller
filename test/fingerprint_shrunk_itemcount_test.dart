import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-57: a target beyond a SHRUNK list must be rejected with [RangeError]
/// before the automatic mode's stale full prefix is ever summed.
///
/// Without the upfront `itemCount()` bound check, `_hasFingerprintMismatchInPrefix`
/// only ever scans up to the new (smaller) `itemCount`, so it silently stops
/// at the new end without noticing that the target itself is now out of
/// range -- the stale, still-complete, still-fingerprint-matching OLD prefix
/// then sums to a "successful" offset for a row that no longer exists.
void main() {
  group('ISC-57: scrollTo rejects a target beyond a shrunk itemCount', () {
    testWidgets(
      'shrinking itemCount via a real rebuild then requesting the deleted index throws RangeError, '
      'does not call contentFingerprint past the new end, and does not move to a stale offset',
      (WidgetTester tester) async {
        const originalItemCount = 30;
        const shrunkItemCount = 10;
        const rowHeight = 100.0;
        const viewportHeight = 600.0;

        var currentItemCount = originalItemCount;
        final fingerprints = List<int>.filled(originalItemCount, 0);
        final fingerprintCallLog = <int>[];

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
          itemCount: () => currentItemCount,
          contentFingerprint: (index) {
            fingerprintCallLog.add(index);
            return fingerprints[index];
          },
        );

        late StateSetter setState_;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: viewportHeight,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setState_ = setState;
                    return ListView.builder(
                      controller: controller,
                      itemCount: currentItemCount,
                      itemBuilder: (context, index) {
                        return controller.watch(
                          index: index,
                          child: SizedBox(
                              height: rowHeight, child: Text('index=$index')),
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

        // Step 1: measure the full original prefix by scrolling through the
        // entire original list once.
        unawaited(
          controller.scrollTo((originalItemCount - 1).toDouble(),
              duration: const Duration(milliseconds: 100)),
        );
        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          controller.measurementsSizes.length,
          originalItemCount,
          reason:
              'Every original index must be measured before the list shrinks.',
        );

        // Step 2: shrink itemCount and the underlying data via a REAL
        // rebuild -- ListView.builder itself now reports the smaller count,
        // and the deleted rows' content is gone, not merely hidden.
        setState_(() {
          currentItemCount = shrunkItemCount;
        });
        await tester.pumpAndSettle();

        // Captured AFTER the shrink settles, not before: Flutter's own list
        // reflow (fewer/shorter rows -> smaller maxScrollExtent) legitimately
        // moves the position on its own here, independent of this
        // controller. What ISC-57 must prove is that the REJECTED scrollTo()
        // below does not move the position any further from wherever this
        // reflow already left it.
        final offsetBeforeRejectedScroll = controller.position.pixels;

        // Step 3: request an index that only existed in the OLD list. The
        // stale cache still holds a complete, fingerprint-matching prefix
        // for 0..(originalItemCount - 1) -- nothing invalidated it -- so
        // without ISC-57's upfront bound check this would otherwise sum
        // straight to a "successful" offset for a deleted row.
        const deletedIndex = originalItemCount - 1;
        fingerprintCallLog.clear();

        Object? caughtError;
        var completed = false;
        unawaited(
          controller
              .scrollTo(deletedIndex.toDouble(),
                  duration: const Duration(milliseconds: 100))
              .then(
            (_) => completed = true,
            onError: (Object e) {
              caughtError = e;
              completed = true;
            },
          ),
        );
        for (int i = 0; i < 300 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(completed, isTrue,
            reason:
                'scrollTo() must settle (success or error) within the frame budget.');
        expect(
          caughtError,
          isA<RangeError>(),
          reason:
              'ISC-57: a target at or beyond the shrunk itemCount ($shrunkItemCount) must be '
              'rejected with RangeError, even though the stale cache still has a complete, '
              'fingerprint-matching prefix for the OLD list.',
        );
        expect(
          fingerprintCallLog.where((i) => i >= shrunkItemCount).toList(),
          isEmpty,
          reason:
              'ISC-57: contentFingerprint() must never be called for an index at or beyond '
              'the current itemCount -- the bound check must reject the target before any '
              'fingerprint scan runs at all.',
        );
        expect(
          controller.position.pixels,
          offsetBeforeRejectedScroll,
          reason:
              'ISC-57: rejecting the out-of-range target must not move the position at all, '
              'in particular not to the stale offset the old (deleted) row would have summed to.',
        );
      },
    );

    testWidgets(
      'a target still within the shrunk itemCount succeeds normally',
      (WidgetTester tester) async {
        const originalItemCount = 30;
        const shrunkItemCount = 10;
        const rowHeight = 100.0;
        // Small enough that the shrunk list's maxScrollExtent (900.0, for 10
        // rows of 100.0) comfortably exceeds the target offset below, so
        // the assertion is not confused by clamping the way a viewport
        // close to or larger than the shrunk content would be.
        const viewportHeight = 100.0;

        var currentItemCount = originalItemCount;
        final fingerprints = List<int>.filled(originalItemCount, 0);

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
          itemCount: () => currentItemCount,
          contentFingerprint: (index) => fingerprints[index],
        );

        late StateSetter setState_;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: viewportHeight,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setState_ = setState;
                    return ListView.builder(
                      controller: controller,
                      itemCount: currentItemCount,
                      itemBuilder: (context, index) {
                        return controller.watch(
                          index: index,
                          child: SizedBox(
                              height: rowHeight, child: Text('index=$index')),
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

        unawaited(
          controller.scrollTo((originalItemCount - 1).toDouble(),
              duration: const Duration(milliseconds: 100)),
        );
        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        setState_(() {
          currentItemCount = shrunkItemCount;
        });
        await tester.pumpAndSettle();

        const survivingIndex = shrunkItemCount - 1;
        const correctOffset = survivingIndex * rowHeight;

        unawaited(controller.scrollTo(survivingIndex.toDouble(),
            duration: const Duration(milliseconds: 100)));
        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          controller.position.pixels,
          closeTo(correctOffset, 1.0),
          reason:
              'ISC-57: the bound check must only reject targets at or beyond itemCount, not '
              'every scrollTo() after a shrink -- a still-valid index must keep working normally.',
        );
      },
    );
  });

  group('ISC-58: itemCount() is snapshotted for entry validation', () {
    testWidgets(
        'a rejected (out-of-range) scrollTo() calls itemCount() exactly once',
        (WidgetTester tester) async {
      const itemCountValue = 10;
      const rowHeight = 100.0;
      const viewportHeight = 100.0;
      var itemCountCalls = 0;

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () {
          itemCountCalls++;
          return itemCountValue;
        },
        contentFingerprint: (index) => 0,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: viewportHeight,
              child: ListView.builder(
                controller: controller,
                itemCount: itemCountValue,
                itemBuilder: (context, index) {
                  return controller.watch(
                    index: index,
                    child: SizedBox(
                        height: rowHeight, child: Text('index=$index')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      itemCountCalls = 0;

      Object? caughtError;
      unawaited(
        controller.scrollTo(itemCountValue.toDouble()).catchError((Object e) {
          caughtError = e;
        }),
      );
      await tester.pump();

      expect(caughtError, isA<RangeError>(),
          reason:
              'scrollTo(itemCount) is exactly one past the last valid index.');
      expect(
        itemCountCalls,
        1,
        reason:
            'ISC-58: a single scrollTo() call -- rejected or not -- must call itemCount() '
            'exactly once. Calling it again for the error message or for a fingerprint scan '
            'that never actually runs (this call is rejected before either) would let the '
            'checked bound and the value actually reported/used silently diverge if itemCount() '
            'returned something different on a second call.',
      );
    });

    testWidgets(
        'a successful multi-frame scrollTo() rechecks itemCount() after awaits',
        (WidgetTester tester) async {
      const itemCountValue = 30;
      const rowHeight = 100.0;
      const viewportHeight = 100.0;
      var itemCountCalls = 0;
      final fingerprints = List<int>.filled(itemCountValue, 0);

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () {
          itemCountCalls++;
          return itemCountValue;
        },
        contentFingerprint: (index) => fingerprints[index],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: viewportHeight,
              child: ListView.builder(
                controller: controller,
                itemCount: itemCountValue,
                itemBuilder: (context, index) {
                  return controller.watch(
                    index: index,
                    child: SizedBox(
                        height: rowHeight, child: Text('index=$index')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      itemCountCalls = 0;

      unawaited(controller.scrollTo(5.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.position.pixels, closeTo(5 * rowHeight, 1.0));

      expect(
        itemCountCalls,
        greaterThan(1),
        reason:
            'ISC-47: the entry snapshot validates the requested index, then every await '
            'rechecks current data before another search step can use an old target.',
      );

      // A second operation gets its own entry snapshot and its own liveness
      // checks; neither operation may reuse the other operation's data view.
      itemCountCalls = 0;
      unawaited(controller.scrollTo(10.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.position.pixels, closeTo(10 * rowHeight, 1.0));
      expect(itemCountCalls, greaterThan(1));
    });
  });
}
