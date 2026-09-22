import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'support/scroll_harness.dart';

/// ISC-06/ISC-07: two overlapping `scrollTo` calls, `detach`, and `dispose`
/// while a multi-step search is in flight.
///
/// ISC-06 originally pinned these assertions to the *unsafe* pre-ISC-07
/// behavior (documented, not desired): the second of two overlapping calls
/// losing a position race with `RangeError`, `detach` surfacing Flutter's own
/// `AssertionError`, and `dispose` not interrupting the search at all. ISC-07
/// added an operation-ownership mechanism (a monotonically increasing
/// operation id checked after every `await`, plus a `hasClients` check) that
/// makes all three outcomes safe and predictable instead, so the assertions
/// below were rewritten to match. Every assertion is pinned to a value or
/// exception type observed by running each scenario 5 times in isolated
/// `testWidgets` bodies before this file was rewritten (not guessed). All
/// three scenarios were fully deterministic across those runs: same
/// completion state, same offset (or same exception type/reason) every time,
/// with fixed row height and fixed target indices. Where the code comments
/// below say "observed N/N runs", that is the exploratory count, not a claim
/// this file re-verifies live (doing so via a loop is used only for
/// scenario 1's repeatability check to protect against flakiness regressions
/// without hard-coding a single lucky run).
void main() {
  group(
      'ISC-06/ISC-07: scrollTo concurrency (overlapping calls, detach, dispose)',
      () {
    testWidgets(
      'two overlapping scrollTo calls: the second supersedes the first, so '
      'the first is cancelled and only the second reaches its target',
      (WidgetTester tester) async {
        // 60 rows x 100px. scrollTo(50) starts a long upward search (target
        // pixels 5000, far past the viewport) and is left running. Two frames
        // later, scrollTo(10) is issued without awaiting the first call.
        //
        // ISC-07 gives every scrollTo call an operation id claimed at the
        // start of the call; a newer call bumps the shared counter, so the
        // older call's id goes stale. The first call's search checks that id
        // after every `await` (inside `_animateTo`), so the next time it
        // checks in after the second call starts, it notices it has been
        // superseded and cancels itself instead of continuing to fight the
        // second call for the position.
        //
        // Observed 5/5 isolated runs before writing this assert: the first
        // call always fails with ScrollCancelledException(reason:
        // superseded, requestedIndex: 50.0), and the second call always
        // completes normally at offset 1000.0 (index 10 * 100px, its own
        // target) — i.e. only the last goal is reached, matching the ISC-07
        // DoD. No other outcome was observed in 5 runs.
        const itemCount = 60;
        const rowHeight = 100.0;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (_) => rowHeight,
            guardLimit: 500,
          ),
        );
        final state =
            tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        bool firstCompleted = false;
        Object? firstError;
        unawaited(
          state.controller.scrollTo(50.0).then(
            (_) => firstCompleted = true,
            onError: (Object e) {
              firstError = e;
              firstCompleted = true;
            },
          ),
        );

        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));

        bool secondCompleted = false;
        Object? secondError;
        unawaited(
          state.controller.scrollTo(10.0).then(
            (_) => secondCompleted = true,
            onError: (Object e) {
              secondError = e;
              secondCompleted = true;
            },
          ),
        );

        for (int i = 0; i < 400 && !(firstCompleted && secondCompleted); i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          firstCompleted,
          isTrue,
          reason: 'scrollTo(50) must finish (successfully or with an error) '
              'within the pump budget, not hang.',
        );
        expect(
          secondCompleted,
          isTrue,
          reason: 'scrollTo(10) must finish (successfully or with an error) '
              'within the pump budget, not hang.',
        );

        expect(
          firstError,
          isA<ScrollCancelledException>().having(
            (e) => e.reason,
            'reason',
            ScrollCancelReason.superseded,
          ),
          reason: 'The first scrollTo(50) call should be cancelled once the '
              'second call supersedes it. Got: $firstError',
        );
        expect(
          secondError,
          isNull,
          reason: 'The second, more recent call should reach its own target '
              'uncontested. Got: $secondError',
        );
        expect(
          state.controller.position.pixels,
          closeTo(1000.0, 1.0),
          reason: 'Final offset should match the second call\'s target '
              '(index 10 * ${rowHeight}px), since it is the last call and '
              'the DoD is that only the last goal is reached.',
        );
      },
    );

    // The "stable across repeated runs" check for the scenario above is
    // expressed as N independent testWidgets bodies (below), each with its
    // own tester, rather than as a for-loop of pumpWidget calls sharing one
    // tester. That loop shape was tried while preparing this file and turned
    // out to be its own source of flakiness: reusing one WidgetTester's
    // virtual clock across iterations lets a prior iteration's animation
    // (still winding down when the next iteration's pumpWidget replaces the
    // tree) bleed into the next iteration's starting position — iteration 0
    // reliably saw pos=96.0 before the second call as intended, but later
    // iterations saw pos already at 1544.0 or 5000.0 (leftover motion from
    // the previous iteration's scrollTo(50)), which changes which index is
    // already measured and defeats the scenario the test means to exercise.
    // Separate testWidgets bodies give each run a fresh tester and were
    // confirmed deterministic (8/8) during manual exploration.
    for (var iteration = 0; iteration < 5; iteration++) {
      testWidgets(
        'two overlapping scrollTo calls: outcome is stable across repeated '
        'runs (run $iteration)',
        (WidgetTester tester) async {
          const itemCount = 60;
          const rowHeight = 100.0;

          await tester.pumpWidget(
            ScrollHarness(
              itemCount: itemCount,
              itemHeightBuilder: (_) => rowHeight,
              guardLimit: 500,
            ),
          );
          final state =
              tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
          await tester.pumpAndSettle();

          bool firstCompleted = false;
          Object? firstError;
          unawaited(
            state.controller.scrollTo(50.0).then(
              (_) => firstCompleted = true,
              onError: (Object e) {
                firstError = e;
                firstCompleted = true;
              },
            ),
          );

          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 16));

          bool secondCompleted = false;
          Object? secondError;
          unawaited(
            state.controller.scrollTo(10.0).then(
              (_) => secondCompleted = true,
              onError: (Object e) {
                secondError = e;
                secondCompleted = true;
              },
            ),
          );

          for (int i = 0;
              i < 400 && !(firstCompleted && secondCompleted);
              i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }

          expect(
            firstCompleted && secondCompleted,
            isTrue,
            reason: 'Run $iteration: both calls must finish within the pump '
                'budget.',
          );
          expect(
            firstError,
            isA<ScrollCancelledException>().having(
              (e) => e.reason,
              'reason',
              ScrollCancelReason.superseded,
            ),
            reason: 'Run $iteration: first call should be cancelled as '
                'superseded. Got: $firstError',
          );
          expect(
            secondError,
            isNull,
            reason: 'Run $iteration: second call should reach its own '
                'target uncontested. Got: $secondError',
          );
        },
      );
    }

    testWidgets(
      'detach while a multi-step search is in flight cancels the pending '
      'Future with ScrollCancelReason.detached instead of hanging, '
      'succeeding, or leaking an AssertionError',
      (WidgetTester tester) async {
        // Target index 50 in a 60-row, 100px-per-row list requires a
        // multi-step search (only ~6 rows fit the default test viewport, so
        // reaching index 50 needs several search steps). The target is
        // within itemCount, so nothing here should trip ISC-05's
        // unreachable-index RangeError; only the detach is expected to
        // interrupt the search.
        //
        // A manually built ListView (not ScrollHarness) is used so the
        // detach can be driven by unmounting the Scrollable itself: calling
        // `controller.detach(controller.position)` directly races the
        // framework's own detach-on-unmount and throws a *different*,
        // ScrollHarness-lifecycle-specific assertion
        // ('_positions.contains(position)') that is an artifact of double
        // detaching, not of the controller's search continuing after
        // detach. Replacing the widget subtree lets Flutter's normal
        // Scrollable.dispose() perform the one real detach.
        //
        // Before ISC-07, this surfaced Flutter's own `ScrollController.
        // position` getter assertion ("ScrollController not attached to any
        // scroll views") because `_animateTo` re-read `position` after
        // `await`ing a step with no owner/attachment check. ISC-07 added a
        // `hasClients`/`positions.isEmpty` check after every `await` inside
        // `_animateTo`, so the search now notices the detach itself and
        // cancels cleanly before touching the now-detached position.
        //
        // Observed 5/5 isolated runs before writing this assert: after the
        // subtree is replaced, the pending Future always completes with
        // ScrollCancelledException(reason: detached, requestedIndex: 50.0).
        // No run completed successfully, no run hung, and no run leaked
        // Flutter's raw AssertionError.
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

        // Let the search run for a few steps so it is genuinely mid-flight
        // (not measuring only the initial viewport) before detaching.
        for (int i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          completed,
          isFalse,
          reason: 'The search should still be in flight three frames in; if '
              'it already finished the detach below would not be testing '
              'concurrency at all.',
        );

        // Unmount the Scrollable so the framework performs the one real
        // detach, instead of racing a manual detach() against it.
        await tester.pumpWidget(const SizedBox.shrink());

        for (int i = 0; i < 100 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo\'s Future must settle (successfully or with an '
              'error) within the pump budget after detach, not hang forever.',
        );
        expect(
          error,
          isA<ScrollCancelledException>().having(
            (e) => e.reason,
            'reason',
            ScrollCancelReason.detached,
          ),
          reason: 'A search step after detach should notice hasClients is '
              'now false via the ISC-07 check-in and cancel itself with '
              'ScrollCancelReason.detached, rather than leaking Flutter\'s '
              'own position-getter AssertionError. Got: $error '
              '(${error.runtimeType})',
        );
      },
    );

    testWidgets(
      'dispose while a multi-step search is in flight cancels the pending '
      'Future with ScrollCancelReason.disposed instead of letting the '
      'search keep driving the position',
      (WidgetTester tester) async {
        // Same reachable multi-step target as the detach scenario (index 50
        // of 60 rows at 100px), but this time `controller.dispose()` is
        // called directly instead of unmounting the widget tree.
        //
        // `ScrollController.dispose()` (see
        // package:flutter/src/widgets/scroll_controller.dart) only removes
        // this controller's listeners from each attached ScrollPosition and
        // calls `super.dispose()` (ChangeNotifier disposal) — it does NOT
        // clear `_positions` or detach the position, so before ISC-07 a
        // search step already in flight kept working against a
        // ScrollPosition that was still fully attached and alive, and the
        // Future resolved normally as if nothing had happened. ISC-07's
        // override bumps the operation id (and sets a `_disposed` flag used
        // only to pick the reported reason) before calling `super.dispose()`,
        // so the next check-in inside `_animateTo` sees a stale id and
        // cancels with ScrollCancelReason.disposed instead of continuing.
        //
        // Observed 5/5 isolated runs before writing this assert: every run
        // completed with ScrollCancelledException(reason: disposed,
        // requestedIndex: 50.0) shortly after dispose() was called, and no
        // run let the search continue to offset 5000.0.
        const itemCount = 60;
        const rowHeight = 100.0;
        const targetIndex = 50.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
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

        for (int i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          completed,
          isFalse,
          reason: 'The search should still be in flight three frames in; if '
              'it already finished, dispose below would not be testing '
              'concurrency at all.',
        );

        controller.dispose();

        for (int i = 0; i < 100 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo\'s Future must settle within the pump budget '
              'after dispose, not hang forever.',
        );
        expect(
          error,
          isA<ScrollCancelledException>().having(
            (e) => e.reason,
            'reason',
            ScrollCancelReason.disposed,
          ),
          reason: 'dispose() bumps the operation id, so the next check-in '
              'inside the in-flight search should cancel it with '
              'ScrollCancelReason.disposed rather than let it keep driving '
              'the position toward its original target. Got: $error',
        );
      },
    );
  });
}
