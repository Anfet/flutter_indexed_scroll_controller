import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// Tests for ISC-08/ISC-09: explicit cancellation of scrollTo via
/// cancelScroll() and user drag via NotificationListener.
///
/// The first group (ISC-08) documents the expected behavior when a user
/// initiates a drag gesture during an active scrollTo operation: the bare
/// controller does not automatically cancel programmatic scrolls; callers
/// must explicitly call `cancelScroll()` from a `NotificationListener`. It
/// pins the "no implicit cancel" contract — drag never interrupts an
/// in-flight `scrollTo` by itself, whether the drag happens before it starts
/// or while it is still actively searching — which is exactly what a naive
/// implementation of drag-cancels-scrollTo could accidentally break by
/// wiring a `ScrollStartNotification` listener directly into the controller
/// instead of leaving it opt-in via `cancelScroll()`. That contract must
/// keep holding after ISC-09 adds `cancelScroll()` below: the two groups
/// together show that cancellation only ever happens because calling code
/// chose to call `cancelScroll()`, never as a side effect of the drag
/// itself.
///
/// The second group (ISC-09) tests the real `cancelScroll()` implementation,
/// which reuses the same `_currentOperationId`/`_checkOperationLive`
/// mechanism ISC-07 added for supersession by a newer `scrollTo` call,
/// rather than a second cancellation mechanism.
void main() {
  group('ISC-08: Explicit cancel of scrollTo', () {
    testWidgets('scrollTo completes normally when no drag interrupts it',
        (WidgetTester tester) async {
      // Baseline: scrollTo reaches its target without user interaction.
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 10),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemCount: 50,
              itemBuilder: (context, index) {
                return controller.watch(
                  index: index,
                  child: SizedBox(height: 100, child: Text('Item $index')),
                );
              },
            ),
          ),
        ),
      );

      // Scroll to a reachable index without interruption.
      final scrollFuture = controller.scrollTo(10.0);
      await tester.pumpAndSettle();

      // The Future should complete successfully (no exception).
      await expectLater(scrollFuture, completes);

      // The position should be approximately at index 10 (offset ~1000).
      expect(controller.position.pixels, closeTo(1000.0, 1.0));

      addTearDown(controller.dispose);
    });

    testWidgets(
      'drag before scrollTo does not prevent a subsequent scrollTo from '
      'completing',
      (WidgetTester tester) async {
        // ISC-08 documents that the bare controller does NOT automatically
        // cancel programmatic scrolls because of user drag. This exercises
        // the simple ordering (drag finishes, then scrollTo starts) as a
        // baseline before the harder concurrent case below.
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 10),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 50,
                itemBuilder: (context, index) {
                  return controller.watch(
                    index: index,
                    child: SizedBox(height: 100, child: Text('Item $index')),
                  );
                },
              ),
            ),
          ),
        );

        // User drags the list.
        await tester.drag(find.byType(ListView), const Offset(0, -200));
        await tester.pumpAndSettle();

        // After drag, programmatic scrollTo should still work normally.
        final scrollFuture = controller.scrollTo(20.0);
        await tester.pumpAndSettle();

        await expectLater(scrollFuture, completes);
        expect(controller.position.pixels, closeTo(2000.0, 1.0));

        addTearDown(controller.dispose);
      },
    );

    testWidgets(
      'a drag gesture while scrollTo is actively searching does not cancel '
      'or supersede it: the scrollTo still reaches its own target',
      (WidgetTester tester) async {
        // This is the scenario ISC-06/ISC-07's concurrency tests do not
        // cover: those exercise two competing *scrollTo* calls (which do
        // supersede each other via the operation-id mechanism). A user drag
        // is a fundamentally different path — it drives the ScrollPosition
        // directly via drive/ballistic simulations, never calling scrollTo
        // or bumping `_currentOperationId` — so the operation-ownership
        // check in `_checkOperationLive` (see
        // lib/src/indexed_scroll_controller.dart) has nothing to notice: a
        // drag is invisible to it. The documented contract (scrollTo
        // Dartdoc, "Cancellation" section) is that only a newer scrollTo,
        // detach, or dispose cancel an in-flight call — drag is deliberately
        // absent from that list. This test pins that a concurrent drag
        // genuinely does not interrupt the search, so a future change that
        // makes drag start participating in cancellation (e.g. by wiring a
        // ScrollStartNotification listener into the controller itself)
        // would be caught here as a behavior change.
        const itemCount = 60;
        const rowHeight = 100.0;
        const targetIndex = 50.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
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
        // mid-flight (matching the "3 frames in, not yet settled" shape used
        // by the ISC-07 concurrency tests) before dragging.
        for (int i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          completed,
          isFalse,
          reason: 'The search should still be in flight three frames in; if '
              'it already finished the drag below would not be testing '
              'concurrency at all.',
        );

        // Drag the list while the search is still actively stepping toward
        // its target. This exercises the same ScrollPosition the search is
        // driving via position.animateTo, from a second, independent input
        // path.
        await tester.drag(find.byType(ListView), const Offset(0, -150));

        // Let both the drag's ballistic settling and the scrollTo's search
        // continue.
        for (int i = 0; i < 200 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo\'s Future must settle within the pump budget '
              'even with a concurrent drag, not hang forever.',
        );
        expect(
          error,
          isNull,
          reason: 'A drag concurrent with an in-flight scrollTo is not one '
              'of the documented cancellation triggers (superseded, '
              'detached, disposed), so the scrollTo should complete '
              'successfully rather than being interrupted. Got: $error',
        );
        expect(
          controller.position.pixels,
          closeTo(targetIndex * rowHeight, 1.0),
          reason: 'Once settled, the position should reflect scrollTo\'s own '
              'target (index $targetIndex * ${rowHeight}px) — the search '
              'keeps re-driving the position after each of its own '
              'animateTo calls, so it should still land on its target even '
              'though a drag briefly moved the position out from under it.',
        );
      },
    );
  });

  group('ISC-09: cancelScroll()', () {
    testWidgets(
      'cancelScroll() during an active scrollTo completes its Future with '
      'ScrollCancelledException(reason: explicitCancel) and stops the '
      'search from applying further position updates',
      (WidgetTester tester) async {
        // Mirrors the drag-during-search setup from ISC-08 above, but drives
        // cancellation through cancelScroll() (called from a
        // NotificationListener<ScrollStartNotification>, as the package
        // example now does) instead of a raw drag — so this is the "real"
        // cancellation counterpart to the "drag alone does nothing" test
        // above.
        //
        // The listener below checks `dragDetails != null` before calling
        // cancelScroll(), exactly like the ISC-23-fixed package example
        // (example/lib/list_screen.dart) — this is required, not cosmetic:
        // scrollTo()'s own internal animateTo steps each start a fresh
        // ScrollActivity and so each also post a ScrollStartNotification
        // (dragDetails == null, per ISC-22). An unconditional cancelScroll()
        // here would react to the search's own first step instead of to the
        // synthetic ScrollStartNotification dispatched below, and ISC-25's
        // fix (which stops the position's activity synchronously) makes that
        // wrong self-cancellation resolve within the same frame, well before
        // the "let the search run 3 frames" setup below has a chance to run
        // — so, unlike before ISC-25, omitting the guard here would make
        // this test fail immediately instead of merely being imprecise.
        const itemCount = 60;
        const rowHeight = 100.0;
        const targetIndex = 50.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NotificationListener<ScrollStartNotification>(
                onNotification: (notification) {
                  if (notification.dragDetails != null) {
                    controller.cancelScroll();
                  }
                  return false;
                },
                child: ListView.builder(
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

        final pixelsBeforeCancel = controller.position.pixels;

        // A ScrollStartNotification with non-null dragDetails is what a real
        // drag dispatches (see ISC-22); posting one directly exercises the
        // NotificationListener -> cancelScroll() wiring without needing a
        // full drag gesture, while still passing the listener's `dragDetails
        // != null` guard above so this is understood as a user-driven
        // cancellation rather than the search's own internal notification.
        ScrollStartNotification(
          metrics: controller.position.copyWith(),
          context: tester.element(find.byType(ListView)),
          dragDetails: DragStartDetails(),
        ).dispatch(tester.element(find.byType(ListView)));

        for (int i = 0; i < 100 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo\'s Future must settle within the pump budget '
              'after cancelScroll(), not hang forever.',
        );
        expect(
          error,
          isA<ScrollCancelledException>().having(
            (e) => e.reason,
            'reason',
            ScrollCancelReason.explicitCancel,
          ),
          reason: 'cancelScroll() should cancel the in-flight search with '
              'ScrollCancelReason.explicitCancel, distinct from the '
              'ScrollCancelReason.superseded a competing scrollTo call '
              'would report. Got: $error',
        );

        // Give a few more frames the chance to apply a stale position
        // update, if the cancellation did not actually stop the search.
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          controller.position.pixels,
          isNot(closeTo(targetIndex * rowHeight, 1.0)),
          reason: 'The cancelled search must not go on to reach its '
              'original target (index $targetIndex * ${rowHeight}px); the '
              'position should stay near where it was at the moment of '
              'cancellation ($pixelsBeforeCancel), not keep advancing.',
        );
      },
    );

    testWidgets(
      'a scrollTo issued after cancelScroll() completes normally, without '
      'being stuck in the previous call\'s cancelled state',
      (WidgetTester tester) async {
        const itemCount = 60;
        const rowHeight = 100.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
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

        bool firstCompleted = false;
        Object? firstError;
        unawaited(
          controller.scrollTo(50.0).then(
            (_) => firstCompleted = true,
            onError: (Object e) {
              firstError = e;
              firstCompleted = true;
            },
          ),
        );

        for (int i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(firstCompleted, isFalse);

        controller.cancelScroll();

        for (int i = 0; i < 100 && !firstCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(firstCompleted, isTrue);
        expect(
          firstError,
          isA<ScrollCancelledException>().having(
            (e) => e.reason,
            'reason',
            ScrollCancelReason.explicitCancel,
          ),
        );

        // The next scrollTo call must behave as if nothing happened before
        // it: it should reach its own target normally, not inherit any
        // leftover "cancelled" state from the previous operation.
        final secondFuture = controller.scrollTo(20.0);
        await tester.pumpAndSettle();

        await expectLater(secondFuture, completes);
        expect(controller.position.pixels, closeTo(2000.0, 1.0));
      },
    );

    testWidgets(
      'cancelScroll() with no active scrollTo is a safe no-op',
      (WidgetTester tester) async {
        const itemCount = 50;
        const rowHeight = 100.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 10),
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

        // No scrollTo has ever been issued: cancelScroll() must not throw.
        expect(() => controller.cancelScroll(), returnsNormally);

        // Calling it again, still with nothing active, must also be fine.
        expect(() => controller.cancelScroll(), returnsNormally);

        // The controller should still work normally afterwards.
        final scrollFuture = controller.scrollTo(10.0);
        await tester.pumpAndSettle();
        await expectLater(scrollFuture, completes);
        expect(controller.position.pixels, closeTo(1000.0, 1.0));

        // A completed scrollTo also leaves nothing "active" to cancel.
        expect(() => controller.cancelScroll(), returnsNormally);
      },
    );
  });
}
