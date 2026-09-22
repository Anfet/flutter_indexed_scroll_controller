import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// Regression tests for ISC-22 and ISC-23.
///
/// `scrollTo()` drives the underlying `ScrollPosition` with `animateTo(...)`,
/// and Flutter's `animateTo` posts a `ScrollStartNotification` when the
/// animation begins — the same notification type a real user drag produces.
/// The package example (`example/lib/list_screen.dart`) listens for
/// `ScrollStartNotification` and calls `cancelScroll()` so a user's drag can
/// interrupt an in-flight `scrollTo()`. ISC-22 found that the example's
/// original wiring called `cancelScroll()` unconditionally, which also
/// cancelled the controller's own programmatic animation, since the
/// notification from `scrollTo()`'s internal `animateTo` looked
/// indistinguishable from a user's unless something inspected it further.
///
/// `ScrollStartNotification.dragDetails` is that distinguishing signal: it is
/// non-null only for notifications produced by a real user gesture
/// (`DragStartDetails`), and null for a purely programmatic animation. ISC-23
/// fixed the example by checking `notification.dragDetails != null` before
/// calling `cancelScroll()`. This file characterizes that field via real
/// Flutter scroll behavior only — never a synthetic/hand-constructed
/// `ScrollStartNotification` — and includes a regression test mirroring the
/// example's fixed wiring.
void main() {
  group(
      'ISC-22: ScrollStartNotification.dragDetails distinguishes '
      'programmatic scrollTo() from real user drags', () {
    testWidgets(
      'a scrollTo()-driven ScrollStartNotification has dragDetails == null, '
      'and scrollTo() completes at its target without being cancellable by '
      'its own notifications',
      (WidgetTester tester) async {
        const itemCount = 200;
        const rowHeight = 100.0;
        const targetIndex = 150.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        final receivedNotifications = <ScrollStartNotification>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NotificationListener<ScrollStartNotification>(
                onNotification: (notification) {
                  receivedNotifications.add(notification);
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

        // No simulated user gesture anywhere in this test: the only input
        // driving the list is scrollTo()'s own internal animateTo() calls,
        // which the multi-step search issues repeatedly for an unmeasured,
        // distant target like this one.
        for (int i = 0; i < 300 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo() must settle within the pump budget.',
        );
        expect(
          error,
          isNull,
          reason: 'A purely programmatic scrollTo() must not cancel itself '
              'via its own ScrollStartNotification stream. Got: $error',
        );
        expect(
          controller.position.pixels,
          closeTo(targetIndex * rowHeight, 1.0),
          reason: 'scrollTo() must reach its own target undisturbed.',
        );

        expect(
          receivedNotifications,
          isNotEmpty,
          reason: 'animateTo() is documented to post a ScrollStartNotification '
              'when it begins; the multi-step search calls animateTo() '
              'repeatedly, so at least one should have been observed.',
        );
        for (final notification in receivedNotifications) {
          expect(
            notification.dragDetails,
            isNull,
            reason: 'Every ScrollStartNotification produced while only '
                'scrollTo() is driving the list must carry dragDetails == '
                'null: there is no real pointer/gesture behind it.',
          );
        }
      },
    );

    testWidgets(
      'a real WidgetTester.drag() while scrollTo() is in flight produces a '
      'ScrollStartNotification with dragDetails != null',
      (WidgetTester tester) async {
        const itemCount = 200;
        const rowHeight = 100.0;
        const targetIndex = 150.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        final receivedNotifications = <ScrollStartNotification>[];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NotificationListener<ScrollStartNotification>(
                onNotification: (notification) {
                  receivedNotifications.add(notification);
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

        // Let the search get genuinely mid-flight before the real drag, so
        // the drag and the programmatic animation are actually concurrent.
        for (int i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          completed,
          isFalse,
          reason: 'The search should still be in flight three frames in; '
              'otherwise the drag below would not be concurrent with '
              'anything.',
        );

        final notificationsBeforeDrag = receivedNotifications.length;

        // A real pointer-driven drag, not a synthesized notification: this
        // is what actually sets DragStartDetails on the resulting
        // ScrollStartNotification.
        await tester.drag(find.byType(ListView), const Offset(0, -150));

        final dragNotifications = receivedNotifications.skip(notificationsBeforeDrag).toList();
        expect(
          dragNotifications.any((n) => n.dragDetails != null),
          isTrue,
          reason: 'A real user drag must produce at least one '
              'ScrollStartNotification with non-null dragDetails, which is '
              'exactly the signal ISC-23 will use to tell real gestures '
              'apart from scrollTo()\'s own programmatic animation.',
        );

        // Document the actual observed behavior of the bare controller
        // (with no cancel-on-notification wiring in this test): per ISC-08,
        // a drag alone is invisible to scrollTo()'s cancellation mechanism,
        // so the search is expected to keep going and still reach its own
        // target once both the drag's ballistic settling and the search
        // finish.
        for (int i = 0; i < 300 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo() must settle within the pump budget even with '
              'a concurrent real drag.',
        );
        expect(
          error,
          isNull,
          reason: 'The bare controller (without the example\'s '
              'cancel-on-any-notification wiring) does not treat a drag as '
              'a cancellation trigger by itself; see ISC-08. Got: $error',
        );
        expect(
          controller.position.pixels,
          closeTo(targetIndex * rowHeight, 1.0),
          reason: 'Once settled, the position should reflect scrollTo()\'s '
              'own target: the search keeps re-driving the position after '
              'each of its own animateTo() calls.',
        );
      },
    );

    testWidgets(
      'ISC-23 regression: mirroring the example\'s fixed '
      'NotificationListener<ScrollStartNotification> + cancelScroll() '
      'wiring (guarded by dragDetails != null) no longer cancels a '
      'purely programmatic scrollTo()',
      (WidgetTester tester) async {
        const itemCount = 200;
        const rowHeight = 100.0;
        const targetIndex = 150.0;

        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NotificationListener<ScrollStartNotification>(
                // Mirrors example/lib/list_screen.dart's fixed wiring: only
                // cancel on a real user drag (dragDetails != null), not on
                // scrollTo()'s own internal animateTo() notifications.
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

        // No user gesture at all: scrollTo()'s own internal animateTo()
        // calls post ScrollStartNotifications, but the fixed wiring ignores
        // them because dragDetails is null.
        for (int i = 0; i < 300 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          completed,
          isTrue,
          reason: 'scrollTo() must settle within the pump budget.',
        );
        expect(
          error,
          isNull,
          reason: 'The fixed wiring must not cancel a purely programmatic '
              'scrollTo() via its own ScrollStartNotification stream. '
              'Got: $error',
        );
        expect(
          controller.position.pixels,
          closeTo(targetIndex * rowHeight, 1.0),
          reason: 'With the fix, the controller must reach the requested '
              'target undisturbed by its own notifications.',
        );
      },
    );
  });
}
