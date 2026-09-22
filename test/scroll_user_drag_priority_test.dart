import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// Builds a list, optionally wrapped in [IndexedScrollGestureDetector], and
/// drags it while a `scrollTo()` may or may not be in flight.
///
/// Returns how far the list actually moved across the drag. The whole point
/// of this harness is that `wrapped` and `programmaticScroll` vary
/// independently: the original bug reproduced with NO gesture wiring at all,
/// so a test that holds the wiring fixed cannot detect it.
Future<double> _dragDistance(
  WidgetTester tester, {
  required bool wrapped,
  required bool programmaticScroll,
  void Function(Object error)? onScrollError,
}) async {
  final controller = IndexedScrollController(
    scrollDuration: const Duration(milliseconds: 300),
  );
  addTearDown(controller.dispose);

  // ISC-82a made the search loop advance by unconditional jumpTo instead of
  // an animated step per iteration, so a nearby target (item 50 on a
  // 200-item list, as this used to be) now resolves within the single pump
  // below -- scrollTo() would already be finished before the drag ever
  // starts, and this harness would stop exercising the race it exists to
  // test. A far target on a much longer list keeps the search genuinely
  // spanning multiple frames (confirmed: item 15000 of 20000 is still
  // mid-search after one 16ms pump), so the drag still contends with an
  // in-flight scrollTo the way the original defect did.
  const targetIndex = 15000.0;
  final list = ListView.builder(
    controller: controller,
    itemCount: 20000,
    itemBuilder: (context, index) => controller.watch(
      index: index,
      child: SizedBox(height: 100.0, child: Text('Item $index')),
    ),
  );

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: wrapped ? IndexedScrollGestureDetector(controller: controller, child: list) : list,
      ),
    ),
  );
  await tester.pumpAndSettle();

  if (programmaticScroll) {
    unawaited(controller.scrollTo(targetIndex).catchError((Object e) => onScrollError?.call(e)));
    await tester.pump(const Duration(milliseconds: 16));
  }

  final gesture = await tester.startGesture(const Offset(200, 300));
  await tester.pump();
  final before = controller.offset;
  for (var i = 0; i < 5; i++) {
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
  }
  final moved = controller.offset - before;
  await gesture.up();
  await tester.pumpAndSettle();
  return moved;
}

void unawaited(Future<void> f) {}

void main() {
  group('user drag takes priority over an in-flight scrollTo', () {
    testWidgets('baseline: drag moves the list with no scroll in flight', (tester) async {
      expect(
        await _dragDistance(tester, wrapped: false, programmaticScroll: false),
        closeTo(200.0, 1.0),
        reason: 'Sanity check on the harness itself: a plain drag of 5x40px '
            'must move the list 200px when nothing else is running.',
      );
    });

    testWidgets('wrapped: drag still moves the list during a scrollTo', (tester) async {
      Object? error;
      final moved = await _dragDistance(
        tester,
        wrapped: true,
        programmaticScroll: true,
        onScrollError: (e) => error = e,
      );

      expect(
        moved,
        closeTo(200.0, 1.0),
        reason: 'The user\'s finger must keep control of the list while a '
            'scrollTo() is searching. Before the fix this was 0.0: the '
            'search\'s jumpTo replaced the DragScrollActivity holding the '
            'gesture, so the drag was dead.',
      );
      expect(error, isA<ScrollCancelledException>());
      expect(
        (error! as ScrollCancelledException).reason,
        ScrollCancelReason.userGesture,
        reason: 'The yielded scrollTo must report why it stopped, so a '
            'caller can tell "the user took over" from a retryable '
            'supersession.',
      );
    });

    testWidgets('unwrapped: a bare controller still loses the drag (documents the limit)', (tester) async {
      // The original defect reproduced WITHOUT any gesture wiring, which is
      // why this case is covered separately from the wrapped one above.
      //
      // A bare controller has no way to learn that a drag started --
      // ScrollPosition exposes no public "is a finger down" signal -- so it
      // cannot yield, and the search's jumpTo still takes the position away
      // from the gesture. This test pins that as the KNOWN, documented
      // limit of not wrapping, so that if a future change ever makes the
      // bare case work, this failing test prompts updating the docs that
      // currently tell users the wrapper is required.
      //
      // ISC-82a changed WHAT the position lands on here, not WHETHER the
      // drag loses. Before, the search's per-step animateTo was still deep
      // in its own tween 80ms into the race, so the drag's actual -200px
      // motion happened not to have landed either -- pixels stayed near
      // 0.0 by coincidence of animation timing, not because the drag won.
      // Now the search's jumpTo lands its full step immediately every
      // pump, so pixels visibly races ahead by multiples of the viewport
      // instead. Asserting "not the drag's own distance" is the actual
      // contract; asserting a specific pixel value here would just pin
      // today's search-step size (see ISC-82c, which may change it).
      final moved = await _dragDistance(
        tester,
        wrapped: false,
        programmaticScroll: true,
        onScrollError: (_) {},
      );
      expect(
        moved,
        isNot(closeTo(200.0, 1.0)),
        reason: 'Without IndexedScrollGestureDetector the drag\'s own -200px motion never lands '
            '-- the search\'s jumpTo keeps overwriting position.pixels every frame, so the '
            'gesture never gets to move the list on its own. This is why the wrapper exists and '
            'why the README documents it as required for gesture priority.',
      );
    });

    testWidgets('scrollTo() started mid-drag yields instead of killing the gesture', (tester) async {
      final controller = IndexedScrollController(scrollDuration: const Duration(milliseconds: 300));
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IndexedScrollGestureDetector(
              controller: controller,
              child: ListView.builder(
                controller: controller,
                itemCount: 200,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(height: 100.0, child: Text('Item $index')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();

      await expectLater(
        controller.scrollTo(80),
        throwsA(isA<ScrollCancelledException>().having(
          (e) => e.reason,
          'reason',
          ScrollCancelReason.userGesture,
        )),
      );

      final before = controller.offset;
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(
        controller.offset - before,
        closeTo(40.0, 1.0),
        reason: 'The drag must survive a scrollTo() attempted mid-gesture.',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a scrollTo issued after the drag ends works normally', (tester) async {
      final controller = IndexedScrollController(scrollDuration: Duration.zero);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IndexedScrollGestureDetector(
              controller: controller,
              child: ListView.builder(
                controller: controller,
                itemCount: 200,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(height: 100.0, child: Text('Item $index')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // The gesture is over, so the controller must accept work again --
      // otherwise the gesture-end notification would be a one-way latch that
      // permanently disables scrollTo after the first ever drag.
      var settled = false;
      final future = controller.scrollTo(30).then((_) => settled = true);
      for (var i = 0; i < 300 && !settled; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await future;
      expect(settled, isTrue);
      expect(controller.offset, closeTo(3000.0, 1.0));
    });
  });
}
