import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-41: `scrollTo(duration: Duration.zero)` right after
/// `invalidateMeasurements()`, with an incomplete prefix and no widened
/// `cacheExtent`.
///
/// The regression occurred when `scrollTo()`'s internal recovery `jumpTo(0)`
/// did not wait for a frame
/// before `_runAnimateTo`'s search loop started stepping. With
/// `duration: Duration.zero`, that loop's very first step also takes a
/// `jumpTo` (its own zero-duration fast path), so both jumps used to fire
/// back-to-back before row 0 was ever built/laid out: index 0 never
/// registered a measurement, yet `position.pixels` kept visibly changing
/// from the jumps themselves, so the loop's "did we make progress" check
/// never stalled and the search walked the position past the physical end
/// of the list instead of completing or erroring.
void main() {
  group('ISC-41: recovery after invalidateMeasurements() with Duration.zero',
      () {
    testWidgets(
      'row height change + invalidateMeasurements() + immediate '
      'scrollTo(10, duration: Duration.zero) settles at the exact offset, '
      'without a widened cacheExtent',
      (WidgetTester tester) async {
        const itemCount = 30;
        const viewportHeight = 400.0;
        const defaultHeight = 100.0;
        const mutatedIndex = 9;
        const newHeight = 350.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        double heightForIndex(int index) =>
            index == mutatedIndex ? _rowHeight.value : defaultHeight;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                height: viewportHeight,
                child: ValueListenableBuilder<double>(
                  valueListenable: _rowHeight,
                  builder: (context, _, __) {
                    return ListView.builder(
                      controller: controller,
                      itemCount: itemCount,
                      // Default cacheExtent: the task specifically requires
                      // no enlarged cacheExtent, so only a handful of rows
                      // around the viewport are ever built at once.
                      itemBuilder: (context, index) {
                        return controller.watch(
                          index: index,
                          child: SizedBox(
                            height: heightForIndex(index),
                            child: Text('index=$index'),
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

        // Step 1: scroll to offset 800 (row 8's top, at the original uniform
        // 100px height) so the list is positioned exactly as the task
        // describes, and index `mutatedIndex` (9) is measured at its
        // original height before it changes.
        unawaited(controller.scrollTo(8.0,
            duration: const Duration(milliseconds: 100)));
        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(controller.position.pixels, closeTo(800.0, 1.0));
        expect(controller.measurementsSizes[mutatedIndex]?.height,
            closeTo(defaultHeight, 1.0));

        // Step 2: change row 9's height and invalidate. This is the ISC-41
        // reproduction setup: the position is NOT reset to 0 by the caller,
        // no external jumpTo(0) or widened cacheExtent is used -- the
        // controller must recover the prefix on its own.
        _rowHeight.value = newHeight;
        controller.invalidateMeasurements();

        // Step 3: immediately (no intervening pump) call
        // scrollTo(10, duration: Duration.zero). Before the fix this call's
        // Future never completed within any reasonable frame budget and
        // position.pixels drifted far past the physical end of the list
        // (it reached 40400px against a 30-row list). The fix
        // must make this settle in a bounded number of frames at the exact
        // target: rows 0-8 at 100px (900) + row 9 at its new 350px = 1250px.
        const expectedOffset =
            mutatedIndex * defaultHeight + newHeight; // 1250.0

        bool completed = false;
        Object? error;
        final future = controller.scrollTo(10.0, duration: Duration.zero);
        unawaited(
          future.then(
            (_) => completed = true,
            onError: (Object e) {
              error = e;
              completed = true;
            },
          ),
        );

        const maxFrames = 200;
        var framesPumped = 0;
        for (; framesPumped < maxFrames && !completed; framesPumped++) {
          await tester.pump(const Duration(milliseconds: 16));
          // A regression that walks past the physical end of the list would
          // otherwise keep "making progress" (position.pixels keeps
          // changing) forever and never trip this test's own frame budget
          // via a clean failure -- so also fail fast if pixels run away well
          // past any plausible target, rather than waiting out the full
          // budget in that case too.
          expect(
            controller.position.pixels,
            lessThan(itemCount * newHeight),
            reason: 'position.pixels must never run past the physical end of '
                'the list while recovering; observed '
                '${controller.position.pixels}px after $framesPumped frames.',
          );
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo(10, duration: Duration.zero) must settle within '
              '$maxFrames frames after invalidateMeasurements(), not hang.',
        );
        expect(error, isNull,
            reason:
                'scrollTo must complete successfully, not error. Got: $error');
        expect(controller.measurementsSizes.containsKey(0), isTrue,
            reason: 'Index 0 must have been measured during recovery.');
        expect(
          controller.position.pixels,
          closeTo(expectedOffset, 1.0),
          reason: 'Expected the exact recovered offset $expectedOffset px '
              '(9 rows * ${defaultHeight}px + row 9\'s new ${newHeight}px).',
        );
      },
    );

    testWidgets(
      'cancelScroll() during the post-invalidation frame wait cancels the '
      'call instead of leaking the active operation',
      (WidgetTester tester) async {
        const itemCount = 30;
        const viewportHeight = 400.0;
        const rowHeight = 100.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

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
                          height: rowHeight, child: Text('index=$index')),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        unawaited(controller.scrollTo(8.0,
            duration: const Duration(milliseconds: 100)));
        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        controller.invalidateMeasurements();

        bool completed = false;
        Object? error;
        final future = controller.scrollTo(10.0, duration: Duration.zero);
        unawaited(
          future.then(
            (_) => completed = true,
            onError: (Object e) {
              error = e;
              completed = true;
            },
          ),
        );

        // Cancel before the first pump lands, so the cancellation is
        // observed while the call is suspended in the post-jumpTo(0) frame
        // wait this task adds, not later in the search loop.
        controller.cancelScroll();

        for (int i = 0; i < 200 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(completed, isTrue,
            reason: 'A cancelled call must still settle, not hang.');
        expect(
          error,
          isA<ScrollCancelledException>().having(
              (e) => e.reason, 'reason', ScrollCancelReason.explicitCancel),
          reason: 'Cancelling during the post-invalidation frame wait must '
              'report explicitCancel. Got: $error',
        );

        // A leaked _activeOperationId (never cleared because the throw
        // happened before _animateTo's try/finally) would make this next,
        // independent scrollTo() get silently superseded before it even
        // starts, or otherwise misbehave. It must complete cleanly.
        final nextFuture = controller.scrollTo(5.0,
            duration: const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
        await expectLater(nextFuture, completes);
        expect(controller.position.pixels, closeTo(500.0, 1.0));
      },
    );

    testWidgets(
      'invalidateMeasurements() + scrollTo(duration: Duration.zero) to an '
      'unreachable index reports RangeError instead of drifting past the '
      'physical end of the list',
      (WidgetTester tester) async {
        // A 20-row x 100px list, invalidateMeasurements(), then
        // scrollTo(30, duration: Duration.zero) used to never settle --
        // position.pixels reached 32000px instead of the documented
        // RangeError, because the search loop's zero-duration jumpTo steps
        // are not clamped to maxScrollExtent, so position.pixels kept
        // visibly changing (looking like progress) even after the loop had
        // already walked past the physical end of the list.
        const itemCount = 20;
        const viewportHeight = 400.0;
        const rowHeight = 100.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

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
                          height: rowHeight, child: Text('index=$index')),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        controller.invalidateMeasurements();

        bool completed = false;
        Object? error;
        final future = controller.scrollTo(30.0, duration: Duration.zero);
        unawaited(
          future.then(
            (_) => completed = true,
            onError: (Object e) {
              error = e;
              completed = true;
            },
          ),
        );

        const maxFrames = 100;
        var framesPumped = 0;
        for (; framesPumped < maxFrames && !completed; framesPumped++) {
          await tester.pump(const Duration(milliseconds: 16));
          // A regression that never clamps its stall detection to the
          // physical bound would otherwise keep "making progress" forever
          // and blow through the physical end of the list well before this
          // test's own frame budget would catch it as a hang.
          expect(
            controller.position.pixels,
            lessThan(itemCount * rowHeight * 2),
            reason: 'position.pixels must never run away past the physical '
                'end of the list; observed ${controller.position.pixels}px '
                'after $framesPumped frames.',
          );
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo(30, duration: Duration.zero) to an unreachable '
              'index must settle (with an error) within $maxFrames frames, '
              'not hang.',
        );
        expect(
          error,
          isA<RangeError>(),
          reason: 'An unreachable target past the physical end of the list '
              'must report RangeError, not hang or throw something else. '
              'Got: $error',
        );
      },
    );
  });
}

final ValueNotifier<double> _rowHeight = ValueNotifier<double>(100.0);
