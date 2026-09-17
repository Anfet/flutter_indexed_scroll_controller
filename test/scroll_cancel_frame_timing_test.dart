import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-24/ISC-25: `position.pixels` behavior between the moment
/// `cancelScroll()` is called and the moment the in-flight `scrollTo()`
/// Future actually settles.
///
/// ISC-24 found that `cancelScroll()` only bumped `_currentOperationId`
/// without touching the `ScrollPosition` itself. The search loop in
/// `_runAnimateTo` (see lib/src/indexed_scroll_controller.dart) drives each
/// step with a single `await position.animateTo(offset, duration:
/// scrollDuration, curve: ...)` and only calls `_checkOperationLive` — the
/// point that notices the bumped operation id and throws
/// `ScrollCancelledException` — after that whole step's `Future` resolves.
/// With no per-frame liveness check inside a single `animateTo` step, a
/// cancellation landing mid-step used to be invisible to the search until
/// that step finished, so `position.pixels` kept advancing, frame over
/// frame, toward that step's own abandoned intermediate target for up to a
/// full step's `scrollDuration` worth of extra frames.
///
/// ISC-25 fixed this: `cancelScroll()` now calls `position.jumpTo(position.
/// pixels)` synchronously, before bumping the operation id. `jumpTo` forces
/// whatever `ScrollActivity` is currently driving the position (including a
/// `DrivenScrollActivity` left running by the in-flight `animateTo` step) to
/// be replaced with an idle one, so the coasting stops immediately instead
/// of continuing until the step's `Future` resolves. This test is the
/// regression anchor for that fix: it pins that `position.pixels` freezes at
/// (or immediately after) the value recorded right after `cancelScroll()`,
/// rather than continuing to advance across subsequent pumped frames.
void main() {
  group('ISC-25: position freezes immediately on cancelScroll()', () {
    testWidgets(
      'position.pixels freezes immediately when cancelScroll() is called '
      'mid-step, instead of coasting for the rest of the in-flight '
      'animateTo step',
      (WidgetTester tester) async {
        const itemCount = 200;
        const rowHeight = 100.0;
        // Far enough that the unmeasured-item search loop needs several
        // multi-frame animateTo steps to reach it, rather than taking the
        // instant "already there" early return.
        const targetIndex = 150.0;

        final controller = IndexedScrollController(
          // Long enough (multiple 16ms frames) that a step is genuinely
          // still ticking, frame over frame, when cancelScroll() lands
          // mid-step rather than happening to land exactly on a step
          // boundary.
          scrollDuration: const Duration(milliseconds: 300),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  return controller.watch(
                    index: index,
                    child: SizedBox(height: rowHeight, child: Text('$index')),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        bool completed = false;
        Object? error;
        unawaited(
          controller.scrollTo(targetIndex).then(
            (_) => completed = true,
            onError: (Object e) {
              error = e;
              completed = true;
            },
          ),
        );

        // Let the multi-step search run for a few frames so it is genuinely
        // mid-flight, in the middle of a step's animateTo, before cancelling.
        for (int i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          completed,
          isFalse,
          reason: 'The search should still be in flight three frames in; if '
              'it already finished, cancelScroll() below would not be '
              'testing cancellation of an active search at all.',
        );

        final pixelsAtStepStart = controller.position.pixels;

        controller.cancelScroll();

        // Record position.pixels immediately after cancelScroll(), in the
        // same microtask, before any further pump gets a chance to run.
        final pixelsImmediatelyAfterCancel = controller.position.pixels;

        // cancelScroll() itself does not touch the ScrollPosition (it only
        // bumps the operation id), so nothing should have moved yet between
        // the last pump and this synchronous read.
        expect(
          pixelsImmediatelyAfterCancel,
          equals(pixelsAtStepStart),
          reason: 'cancelScroll() only bumps the internal operation id; it '
              'does not synchronously touch position.pixels, so the value '
              'read in the same microtask should be unchanged from the last '
              'pumped frame.',
        );

        // Now pump single frames one at a time, recording position.pixels
        // after each, until the Future settles (bounded so a bug that hangs
        // forever fails fast instead of timing out the whole suite).
        final recordedPixels = <double>[pixelsImmediatelyAfterCancel];
        // Before ISC-25, a step's animateTo ran for the full scrollDuration
        // (300ms) once started, regardless of when cancelScroll() landed
        // inside it; at ~16ms/frame that was on the order of 19 frames worst
        // case. ISC-25's jumpTo-based stop means settling should now happen
        // much sooner, but the same generous budget is kept so this test
        // still catches a regression that reintroduces coasting or hangs.
        const maxFramesToWaitForSettle = 25;
        var framesPumped = 0;
        for (; framesPumped < maxFramesToWaitForSettle && !completed; framesPumped++) {
          await tester.pump(const Duration(milliseconds: 16));
          recordedPixels.add(controller.position.pixels);
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo\'s Future must settle within '
              '$maxFramesToWaitForSettle frames of cancelScroll(), not hang '
              'forever. Recorded pixels per frame: $recordedPixels',
        );
        expect(
          error,
          isA<ScrollCancelledException>().having(
            (e) => e.reason,
            'reason',
            ScrollCancelReason.explicitCancel,
          ),
          reason: 'cancelScroll() should cancel the in-flight search with '
              'ScrollCancelReason.explicitCancel. Got: $error',
        );

        // --- The ISC-25 fix, verified ------------------------------------
        //
        // Before the fix, the DrivenScrollActivity from the in-flight
        // animateTo step kept coasting toward that step's *own* intermediate
        // target for the rest of that step's duration — well over a dozen
        // frames advancing by a constant ~32px/frame in the scenario this
        // test exercises — because the search only noticed the cancellation
        // once that step's `await position.animateTo(...)` finally resolved
        // and `_checkOperationLive` ran again, with no per-frame liveness
        // check inside a single step.
        //
        // ISC-25 fixed this by having cancelScroll() call
        // `position.jumpTo(position.pixels)` synchronously before bumping
        // the operation id, which replaces the running DrivenScrollActivity
        // with an idle one immediately. So position.pixels should now stay
        // at the value recorded immediately after cancelScroll() for every
        // subsequently pumped frame, instead of continuing to advance.
        final positionChangedAfterCancelBeforeSettle = recordedPixels
            .skip(1)
            .any((p) => p != pixelsImmediatelyAfterCancel);
        expect(
          positionChangedAfterCancelBeforeSettle,
          isFalse,
          reason: 'Expected position.pixels to freeze immediately once '
              'cancelScroll() is called, because it now forces the '
              'position\'s current activity to stop synchronously (via '
              'jumpTo) instead of leaving a DrivenScrollActivity coasting '
              'until the search\'s next check-in. Recorded pixels per frame '
              'after cancel: $recordedPixels',
        );

        // Once the Future has settled, the search must not still be live:
        // further pumps must not move the position toward the original
        // far-away target.
        final pixelsAtSettle = controller.position.pixels;
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          controller.position.pixels,
          equals(pixelsAtSettle),
          reason: 'Once the cancelled scrollTo\'s Future has settled, no '
              'further position changes should occur from that operation; '
              'the position must stay at $pixelsAtSettle, not keep drifting.',
        );
        expect(
          controller.position.pixels,
          isNot(closeTo(targetIndex * rowHeight, 1.0)),
          reason: 'The cancelled search must never reach its original '
              'far-away target (index $targetIndex * ${rowHeight}px).',
        );

        // Secondary check: a fresh scrollTo() issued after cancellation is
        // unaffected by the previous operation's leftover state and
        // completes normally.
        final secondFuture = controller.scrollTo(20.0);
        await tester.pumpAndSettle();
        await expectLater(secondFuture, completes);
        expect(controller.position.pixels, closeTo(2000.0, 1.0));
      },
    );
  });
}
