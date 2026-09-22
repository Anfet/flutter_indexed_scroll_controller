import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group(
      'ISC-34/ISC-35: _liveOwners across index AND controller reassignment, then unmount',
      () {
    // Background (read from lib/src/indexed_scroll_controller.dart and
    // lib/src/indexed_scroll_item.dart before writing this test):
    //
    // `_liveOwners` (`Map<int, _RenderIndexedScrollItem>`) is a plain instance
    // field on `IndexedScrollController` -- NOT static/shared. Two different
    // `IndexedScrollController` instances therefore each own a completely
    // separate `_liveOwners` map; "the wrong controller's map" really means
    // "controller A's own map still mentions a render object that no longer
    // has anything to do with A".
    //
    // `IndexedScrollItem.updateRenderObject()` (ISC-11) does this on reuse:
    //   (renderObject as _RenderIndexedScrollItem)..index = index..controller = controller;
    // ISC-34 found that the `index`/`controller` setters on
    // `_RenderIndexedScrollItem` used to only do `_index = value` /
    // `_controller = value` + `markNeedsLayout()` -- neither setter called
    // anything on the OLD `_controller` to unregister the object from it. So
    // switching a row from controller A to controller B never touched A's
    // `_liveOwners` at all; A's stale entry (from before the switch) was left
    // exactly as it was until something else cleared it -- which nothing
    // ever did, since `_RenderIndexedScrollItem.detach()` only ever
    // unregisters from whichever controller is CURRENT at detach time (B,
    // once the object has moved), never a controller it was previously
    // assigned to.
    //
    // ISC-35 closes this: both setters now call
    // `_controller._unregisterLiveOwner(this, index: _index)` with the OLD
    // controller/index, before either field is updated, using the same
    // identity check `detach()` already used (ISC-11) -- only removing the
    // entry if this object is still the one currently registered there. The
    // test below now asserts the fixed behavior directly, including the
    // crash ISC-34's review found the leak could cause (a stale entry
    // pointing at a since-disposed RenderObject).

    testWidgets(
      'reassigning one IndexedScrollItem from controller A to controller B, invalidating '
      'both, then unmounting: A releases its live-registration entry for the object at '
      'reassignment time, so invalidating A afterwards is safe',
      (WidgetTester tester) async {
        const rowHeight = 100.0;
        const itemCount = 10;

        final controllerA = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        final controllerB = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controllerA.dispose);
        addTearDown(controllerB.dispose);

        late StateSetter setState;
        IndexedScrollController activeController = controllerA;
        int activeIndex = 3;
        bool mounted = true;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setter) {
                  setState = setter;
                  return ListView.builder(
                    // NOTE: ListView.builder's own `controller:` must stay
                    // fixed for the whole widget tree's lifetime (switching
                    // it is a distinct, unrelated concern from switching
                    // which IndexedScrollController a single watch() row
                    // reports to). Only the tracked row's own `watch()`
                    // controller/index change here, exactly as ISC-34 asks.
                    controller: controllerA,
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        if (!mounted) {
                          return const SizedBox(height: rowHeight);
                        }
                        return activeController.watch(
                          index: activeIndex,
                          child: Container(
                            height: rowHeight,
                            color: Colors.blue,
                            child: Center(
                              child: Text('tracked index=$activeIndex'),
                            ),
                          ),
                        );
                      }
                      return Container(
                        height: rowHeight,
                        color: Colors.grey,
                        child: Center(child: Text('Item $index')),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        // Step 1: registered under controller A, logical index 3.
        expect(controllerA.measurementsSizes.containsKey(3), isTrue,
            reason:
                'Initial registration should land in controller A at index 3.');
        // `_liveOwners` is private, so we probe it indirectly via
        // `_unregisterLiveOwner`'s observable effect: invalidateMeasurements()
        // marks every CURRENT `_liveOwners` value for relayout. We confirm
        // liveness the direct, supported way instead -- by checking that a
        // fresh measurement re-appears after invalidation without the widget
        // changing, which only happens if the render object is still the
        // registered live owner and gets a markNeedsLayout() call.
        controllerA.invalidateMeasurements();
        await tester.pumpAndSettle();
        expect(controllerA.measurementsSizes.containsKey(3), isTrue,
            reason:
                'A live-owned row must re-register after invalidateMeasurements() '
                'marks it for relayout.');

        // Step 2: reassign the SAME widget slot to a NEW index (7) under a
        // DIFFERENT controller (B) -- the ISC-34 scenario, going beyond
        // ISC-10/11's same-controller coverage.
        setState(() {
          activeIndex = 7;
          activeController = controllerB;
        });
        await tester.pumpAndSettle();

        // The live registration must now be under B/7, and B must not have
        // inherited anything from A.
        expect(controllerB.measurementsSizes.containsKey(7), isTrue,
            reason:
                'ISC-11 fix: updateRenderObject() moves the live registration to '
                'the new controller/index pair.');
        expect(controllerB.measurementsSizes.containsKey(3), isFalse,
            reason:
                'Controller B must not inherit stale state keyed by A\'s old index.');
        // controller A keeps its OLD _sizes history by design (ISC-11:
        // ordinary reuse does not purge history) -- that part is expected
        // and is not the bug under test.
        expect(controllerA.measurementsSizes.containsKey(3), isTrue,
            reason:
                'ISC-11: A\'s historical measurement at 3 is retained, not erased.');

        // THE CRUX (ISC-35 fixed): is A's _liveOwners[3] entry (pointing at
        // this render object) still considered "live" by A? Pre-fix, calling
        // invalidateMeasurements() on A here would still call
        // invalidateMeasurement() (markNeedsLayout()) on the object via A's
        // stale entry, redundantly re-registering it under B (its current
        // controller) even though A no longer has any legitimate claim over
        // it. Post-fix, the `controller` setter already removed this entry
        // from A when the row switched to B, so this call is a no-op for the
        // tracked row and must not disturb B's already-correct state.
        final bSizeBeforeExtraInvalidation = controllerB.measurementsSizes[7];
        controllerA.invalidateMeasurements();
        await tester.pumpAndSettle();
        expect(controllerB.measurementsSizes[7],
            equals(bSizeBeforeExtraInvalidation),
            reason:
                'A\'s invalidateMeasurements() must not touch B\'s state for a row that '
                'moved away from A -- A no longer has a live-registration entry for it.');

        // Step 3: unmount the row entirely.
        setState(() {
          mounted = false;
        });
        await tester.pumpAndSettle();

        // detach() fires on the render object with its CURRENT controller,
        // which is B (the last controller it was assigned to). So B's
        // _liveOwners[7] entry, if present, is correctly removed. Probe this
        // via invalidateMeasurements() on B: after unmount there is nothing
        // live for B to mark, so calling it should be a safe no-op that does
        // not throw and does not resurrect a size for index 7 out of thin
        // air (it can't -- invalidateMeasurements() only clears _sizes and
        // marks CURRENTLY-live owners; an unmounted owner is inert).
        controllerB.invalidateMeasurements();
        await tester.pumpAndSettle();
        expect(controllerB.measurementsSizes.containsKey(7), isFalse,
            reason:
                'B correctly unregistered its live owner on detach() -- the entry does '
                'not resurrect after invalidation because nothing live remains to '
                'relayout.');

        // THE REAL FINDING, now a hard pass/fail gate (ISC-35): before the
        // fix, controller A was NEVER the render object's controller at the
        // moment of detach() (it had already moved to B), so A's detach path
        // was never exercised for this object at all -- A's stale
        // _liveOwners[3] entry survived the object's entire detach/unmount
        // lifecycle untouched. That is not inert: ISC-34's review found that
        // RenderObject.markNeedsLayout() (called by
        // _RenderIndexedScrollItem.invalidateMeasurement(), which
        // controllerA.invalidateMeasurements() calls on every entry still in
        // its _liveOwners) asserts !_debugDisposed and unmounting a row
        // disposes its RenderObject -- so calling invalidateMeasurements() on
        // the abandoned controller A, after the object has been unmounted,
        // throws Flutter's "A disposed RenderObject was mutated." FlutterError
        // pre-fix. ISC-35's fix removes the stale entry from A's _liveOwners
        // at the moment of reassignment (in the index/controller setters,
        // before either field changes), so A no longer references the object
        // at all by the time it is disposed, and this call must complete
        // cleanly.
        expect(
          controllerA.invalidateMeasurements,
          returnsNormally,
          reason:
              'ISC-35: controller A must have released its live-registration entry for '
              'the reassigned render object back when it moved to controller B, so '
              'invalidating A after the object is later unmounted (and disposed) must not '
              'touch it at all -- pre-fix this threw FlutterError(\'A disposed RenderObject '
              'was mutated.\') because A\'s stale _liveOwners[3] entry was still marking the '
              'now-disposed object for relayout.',
        );
      },
    );

    testWidgets(
      'multiple reassignments (A/3 -> A/9 -> B/2) then unmount: every vacated '
      'controller/index releases its live-registration entry at reassignment time',
      (WidgetTester tester) async {
        const rowHeight = 50.0;
        const itemCount = 12;

        final controllerA = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        final controllerB = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controllerA.dispose);
        addTearDown(controllerB.dispose);

        late StateSetter setState;
        IndexedScrollController activeController = controllerA;
        int activeIndex = 3;
        bool mounted = true;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setter) {
                  setState = setter;
                  return ListView.builder(
                    controller: controllerA,
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        if (!mounted) {
                          return const SizedBox(height: rowHeight);
                        }
                        return activeController.watch(
                          index: activeIndex,
                          child: Container(
                            height: rowHeight,
                            color: Colors.orange,
                            child: Center(child: Text('idx=$activeIndex')),
                          ),
                        );
                      }
                      return Container(
                        height: rowHeight,
                        color: Colors.grey,
                        child: Center(child: Text('Item $index')),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();
        expect(controllerA.measurementsSizes.containsKey(3), isTrue);

        // Change index only, still controller A (ISC-10/11's own scenario) --
        // confirms the baseline this test builds on before adding the
        // controller switch.
        setState(() => activeIndex = 9);
        await tester.pumpAndSettle();
        expect(controllerA.measurementsSizes.containsKey(9), isTrue,
            reason:
                'Live registration follows the same object to the new index within A.');
        expect(controllerA.measurementsSizes.containsKey(3), isTrue,
            reason:
                'ISC-11: history at the old index within the same controller is kept.');

        // Now switch to controller B at yet another index.
        setState(() {
          activeIndex = 2;
          activeController = controllerB;
        });
        await tester.pumpAndSettle();

        expect(controllerB.measurementsSizes.containsKey(2), isTrue,
            reason:
                'Live registration now follows the object into controller B.');
        expect(controllerB.measurementsSizes.length, equals(1),
            reason:
                'B must start clean: it should hold nothing beyond the one row just '
                'registered under it -- no residue from A\'s history at 3 or 9.');

        // invalidateMeasurements() on A now: this is the "old controller,
        // after the switch" probe from the ISC-34 task description. It must
        // not throw and must not resurrect anything under B.
        controllerA.invalidateMeasurements();
        await tester.pumpAndSettle();
        expect(controllerB.measurementsSizes.containsKey(2), isTrue,
            reason:
                'A\'s invalidation must not disturb B\'s live state for the same row.');

        // invalidateMeasurements() on B, then unmount, then invalidate B
        // again -- confirms B's own bookkeeping is internally consistent
        // across the object's final detach once it is B's problem to track.
        controllerB.invalidateMeasurements();
        await tester.pumpAndSettle();
        expect(controllerB.measurementsSizes.containsKey(2), isTrue,
            reason:
                'B\'s own live row survives B\'s own invalidateMeasurements() + relayout.');

        setState(() => mounted = false);
        await tester.pumpAndSettle();

        controllerB.invalidateMeasurements();
        await tester.pumpAndSettle();
        expect(
          controllerB.measurementsSizes.containsKey(2),
          isFalse,
          reason:
              'After unmount, B has no live owner left for index 2, so re-invalidating B '
              'must not resurrect a size for it -- confirms detach() correctly removed B\'s '
              'own _liveOwners[2] entry.',
        );

        // ISC-35: A must also no longer reference the object after it moved
        // away, even though A itself was never the controller at detach
        // time -- the setters release A's (and A's own earlier index-only
        // reassignment's) live-registration entries as each reassignment
        // happens, not just the final controller's entry at unmount.
        expect(controllerA.invalidateMeasurements, returnsNormally,
            reason:
                'A released its live-registration entries for this object at each '
                'reassignment (3 -> 9 within A, then away to B), so invalidating A after '
                'the object is unmounted (and disposed) must not touch it.');

        // A's own _sizes history at 3 and 9 does NOT survive this sequence --
        // but not because of any ISC-34 leak: `invalidateMeasurements()`
        // unconditionally does `_sizes.clear()` on ITS OWN controller (see
        // lib/src/indexed_scroll_controller.dart), wiping every entry A ever
        // held, not just the ones tied to the reassigned row. The
        // `controllerA.invalidateMeasurements()` call above (the "old
        // controller, after the switch" probe the ISC-34 task asks for) is
        // what erases 3 and 9 here, exactly as it would for any unrelated
        // row A ever measured. This is expected, orthogonal behavior --
        // confirmed empirically (a debug run without that call left 3 and 9
        // intact) -- not a symptom of the reassignment/leak under test.
        expect(controllerA.measurementsSizes.containsKey(3), isFalse,
            reason:
                'invalidateMeasurements() clears ALL of A\'s _sizes unconditionally, '
                'independent of the reassignment scenario.');
        expect(controllerA.measurementsSizes.containsKey(9), isFalse,
            reason:
                'Same: wiped by A\'s own invalidateMeasurements() call above, not by '
                'anything related to the controller switch.');
      },
    );
  });
}
