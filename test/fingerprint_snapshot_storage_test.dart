import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-45: widget tests for the fingerprint-snapshot storage plumbing
/// (`_fingerprints`, threaded from `watch()` through `IndexedScrollItem`
/// into `_RenderIndexedScrollItem.performLayout()`).
///
/// This only tests that the (Size, fingerprint) pair is stored correctly
/// per index -- `scrollTo()` does not read `_fingerprints` at all yet, so
/// every scenario here is independent of ISC-46 and expected to be GREEN.
void main() {
  group('ISC-45: fingerprint snapshot storage', () {
    testWidgets(
        'manual mode (no contentFingerprint) never records a fingerprint entry',
        (
      WidgetTester tester,
    ) async {
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemCount: 5,
              itemBuilder: (context, index) {
                return controller.watch(
                  index: index,
                  child: const SizedBox(height: 100.0),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.measurementsSizes[0], isNotNull,
          reason: 'Size registration is unaffected by the manual mode.');
      expect(
        controller.hasFingerprintFor(0),
        isFalse,
        reason:
            'A controller built without contentFingerprint must never record a '
            'fingerprint entry, even though its rows still register sizes normally.',
      );
    });

    testWidgets(
        'build/layout registers the fingerprint captured at build time alongside the Size',
        (
      WidgetTester tester,
    ) async {
      const itemCount = 5;
      final fingerprints = List<Object?>.filled(itemCount, 'v0');

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
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
                  child: const SizedBox(height: 100.0),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.measurementsSizes[0]?.height, closeTo(100.0, 1.0));
      expect(controller.hasFingerprintFor(0), isTrue);
      expect(controller.fingerprintFor(0), 'v0');
    });

    testWidgets(
        'contentFingerprint returning null is stored as a present entry with value null',
        (
      WidgetTester tester,
    ) async {
      const itemCount = 3;

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
        contentFingerprint: (index) => null,
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
                  child: const SizedBox(height: 100.0),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The critical distinction: hasFingerprintFor(0) must be true (an
      // entry WAS recorded) even though fingerprintFor(0) is null (that
      // entry's VALUE is null) -- containsKey, not "value is non-null", is
      // the presence check, exactly per contentFingerprint's contract that
      // null is an ordinary allowed fingerprint value.
      expect(
        controller.hasFingerprintFor(0),
        isTrue,
        reason:
            'A row whose fingerprint genuinely IS null must still show a present '
            'entry, distinguishing it from an index that was never measured at all.',
      );
      expect(controller.fingerprintFor(0), isNull);

      expect(
        controller.hasFingerprintFor(999),
        isFalse,
        reason:
            'An index that was never registered must show no entry at all -- the '
            'same "no entry" state as a null-valued entry would produce if presence '
            'were checked via value nullability instead of containsKey.',
      );
    });

    testWidgets(
        'invalidateMeasurements() clears both the size and its fingerprint together',
        (
      WidgetTester tester,
    ) async {
      const itemCount = 5;
      final fingerprints = List<Object?>.filled(itemCount, 'v0');

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
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
                  child: const SizedBox(height: 100.0),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.hasFingerprintFor(0), isTrue);

      controller.invalidateMeasurements();

      expect(
        controller.measurementsSizes.containsKey(0),
        isFalse,
        reason: 'invalidateMeasurements() clears _sizes.',
      );
      expect(
        controller.hasFingerprintFor(0),
        isFalse,
        reason:
            'invalidateMeasurements() must clear _fingerprints in the same step, so '
            'no fingerprint entry outlives the Size it was paired with -- a stale '
            'fingerprint surviving here could later appear to validate a size registered '
            'by an unrelated, future performLayout() pass.',
      );
    });

    testWidgets(
        're-measuring a corrected index after invalidateMeasurements() registers the new fingerprint',
        (
      WidgetTester tester,
    ) async {
      const itemCount = 5;
      final fingerprints = List<Object?>.filled(itemCount, 'v0');
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
                      child: const SizedBox(height: 100.0),
                    );
                  },
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.fingerprintFor(0), 'v0');

      // Mutate the data AND invalidate, exactly per the manual-mode
      // contract: invalidateMeasurements() clears the pair and forces every
      // live row through performLayout() again, which re-derives a fresh
      // fingerprint snapshot at the next build -- captured via the
      // StatefulBuilder rebuild below, before that layout runs.
      fingerprints[0] = 'v1';
      controller.invalidateMeasurements();
      setState_(() {});
      await tester.pumpAndSettle();

      expect(controller.measurementsSizes[0]?.height, closeTo(100.0, 1.0));
      expect(
        controller.hasFingerprintFor(0),
        isTrue,
        reason:
            'The corrected index must have a fresh fingerprint entry after being '
            're-measured, not remain in the "cleared, never re-registered" state.',
      );
      expect(
        controller.fingerprintFor(0),
        'v1',
        reason:
            'The re-registered fingerprint must be the NEW value captured at the '
            'rebuild that produced the child actually laid out, not the old v0 snapshot '
            'invalidateMeasurements() discarded.',
      );
    });

    testWidgets(
        'a fingerprint change alone, with no relayout, does not update the stored snapshot',
        (
      WidgetTester tester,
    ) async {
      // Per the ISC-41 contract: reading contentFingerprint fresh inside
      // performLayout (rather than using the build-time snapshot) risks
      // attaching a newer fingerprint to an old child's Size. This test
      // proves the OPPOSITE failure mode does not happen either: if a row's
      // fingerprint changes but nothing forces that row through a new
      // build+layout pass, the OLD (Size, fingerprint) pair must stay
      // exactly as it was -- neither half silently updated on its own.
      const itemCount = 5;
      final fingerprints = List<Object?>.filled(itemCount, 'v0');

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
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
                  child: const SizedBox(height: 100.0),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.fingerprintFor(0), 'v0');
      final sizeBefore = controller.measurementsSizes[0];

      // Change the data WITHOUT calling invalidateMeasurements() or
      // triggering any rebuild -- nothing in the widget tree changed, so no
      // frame runs performLayout() again for this row.
      fingerprints[0] = 'v1';
      await tester.pump();

      expect(
        controller.fingerprintFor(0),
        'v0',
        reason:
            'With no rebuild and no invalidateMeasurements(), the stored fingerprint '
            'must remain the old build-time snapshot -- it must never be refreshed by '
            'silently re-reading contentFingerprint() outside of a real build+layout '
            'pass, or the stored pair could end up mixing an old Size with a fingerprint '
            'that describes different (newer) data.',
      );
      expect(controller.measurementsSizes[0], sizeBefore);
    });
  });
}
