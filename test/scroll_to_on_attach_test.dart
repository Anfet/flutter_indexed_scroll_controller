import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-32/ISC-33: `scrollTo()` called synchronously from
/// `ScrollController.onAttach`, i.e. at the moment a `ScrollPosition`
/// attaches to the controller but before that position has gone through its
/// first layout pass.
///
/// `onAttach` (a `ScrollController` constructor parameter, not something
/// this package defines) fires from inside `ScrollController.attach`, called
/// synchronously by `ScrollableState.didChangeDependencies` while the
/// `Scrollable`'s element is still being mounted — well before
/// `RenderViewport.performLayout` ever runs. At that point `hasClients`/
/// `positions.isEmpty` are already satisfied (the position was just added to
/// `ScrollController.positions` by `attach` itself), so `scrollTo()`'s own
/// `StateError` guard for "no attached position" does not fire.
///
/// ISC-32 found that `scrollTo()` then read `position.viewportDimension`
/// unguarded, immediately after the attachment checks and before any
/// `await`. `position.hasViewportDimension` is `false` at that point — the
/// backing `_viewportDimension` field has never been set by a layout pass,
/// and its getter (`ScrollPosition.viewportDimension => _viewportDimension!`)
/// is a bare null-check operator, not a value defaulted to `0.0` — so the
/// call's returned `Future` completed with a raw Flutter-SDK `_TypeError`
/// instead of one of this package's documented error types.
///
/// ISC-33 (`lib/src/indexed_scroll_controller.dart`, right after the
/// `positions.length != 1` guard and before `_activeOperationId` is claimed)
/// closes that gap: `scrollTo()` now checks `position.hasViewportDimension`
/// and `position.hasPixels` before reading either getter, and throws a
/// documented `StateError` if either metric is not yet available. Because
/// `scrollTo()` is declared `async`, that `StateError` still does not throw
/// synchronously out of the call in `onAttach` — Dart captures any exception
/// thrown in an `async` function body, even before its first `await`, into
/// the returned `Future` rather than propagating it to the immediate caller
/// — so `scrollTo()` "returns" cleanly from `onAttach`'s point of view, but
/// the `Future` it handed back completes with the `StateError`.
void main() {
  group('ISC-32/ISC-33: scrollTo() called from onAttach, before first layout', () {
    testWidgets(
      'scrollTo() called synchronously inside onAttach does not throw '
      'synchronously (it is an async function), but its Future completes '
      "with a documented StateError, not a raw Flutter-SDK null-check error",
      (WidgetTester tester) async {
        const itemCount = 50;
        const rowHeight = 100.0;

        Object? capturedSyncThrow;
        Future<void>? capturedFuture;
        bool? viewportDimensionAvailableAtAttach;
        Object? futureError;
        bool futureCompleted = false;
        late IndexedScrollController controller;

        controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 50),
          onAttach: (position) {
            // Runs synchronously from inside ScrollController.attach(),
            // while the Scrollable's element is still mounting: `position`
            // is already in `controller.positions`, but no layout pass has
            // ever touched it, so viewportDimension/pixels are not yet
            // meaningful.
            viewportDimensionAvailableAtAttach = position.hasViewportDimension;
            try {
              capturedFuture = controller.scrollTo(10.0);
              // The error handler must be attached synchronously, right
              // here inside onAttach, rather than after pumpWidget returns:
              // pumpWidget's own internal frame pump flushes the microtask
              // queue (and with it this Future's error) before control ever
              // returns to the test body, so attaching the handler later
              // would be too late to catch it and the Flutter test binding
              // would report it as an unhandled async error instead.
              unawaited(
                capturedFuture!.then(
                  (_) => futureCompleted = true,
                  onError: (Object e) {
                    futureError = e;
                    futureCompleted = true;
                  },
                ),
              );
            } catch (e) {
              capturedSyncThrow = e;
            }
          },
        );
        addTearDown(controller.dispose);

        // pumpWidget mounts the Scrollable, which calls
        // ScrollController.attach(), which fires onAttach() synchronously,
        // all before pumpWidget itself returns.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  return controller.watch(
                    index: index,
                    child: SizedBox(height: rowHeight, child: Text('Item $index')),
                  );
                },
              ),
            ),
          ),
        );

        expect(
          viewportDimensionAvailableAtAttach,
          isFalse,
          reason:
              'Confirms the premise: at onAttach time, viewportDimension '
              'has genuinely never been set by a layout pass yet.',
        );

        // Observed: scrollTo() does NOT throw synchronously — it is an
        // `async` function, so the ISC-33 readiness-guard failure (the very
        // first check after the attachment guards) is captured into the
        // returned Future instead of propagating to this synchronous call
        // site.
        expect(
          capturedSyncThrow,
          isNull,
          reason:
              'scrollTo() is declared async: even though it fails the '
              'viewport-readiness guard before any await, Dart captures '
              "that failure into the method's returned Future rather than "
              'throwing it synchronously to the onAttach callback.',
        );
        expect(capturedFuture, isNotNull);

        // A handful of pumps is enough: the failure happens before any
        // await, so the Future settles as soon as the event loop gets a
        // chance to run the error callback — no multi-frame search occurs.
        for (int i = 0; i < 10 && !futureCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          futureCompleted,
          isTrue,
          reason:
              'The Future must settle (as an error) promptly, not hang.',
        );

        // This is the ISC-33 fix, verified: the Future completes with this
        // package's documented StateError, not a raw Flutter SDK
        // _TypeError, and not any of the other three documented contract
        // types either.
        expect(
          futureError,
          isA<StateError>(),
          reason:
              'scrollTo() invoked from onAttach (pre-layout) completes its '
              "Future with this package's documented StateError from the "
              'ISC-33 viewport-readiness guard, not a raw Flutter SDK '
              'null-check _TypeError. Got: $futureError',
        );
        expect(
          futureError.toString(),
          contains('before the first layout'),
          reason:
              'Pins the exact message of the ISC-33 guard in '
              'lib/src/indexed_scroll_controller.dart, so a future change to '
              'the wording is caught as an intentional behavior change '
              'rather than silently passing.',
        );
        expect(
          futureError,
          isNot(isA<TypeError>()),
          reason: 'The raw Flutter SDK null-check error ISC-32 documented '
              'must no longer surface.',
        );
        expect(futureError, isNot(isA<RangeError>()));
        expect(futureError, isNot(isA<ArgumentError>()));
        expect(futureError, isNot(isA<ScrollCancelledException>()));

        // The widget tree still finishes mounting and laying out normally:
        // the failed onAttach-time scrollTo() call did not corrupt the tree
        // build or leave pumpWidget hanging.
        await tester.pumpAndSettle();
        expect(find.text('Item 0'), findsOneWidget);

        // A normal scrollTo() issued after layout has actually happened
        // works fine — this failure is specific to calling scrollTo()
        // before the first layout, not a lasting corruption of the
        // controller's internal operation-id bookkeeping. See
        // "ISC-33: cancelScroll() after an onAttach-time failure is still a
        // no-op" below for a test that pins the operation-id cleanup itself,
        // rather than only this offset outcome.
        final postLayoutFuture = controller.scrollTo(10.0);
        await tester.pumpAndSettle();
        await expectLater(postLayoutFuture, completes);
        expect(controller.position.pixels, closeTo(1000.0, 1.0));
      },
    );

    testWidgets(
      'the same StateError occurs regardless of which index is requested '
      'from onAttach (failure is in the shared pre-search prefix, not the '
      'search loop for a distant target)',
      (WidgetTester tester) async {
        // Confirms the failure is triggered by the viewport-readiness guard
        // itself (the very first synchronous step inside scrollTo(), before
        // any measurement/search logic runs), not by anything specific to
        // the multi-step search pass for a distant/unmeasured index.
        const itemCount = 200;
        const rowHeight = 60.0;

        Future<void>? capturedFuture;
        Object? futureError;
        bool futureCompleted = false;
        late IndexedScrollController controller;

        controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 20),
          onAttach: (position) {
            capturedFuture = controller.scrollTo(150.0);
            // See the first test above for why this must be attached here,
            // synchronously inside onAttach, rather than after pumpWidget.
            unawaited(
              capturedFuture!.then(
                (_) => futureCompleted = true,
                onError: (Object e) {
                  futureError = e;
                  futureCompleted = true;
                },
              ),
            );
          },
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
                    child: SizedBox(height: rowHeight, child: Text('Item $index')),
                  );
                },
              ),
            ),
          ),
        );

        expect(capturedFuture, isNotNull);

        for (int i = 0; i < 10 && !futureCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(futureCompleted, isTrue);
        expect(
          futureError,
          isA<StateError>(),
          reason:
              'Same guard failure for a distant, unmeasured target: it '
              'happens before the search loop ever starts, at the '
              'viewport-readiness check on the first line of '
              "scrollTo()'s body after the attachment checks — independent "
              'of scrollToIndex.',
        );
        expect(
          futureError.toString(),
          contains('before the first layout'),
        );
      },
    );

    testWidgets(
      'ISC-33: cancelScroll() after an onAttach-time failure is still a '
      'no-op, proving _activeOperationId was never left dangling by the '
      'early StateError',
      (WidgetTester tester) async {
        // ISC-32's reviewer noted that, before this fix, _activeOperationId
        // was claimed synchronously (before the viewportDimension read) but
        // only ever cleared in _animateTo's `finally` or its early-return
        // success path — never on this early-failure path. The earlier test
        // above ("a normal scrollTo() ... works fine") only proves the
        // *offset* comes out right afterward, which is true regardless of
        // whether the id leaked, because the next call's `++_currentOperationId`
        // always moves past a stale id anyway. This test instead pins the
        // operation-id bookkeeping itself: after the ISC-33 fix, the guard
        // throws before `_activeOperationId` is ever assigned, so
        // cancelScroll() immediately after the failed onAttach call must see
        // no active operation and be a safe no-op, not throw and not affect
        // a later, real scrollTo().
        const itemCount = 50;
        const rowHeight = 100.0;

        late IndexedScrollController controller;
        Future<void>? capturedFuture;

        controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 50),
          onAttach: (position) {
            capturedFuture = controller.scrollTo(10.0);
            // Swallow the expected StateError so it doesn't surface as an
            // unhandled async error in this test.
            unawaited(capturedFuture!.catchError((_) {}));
          },
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
                    child: SizedBox(height: rowHeight, child: Text('Item $index')),
                  );
                },
              ),
            ),
          ),
        );

        for (int i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await expectLater(capturedFuture, throwsA(isA<StateError>()));

        // If _activeOperationId had leaked (the pre-ISC-33 bug), this would
        // still not directly throw -- cancelScroll() is documented as a
        // no-op when nothing is active, and a dangling id would make it
        // *incorrectly* look like something was active. The real proof is
        // the assertion after it: a subsequent real scrollTo() must reach
        // its exact target, undisturbed by whatever cancelScroll() just did.
        controller.cancelScroll();
        await tester.pump();

        final future = controller.scrollTo(10.0);
        await tester.pumpAndSettle();
        await expectLater(
          future,
          completes,
          reason:
              'A real scrollTo() after the onAttach failure and an '
              'intervening cancelScroll() call must complete normally: if '
              'cancelScroll() had wrongly found a leaked active id and '
              'cancelled THIS call by mistake, this scrollTo() would '
              'complete with a ScrollCancelledException instead.',
        );
        expect(
          controller.position.pixels,
          closeTo(1000.0, 1.0),
          reason:
              'Confirms the real scrollTo() actually reached its target '
              'offset, not just that its Future settled without throwing.',
        );
      },
    );
  });
}
