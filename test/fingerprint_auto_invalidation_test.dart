import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-43: widget tests for the automatic fingerprint-based invalidation
/// contract (ISC-41/refactor.md), built on the [IndexedScrollController.itemCount]/
/// [IndexedScrollController.contentFingerprint] constructor surface added by
/// ISC-44.
///
/// `scrollTo()` does not yet consult either callback -- that lands in
/// ISC-46 -- so every scenario here that requires automatic detection is
/// expected to be RED until then. Each assertion is a concrete pixel offset
/// or a concrete call-count, not a tautology, so "red" and "green" are both
/// numerically unambiguous. None of these tests call
/// `invalidateMeasurements()` -- that would defeat the point of testing the
/// automatic path -- and none jump/rebuild a mutated row before probing,
/// since that would silently fix the very staleness under test.
void main() {
  group('ISC-43: automatic fingerprint invalidation', () {
    testWidgets(
        'visible-row replacement with a different height is picked up immediately by watch()',
        (
      WidgetTester tester,
    ) async {
      // A visible row is rebuilt by Flutter on the very next frame regardless
      // of the automatic mode -- watch() always registers whatever it is
      // actually handed. This is the baseline "not even a defect" case: it
      // must already be green today, independent of ISC-46.
      const itemCount = 10;
      final heights = List<double>.filled(itemCount, 100.0);
      final fingerprints = List<int>.filled(itemCount, 0);
      late StateSetter setState_;

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
        contentFingerprint: (index) => fingerprints[index],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setState_ = setState;
                return ListView.builder(
                  controller: controller,
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    return controller.watch(
                      index: index,
                      child: SizedBox(
                          height: heights[index], child: Text('index=$index')),
                    );
                  },
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.measurementsSizes[0]?.height, closeTo(100.0, 1.0));

      setState_(() {
        heights[0] = 250.0;
        fingerprints[0] = 1;
      });
      await tester.pumpAndSettle();

      expect(
        controller.measurementsSizes[0]?.height,
        closeTo(250.0, 1.0),
        reason:
            'A visible row is rebuilt and re-measured by watch() on the next frame '
            'regardless of the automatic mode; this must already hold without ISC-46.',
      );
    });

    testWidgets(
        'a real rebuild with unchanged fingerprints reuses the cached size, no forced re-scan',
        (
      WidgetTester tester,
    ) async {
      const itemCount = 10;
      final heights = List<double>.filled(itemCount, 100.0);
      final fingerprints = List<int>.filled(itemCount, 0);
      var rebuildCounter = 0;
      late StateSetter setState_;

      // ISC-56: a log of every index contentFingerprint() is called for, so
      // this test can prove scrollTo() actually READ the target's
      // fingerprint -- not merely that it didn't re-measure it, which is
      // also (trivially) true on today's controller, where scrollTo() never
      // calls contentFingerprint() at all because ISC-46 hasn't landed yet.
      final fingerprintCallLog = <int>[];

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
        contentFingerprint: (index) {
          fingerprintCallLog.add(index);
          return fingerprints[index];
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200.0,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setState_ = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      return controller.watch(
                        index: index,
                        // Keyed by rebuildCounter so setState_(() {
                        // rebuildCounter++; }) below forces Flutter to
                        // discard and recreate this row's RenderObject
                        // (rather than merely updating the existing one with
                        // identical geometry, which performLayout()'s own
                        // "constraints/size unchanged" fast path could skip
                        // entirely) -- a real, verifiable rebuild that always
                        // runs performLayout() at least once, matching what
                        // ISC-55 requires this test to actually exercise.
                        child: SizedBox(
                          key: ValueKey('row-$index-rebuild-$rebuildCounter'),
                          height: heights[index],
                          child: Text('index=$index rebuild=$rebuildCounter'),
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

      unawaited(controller.scrollTo(5.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      const firstOffset = 5 * 100.0;
      expect(controller.position.pixels, closeTo(firstOffset, 1.0));

      // ISC-55: the rebuild below runs while the viewport sits at offset
      // 500.0, i.e. showing indices 5-6 (2 rows of 100.0 in a 200.0
      // viewport), so THOSE are the indices this setState() actually
      // rebuilds -- not 0-1, which are off-screen (unmounted) at this point
      // and whose itemBuilder does not run at all here. Any assertion must
      // therefore target 5-6, the rows genuinely touched by this rebuild.
      final rebuiltVisibleIndices = [5, 6];

      // ISC-56: snapshot registrationCountFor() BEFORE the rebuild too, so
      // the "did the rebuild really re-measure this row" claim is proven by
      // observing growth across the rebuild, not by asserting a hardcoded
      // absolute count -- Flutter's own layout-elision strategy for a
      // reused RenderObject is an internal implementation detail this test
      // must not depend on.
      final registrationCountsBeforeRebuild = {
        for (final i in rebuiltVisibleIndices)
          i: controller.registrationCountFor(i),
      };

      // A genuine rebuild of every currently-visible row, with nothing in
      // the underlying data changed: fingerprints are still all equal to
      // what was last measured, so the cached sizes remain valid and a
      // later scrollTo() targeting the SAME viewport window must reach the
      // same offset without re-measuring these rows.
      setState_(() {
        rebuildCounter++;
      });
      await tester.pumpAndSettle();

      // ISC-55: snapshot registrationCountFor() for the rows the rebuild
      // above actually touched (5-6), taken immediately after that rebuild
      // settles -- not after an intervening scroll to a different viewport
      // window, which would unmount them and make any later re-registration
      // just Flutter's own lazy rebuilding of a newly-visible row, unrelated
      // to fingerprint checking. This directly connects the measured
      // registration to the row that was really rebuilt, per ISC-55.
      final registrationCountsAfterRebuild = {
        for (final i in rebuiltVisibleIndices)
          i: controller.registrationCountFor(i),
      };
      for (final i in rebuiltVisibleIndices) {
        expect(
          registrationCountsAfterRebuild[i],
          greaterThan(registrationCountsBeforeRebuild[i]!),
          reason:
              'Index $i must show MORE registrations after the setState() rebuild '
              'than before it: the rebuild forces its keyed SizedBox to be recreated (a '
              'genuine performLayout() pass, not merely an update Flutter could elide). '
              'If the count did not grow, the rebuild did not actually re-measure the '
              'row and the assertions below would prove nothing about fingerprint reuse.',
        );
      }

      // ISC-56: clear the fingerprint call log right before the probing
      // scrollTo, so what it records below is attributable only to THAT
      // call -- not to the initial scrollTo(5), the rebuild, or anything
      // else that ran earlier in this test.
      fingerprintCallLog.clear();

      // Probe with a target that keeps the SAME rows (5-6) mounted
      // throughout -- alignment: 1 asks for index 5's bottom at the
      // viewport bottom, i.e. offset 500.0 + 100.0 - 200.0 = 400.0, which
      // still shows indices 4-5 (not 5-6), so use a tiny fractional target
      // instead: scrollTo(5.01) recomputes the same offset (still ~500.0,
      // clamped to the same rows) via the already-measured fast path
      // without moving the viewport far enough to mount/unmount anything.
      final registrationCountsBeforeProbe = {
        for (final i in rebuiltVisibleIndices)
          i: controller.registrationCountFor(i),
      };
      unawaited(controller.scrollTo(5.01,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        controller.position.pixels,
        closeTo(firstOffset, 2.0),
        reason:
            'scrollTo(5.01) must land within the same viewport window as scrollTo(5), '
            'so indices 5-6 stay mounted throughout and the registration counts below '
            'are attributable only to this scrollTo call, not to an intervening '
            'mount/unmount.',
      );

      // ISC-56: prove scrollTo() actually READ the target's fingerprint --
      // this is what distinguishes "fingerprint checked, equal, size
      // reused" from "the automatic mode never ran at all" (both leave
      // registrationCountFor unchanged, but only the former is the
      // behavior this test is meant to characterize). The prefix relevant
      // to index 5 is 0..5, so index 5 itself must appear in the log
      // scrollTo(5.01) produced.
      expect(
        fingerprintCallLog,
        contains(5),
        reason: 'ISC-56 (red until ISC-46): scrollTo(5.01) must call '
            'contentFingerprint(5) while checking the 0..5 prefix. Without this, an '
            'unchanged registrationCountFor(5) is also trivially true on a controller '
            'where scrollTo() never consults contentFingerprint at all, so it cannot by '
            'itself prove the automatic mode ran and found an equal fingerprint.',
      );

      for (final i in rebuiltVisibleIndices) {
        expect(
          controller.registrationCountFor(i),
          registrationCountsBeforeProbe[i],
          reason:
              'Equal fingerprints must not force index $i to be re-measured by '
              'scrollTo(5.01) alone -- index $i is the row this test\'s rebuild actually '
              'touched, and it stays mounted (never leaves the viewport) during this '
              'probing scroll, so any extra registration for it could only come from an '
              'unwanted forced re-scan. A count that grew while _sizes.length stayed the '
              'same would mean the row was laid out again and its (unchanged) size '
              'silently overwrote the existing cache entry -- exactly the case '
              '_sizes.length cannot detect.',
        );
      }
    });

    testWidgets(
        'fingerprint change with the same resulting height still requires re-measurement',
        (
      WidgetTester tester,
    ) async {
      // The contract (refactor.md) is explicit: a changed fingerprint marks
      // the old size as untrustworthy even if the NEW height happens to be
      // numerically identical, because the controller cannot know the new
      // height in advance -- only the caller's fingerprint promise tells it
      // whether the old size may still be summed. This is observable via the
      // fingerprint callback being invoked for the position at scrollTo time,
      // not via a different final offset (which is indistinguishable here).
      const itemCount = 10;
      const rowHeight = 100.0;
      final fingerprints = List<int>.filled(itemCount, 0);
      final calledForIndex = <int>{};

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
        contentFingerprint: (index) {
          calledForIndex.add(index);
          return fingerprints[index];
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200.0,
              child: ListView.builder(
                controller: controller,
                itemCount: itemCount,
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

      unawaited(controller.scrollTo(5.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.position.pixels, closeTo(5 * rowHeight, 1.0));

      calledForIndex.clear();
      fingerprints[2] =
          1; // identity/content changed, height happens to stay 100.0

      final recovery = controller.scrollTo(
        5.0,
        duration: const Duration(milliseconds: 100),
      );
      final expectedError = expectLater(recovery, throwsA(isA<StateError>()));
      await tester.pumpAndSettle();
      await expectedError;

      expect(
        calledForIndex.contains(2),
        isTrue,
        reason:
            'ISC-43 (red until ISC-46): scrollTo() must call contentFingerprint(2) '
            'while checking the 0..5 prefix before rejecting the old child '
            'version that was never rebuilt.',
      );
    });

    testWidgets(
        'off-screen insertion before the target is detected without invalidateMeasurements()',
        (
      WidgetTester tester,
    ) async {
      const viewportHeight = 600.0;
      const defaultHeight = 100.0;
      const insertAt = 2;
      const insertedHeight = 400.0;

      var itemCountValue = 30;
      List<String> contentIds =
          List<String>.generate(itemCountValue, (i) => 'orig$i');
      final heights = <String, double>{};

      double heightFor(String id) =>
          id == 'INSERTED' ? insertedHeight : (heights[id] ?? defaultHeight);

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCountValue,
        contentFingerprint: (index) => contentIds[index],
      );
      late StateSetter setOuterState;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCountValue,
                    itemBuilder: (context, index) {
                      return controller.watch(
                        index: index,
                        child: SizedBox(
                            height: heightFor(contentIds[index]),
                            child: Text('index=$index')),
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

      unawaited(controller.scrollTo(5.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      unawaited(controller.scrollTo(25.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.position.pixels, greaterThan(viewportHeight));

      // Insert while insertAt is off-screen: itemCount grows, and every index
      // from insertAt onward now maps to a different contentId (fingerprint).
      // The architect's decision on Regression A (todo.md): the widget tree's
      // own itemCount must be kept in sync via setState, exactly as a real
      // ListView-backed app would -- the wide fingerprint-corridor walk this
      // controller now performs is entitled to touch any index whose
      // fingerprint changed, including ones the OLD (unsynced) tree could
      // never have built a row for.
      setOuterState(() {
        itemCountValue += 1;
        contentIds = [
          ...contentIds.sublist(0, insertAt),
          'INSERTED',
          ...contentIds.sublist(insertAt),
        ];
      });

      const correctOffset = insertAt * defaultHeight + insertedHeight;

      unawaited(
        controller.scrollTo((insertAt + 1).toDouble(),
            duration: const Duration(milliseconds: 100)),
      );
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        controller.position.pixels,
        closeTo(correctOffset, 1.0),
        reason:
            'ISC-43 (red until ISC-46): an off-screen insertion changes the '
            'fingerprint of every index at or after $insertAt, so scrollTo() must '
            'detect it without an explicit invalidateMeasurements() call and reach '
            '$correctOffset px.',
      );
    });

    testWidgets(
        'off-screen deletion before the target is detected without invalidateMeasurements()',
        (
      WidgetTester tester,
    ) async {
      const viewportHeight = 600.0;
      const defaultHeight = 100.0;
      const deleteAt = 2;
      const survivorHeight = 400.0;

      var itemCountValue = 30;
      List<String> contentIds = List<String>.generate(
        itemCountValue,
        (i) => i == deleteAt
            ? 'del'
            : i == deleteAt + 1
                ? 'SURV'
                : 'orig$i',
      );

      double heightFor(String id) =>
          id == 'SURV' ? survivorHeight : defaultHeight;

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCountValue,
        contentFingerprint: (index) => contentIds[index],
      );
      late StateSetter setOuterState;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCountValue,
                    itemBuilder: (context, index) {
                      return controller.watch(
                        index: index,
                        child: SizedBox(
                            height: heightFor(contentIds[index]),
                            child: Text('index=$index')),
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

      unawaited(controller.scrollTo(5.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      unawaited(controller.scrollTo(25.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.position.pixels, greaterThan(viewportHeight));

      // The architect's decision on Regression A (todo.md): the widget
      // tree's own itemCount must be kept in sync via setState, exactly as a
      // real ListView-backed app would -- the wide fingerprint-corridor walk
      // this controller now performs is entitled to touch any index whose
      // fingerprint changed, including ones the OLD (unsynced) tree could
      // never have built a row for.
      setOuterState(() {
        itemCountValue -= 1;
        contentIds = [
          ...contentIds.sublist(0, deleteAt),
          ...contentIds.sublist(deleteAt + 1),
        ];
      });

      const correctOffset = deleteAt * defaultHeight + survivorHeight;

      unawaited(
        controller.scrollTo((deleteAt + 1).toDouble(),
            duration: const Duration(milliseconds: 100)),
      );
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        controller.position.pixels,
        closeTo(correctOffset, 1.0),
        reason: 'ISC-43 (red until ISC-46): an off-screen deletion changes the '
            'fingerprint of every index at or after $deleteAt, so scrollTo() must '
            'detect it without an explicit invalidateMeasurements() call and reach '
            '$correctOffset px.',
      );
    });

    testWidgets(
        'same-index content replacement with a different height is detected',
        (WidgetTester tester) async {
      const itemCount = 10;
      const viewportHeight = 200.0;
      const defaultHeight = 100.0;
      const targetIndex = 7;
      const newHeight = 350.0;

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
                        height: heights[index], child: Text('index=$index')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      unawaited(controller.scrollTo(targetIndex.toDouble(),
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.measurementsSizes[targetIndex]?.height,
          closeTo(defaultHeight, 1.0));

      unawaited(controller.scrollTo(0.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.position.pixels, lessThan(viewportHeight),
          reason: 'Target row must now be off-screen.');

      heights[targetIndex] = newHeight;
      fingerprints[targetIndex] = 1;

      // A fractional target (rather than an integer one) makes the target
      // row's OWN extent part of the offset formula (priorItems + extent *
      // fraction), so the stale (100.0) and fresh (350.0) sizes for
      // targetIndex diverge numerically, unlike alignment: 0 on an integer
      // target, which never reads the target's own extent at all.
      const fraction = 0.5;
      const staleOffset =
          targetIndex * defaultHeight + defaultHeight * fraction;
      const correctOffset = targetIndex * defaultHeight + newHeight * fraction;
      expect(correctOffset, isNot(closeTo(staleOffset, 1.0)),
          reason:
              'Sanity check: the two candidate offsets must actually differ.');

      unawaited(
        controller.scrollTo(targetIndex + fraction,
            duration: const Duration(milliseconds: 100)),
      );
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        controller.position.pixels,
        closeTo(correctOffset, 1.0),
        reason:
            'ISC-43 (red until ISC-46): the target itself changed size at the same '
            'logical index; scrollTo() must use the new height ($newHeight, not the '
            'stale $defaultHeight) when computing the fractional offset within the '
            'target row, landing at $correctOffset px, not the stale $staleOffset px.',
      );
    });

    testWidgets(
        'scrollTo(0, alignment: 1) after the first row changes uses the new size',
        (
      WidgetTester tester,
    ) async {
      const itemCount = 10;
      // A viewport shorter than either candidate height keeps `extent -
      // viewportHeight` positive for BOTH the stale and fresh height, so
      // neither offset clamps to minScrollExtent (0.0) -- unlike a tall
      // viewport, where both candidates would clamp to the same value and
      // the test could pass without the target's fingerprint ever being
      // checked.
      const viewportHeight = 50.0;
      const oldHeight = 100.0;
      const newHeight = 300.0;

      final heights = List<double>.filled(itemCount, oldHeight);
      final fingerprints = List<int>.filled(itemCount, 0);
      late StateSetter setState_;

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
              child: StatefulBuilder(
                builder: (context, setState) {
                  setState_ = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      return controller.watch(
                        index: index,
                        child: SizedBox(
                            height: heights[index],
                            child: Text('index=$index')),
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

      unawaited(controller.scrollTo(0.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.measurementsSizes[0]?.height, closeTo(oldHeight, 1.0));

      // Scroll away so row 0 is off-screen when its height changes, then
      // change it WITHOUT rebuilding it in between (no jumpTo(0) here).
      unawaited(controller.scrollTo(8.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      setState_(() {
        heights[0] = newHeight;
        fingerprints[0] = 1;
      });
      // Deliberately no pumpAndSettle()/rebuild of row 0 here: it is
      // off-screen, so this setState alone does not rebuild it.

      // alignment: 1 asks for row 0's BOTTOM at the viewport bottom, i.e. an
      // offset of `extent - viewportHeight`. Both the stale (100.0) and
      // fresh (300.0) heights exceed viewportHeight (50.0), so this offset
      // stays positive -- and different -- for each candidate instead of
      // both clamping to the same minScrollExtent (0.0), which is what a
      // taller viewport would produce.
      const staleTargetPixels = oldHeight - viewportHeight;
      const correctTargetPixels = newHeight - viewportHeight;
      expect(
        correctTargetPixels,
        isNot(closeTo(staleTargetPixels, 1.0)),
        reason: 'Sanity check: the two candidate offsets must actually differ.',
      );

      unawaited(controller.scrollTo(0.0,
          alignment: 1.0, duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        controller.position.pixels,
        closeTo(correctTargetPixels, 1.0),
        reason:
            'ISC-43 (red until ISC-46): scrollTo(0, alignment: 1) must check the '
            "target's OWN fingerprint and use its new height ($newHeight), landing at "
            '$correctTargetPixels px, not the stale cached height ($oldHeight) which '
            'would land at $staleTargetPixels px.',
      );
    });

    testWidgets('changed index 20 with target 10 does not force a jump to 20',
        (WidgetTester tester) async {
      const itemCount = 30;
      const viewportHeight = 600.0;
      const defaultHeight = 100.0;
      const changedIndex = 20;
      const newHeight = 500.0;

      final heights = List<double>.filled(itemCount, defaultHeight);
      final fingerprints = List<int>.filled(itemCount, 0);

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
        contentFingerprint: (index) => fingerprints[index],
      );

      final maxPixelsSeen = <double>[];

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
                        height: heights[index], child: Text('index=$index')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Measure through the whole list once so 0..29 are all cached, then
      // return to the top -- changedIndex ends up off-screen but measured.
      unawaited(controller.scrollTo(29.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      unawaited(controller.scrollTo(0.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      heights[changedIndex] = newHeight;
      fingerprints[changedIndex] = 1;

      const correctOffset =
          10 * defaultHeight; // index 20's size is irrelevant to target 10

      final generationBefore = controller.measurementGeneration;

      unawaited(
        controller
            .scrollTo(10.0, duration: const Duration(milliseconds: 100))
            .then((_) {}),
      );
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        maxPixelsSeen.add(controller.position.pixels);
      }

      expect(
        controller.position.pixels,
        closeTo(correctOffset, 1.0),
        reason:
            'Index $changedIndex is past target 10; its size must not be required to '
            'compute this target.',
      );
      expect(
        maxPixelsSeen.every((p) => p <= changedIndex * defaultHeight),
        isTrue,
        reason:
            'ISC-43: reaching target 10 must not involve a detour toward changed '
            'index $changedIndex; every observed offset must stay well short of it.',
      );
      expect(
        controller.measurementGeneration,
        generationBefore,
        reason:
            'A fingerprint mismatch outside the 0..10 prefix must not trigger a '
            'cache reset at all -- scrollTo(10) never even scans index 20, so it has no '
            'way to notice that mismatch and must not reset the cache "just in case".',
      );
    });

    testWidgets(
        'changed index 10 with target 20 requires index 10 to be re-measured first',
        (
      WidgetTester tester,
    ) async {
      const itemCount = 30;
      const viewportHeight = 600.0;
      const defaultHeight = 100.0;
      const changedIndex = 10;
      const newHeight = 500.0;

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
                        height: heights[index], child: Text('index=$index')),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      unawaited(controller.scrollTo(29.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      unawaited(controller.scrollTo(0.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      heights[changedIndex] = newHeight;
      fingerprints[changedIndex] = 1;

      // Indices 11..19 are unaffected and may be reused as-is.
      final generationBeforeRecovery = controller.measurementGeneration;
      const correctOffset = changedIndex * defaultHeight +
          newHeight +
          (19 - changedIndex) * defaultHeight;

      unawaited(controller.scrollTo(20.0,
          duration: const Duration(milliseconds: 100)));
      for (int i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        controller.position.pixels,
        closeTo(correctOffset, 1.0),
        reason:
            'ISC-43 (red until ISC-46): index $changedIndex is below target 20, so its '
            'new size ($newHeight) must be resolved via watch()/layout before computing '
            "target 20's offset; reusing the stale size would land short at "
            '${changedIndex * defaultHeight + defaultHeight + (19 - changedIndex) * defaultHeight} px instead.',
      );
      expect(
        controller.measurementGeneration,
        generationBeforeRecovery,
        reason: 'ISC-51: recovering index $changedIndex must preserve the '
            'cached measurements for 11..19 instead of falling back to a '
            'full cache reset. SliverList may still choose to lay out those '
            'children while it updates its own geometry.',
      );
    });

    testWidgets(
        'an ordinary rebuild with unchanged fingerprints does not scan itemCount',
        (
      WidgetTester tester,
    ) async {
      const itemCount = 1000;
      const rowHeight = 100.0;
      final fingerprints = List<int>.filled(itemCount, 0);
      var itemCountCalls = 0;
      late StateSetter setState_;

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () {
          itemCountCalls++;
          return itemCount;
        },
        contentFingerprint: (index) => fingerprints[index],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setState_ = setState;
                return ListView.builder(
                  controller: controller,
                  itemCount: itemCount,
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
      );
      await tester.pumpAndSettle();

      itemCountCalls = 0;
      // An unrelated rebuild (no data change) must not scan the whole list.
      setState_(() {});
      await tester.pumpAndSettle();

      expect(
        itemCountCalls,
        0,
        reason:
            'A plain rebuild with nothing changed must not invoke itemCount() at all; '
            'only a scrollTo() call is documented to trigger the automatic check.',
      );
    });

    testWidgets('a user drag does not scan itemCount',
        (WidgetTester tester) async {
      const itemCount = 1000;
      const rowHeight = 100.0;
      final fingerprints = List<int>.filled(itemCount, 0);
      var itemCountCalls = 0;

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () {
          itemCountCalls++;
          return itemCount;
        },
        contentFingerprint: (index) => fingerprints[index],
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
                  child:
                      SizedBox(height: rowHeight, child: Text('index=$index')),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      itemCountCalls = 0;
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(
        itemCountCalls,
        0,
        reason:
            'A user drag must not invoke itemCount(); only scrollTo() triggers the '
            'automatic fingerprint check.',
      );
    });
  });
}
