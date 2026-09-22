import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// Drives [future] to completion with a bounded number of pumps instead of
/// `await future` directly or `pumpAndSettle()`. `scrollTo()` resolves via
/// `WidgetsBinding.instance.endOfFrame`/`position.animateTo`, both of which
/// only advance when frames are actually pumped — awaiting the future with
/// no concurrent pump starves it forever (see
/// test/scroll_to_zero_duration_search_test.dart and ISC-26's precedent for
/// why `expectLater` alone can hang here). Fails the test explicitly if
/// [future] has not settled within [maxPumps], rather than let the whole
/// suite run into the global test timeout.
Future<void> pumpUntilDone(WidgetTester tester, Future<void> future,
    {int maxPumps = 60}) async {
  var settled = false;
  Object? error;
  unawaited(future.then((_) => settled = true, onError: (Object e) {
    error = e;
    settled = true;
  }));
  for (var i = 0; i < maxPumps && !settled; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(settled, isTrue,
      reason: 'scrollTo() must settle within $maxPumps pumps.');
  if (error != null) {
    // ignore: only_throw_errors
    throw error!;
  }
}

/// ISC-36/ISC-37: `measurementsSizes`
/// (lib/src/indexed_scroll_controller.dart) used to read
/// `Map<int, Size> get measurementsSizes => _sizes;` — it returned the live
/// `_sizes` instance itself, not a copy or an unmodifiable view. ISC-36
/// characterized two concrete exploits this allowed: silently corrupting a
/// later `scrollTo()`'s offset by overwriting an already-measured entry, and
/// fabricating an entry for a never-laid-out index to skip the
/// already-measured fast path's safety net entirely.
///
/// ISC-37 closed the gap by changing the getter to
/// `UnmodifiableMapView(_sizes)` — still a live read-through view (so
/// existing diagnostic reads elsewhere in the test suite keep working
/// unchanged), but any write attempt now throws `UnsupportedError` instead of
/// reaching `_sizes`. This file is now a regression anchor: both scenarios
/// below assert that the exploit write throws, not that it succeeds.
void main() {
  group(
      'ISC-37: measurementsSizes is an unmodifiable, still-live view of _sizes',
      () {
    const itemCount = 5;
    final heights = [100.0, 100.0, 100.0, 100.0, 100.0]; // sum = 500

    Widget buildUniformList(IndexedScrollController controller) {
      return MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: itemCount,
            itemBuilder: (context, index) {
              return controller.watch(
                index: index,
                child: SizedBox(
                  height: heights[index],
                  child: Center(child: Text('item $index')),
                ),
              );
            },
          ),
        ),
      );
    }

    testWidgets(
      'writing to an already-measured entry through measurementsSizes throws '
      'instead of corrupting the offset scrollTo() computes on its '
      'already-measured fast path',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(buildUniformList(controller));
        await tester.pumpAndSettle();

        // All 5 rows fit in the 600px test viewport, so every logical index
        // 0..4 is already measured after the first pump -- scrollTo(3) will
        // take the already-measured fast path, not the search pass.
        final measurements = controller.measurementsSizes;
        expect(measurements[1]?.height, closeTo(100.0, 1.0));

        // ISC-37: measurementsSizes now returns UnmodifiableMapView(_sizes)
        // instead of _sizes itself, so this write must throw before it ever
        // reaches the controller's internal storage.
        expect(
          () => measurements[1] = const Size(0, 999.0),
          throwsUnsupportedError,
          reason:
              'measurementsSizes is an UnmodifiableMapView -- attempting to '
              'write through it must throw UnsupportedError, not silently '
              'mutate the live _sizes map (ISC-36 showed this write used to '
              'succeed and corrupt a later scrollTo() offset).',
        );

        // The rejected write must not have partially applied -- the entry
        // stays at its true measured value.
        expect(controller.measurementsSizes[1]?.height, closeTo(100.0, 1.0));

        // scrollTo(3) sums heights of logical indices 0,1,2 to reach logical
        // index 3: 100+100+100 = 300.0px of raw offset. With the write
        // blocked, that sum comes from the real 100px row heights rather
        // than the 1199.0px the ISC-36 exploit used to produce.
        //
        // This list does not actually overflow, though: 5 rows * 100px =
        // 500px of content in a 600px viewport, so maxScrollExtent is 0 and
        // the scrollable cannot move at all. The raw 300px target is past
        // the physical end of the list, and scrollTo() clamps it, so the
        // settled position is 0. The corruption this test guards against
        // would still be caught -- a poisoned entry changes the summed
        // offset, and the assertions above already prove the write throws.
        //
        // duration: Duration.zero drives scrollTo() via jumpTo instead of a
        // real animateTo ticker (see _runAnimateTo), so pumpUntilDone only
        // needs to satisfy the internal `endOfFrame` awaits, not a full
        // animation -- bounded and fast, per this project's no-unbounded-wait
        // testing convention (ISC-04/05).
        await pumpUntilDone(
            tester, controller.scrollTo(3.0, duration: Duration.zero));

        expect(
          controller.position.pixels,
          closeTo(controller.position.maxScrollExtent, 1.0),
          reason:
              'The content (500px) is shorter than the viewport (600px), so '
              'maxScrollExtent is 0 and scrollTo(3) clamps to it rather than '
              'resolving at the unreachable 300px the raw offset formula '
              'produces.',
        );
      },
    );

    testWidgets(
      'fabricating an entry for an index scrollTo() would otherwise reject as '
      'missing throws instead of letting the already-measured fast path '
      'proceed past a gap that was never actually laid out',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        // Only 3 rows this time, so logical indices 0..2 are the entire live
        // set -- index 3 is never registered by real layout at all.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 3,
                itemBuilder: (context, index) {
                  return controller.watch(
                    index: index,
                    child: const SizedBox(
                      height: 100.0,
                      child: Center(child: Text('row')),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          controller.measurementsSizes.containsKey(3),
          isFalse,
          reason:
              'Index 3 was never built or laid out -- it must not be in _sizes yet.',
        );

        // ISC-37: attempting to fabricate an entry for index 3 through the
        // public getter must throw before it ever reaches _sizes, so
        // _hasCompletePrefix(3) can never be fooled by a key that real
        // layout never registered.
        expect(
          () => controller.measurementsSizes[3] = const Size(0, 50.0),
          throwsUnsupportedError,
          reason:
              'measurementsSizes is an UnmodifiableMapView -- fabricating a '
              'key through it must throw, not silently let a never-laid-out '
              'index masquerade as measured (ISC-36 showed this write used '
              'to succeed and let scrollTo(3) skip the search-and-measure '
              'safety net entirely).',
        );

        expect(
          controller.measurementsSizes.containsKey(3),
          isFalse,
          reason: 'The rejected write must not have partially applied.',
        );
      },
    );
  });
}
