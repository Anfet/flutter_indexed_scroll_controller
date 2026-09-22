import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

Widget _list(IndexedScrollController controller,
    {int count = 60, double height = 100.0}) {
  return MaterialApp(
    home: Scaffold(
      body: ListView.builder(
        controller: controller,
        itemCount: count,
        itemBuilder: (context, index) => controller.watch(
          index: index,
          child: SizedBox(height: height, child: Text('Item $index')),
        ),
      ),
    ),
  );
}

void main() {
  group('scrollTo() resolves with an in-bounds offset', () {
    testWidgets('alignment 1.0 at index 0 does not resolve negative',
        (tester) async {
      final controller = IndexedScrollController(scrollDuration: Duration.zero);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller));
      await tester.pumpAndSettle();

      double? offsetAtResolve;
      final future = controller.scrollTo(0, alignment: 1.0).then((_) {
        offsetAtResolve = controller.offset;
      });
      for (var i = 0; i < 400 && offsetAtResolve == null; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await future;

      expect(
        offsetAtResolve,
        isNotNull,
        reason: 'scrollTo() must actually complete within the pump budget.',
      );
      expect(
        offsetAtResolve,
        greaterThanOrEqualTo(controller.position.minScrollExtent),
        reason: 'Before the fix this resolved at -500.0 against a '
            'minScrollExtent of 0.0: the alignment adjustment pushed the '
            'target below the reachable range and the Future settled before '
            'the next layout pass corrected it.',
      );
      expect(offsetAtResolve, closeTo(0.0, 1.0));
    });

    testWidgets('alignment 0.0 at the last index does not resolve past the end',
        (tester) async {
      final controller = IndexedScrollController(scrollDuration: Duration.zero);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller, count: 200));
      await tester.pumpAndSettle();

      double? offsetAtResolve;
      final future = controller.scrollTo(199).then((_) {
        offsetAtResolve = controller.offset;
      });
      for (var i = 0; i < 2000 && offsetAtResolve == null; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await future;

      expect(offsetAtResolve, isNotNull);
      expect(
        offsetAtResolve,
        lessThanOrEqualTo(controller.position.maxScrollExtent),
        reason: 'Before the fix a scroll to the final index resolved at '
            '9940.0 against a maxScrollExtent of 9390.0.',
      );
      expect(
          offsetAtResolve, closeTo(controller.position.maxScrollExtent, 1.0));
    });

    testWidgets('animated (non-zero duration) also resolves in bounds',
        (tester) async {
      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 20));
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller));
      await tester.pumpAndSettle();

      double? offsetAtResolve;
      final future = controller.scrollTo(0, alignment: 1.0).then((_) {
        offsetAtResolve = controller.offset;
      });
      for (var i = 0; i < 400 && offsetAtResolve == null; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await future;

      expect(offsetAtResolve, isNotNull);
      expect(offsetAtResolve,
          greaterThanOrEqualTo(controller.position.minScrollExtent));
    });

    testWidgets('a reachable mid-list target is unaffected by clamping',
        (tester) async {
      // Guards against the clamp being overzealous: an ordinary in-range
      // target must still land exactly where the offset formula says.
      final controller = IndexedScrollController(scrollDuration: Duration.zero);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller, count: 200));
      await tester.pumpAndSettle();

      double? offsetAtResolve;
      final future = controller.scrollTo(30).then((_) {
        offsetAtResolve = controller.offset;
      });
      for (var i = 0; i < 2000 && offsetAtResolve == null; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await future;

      expect(
        offsetAtResolve,
        closeTo(3000.0, 1.0),
        reason: '30 rows of 100px, alignment 0 -> exactly 3000px, well '
            'inside the bounds, so the clamp must not move it.',
      );
    });

    testWidgets('fractional index near the end resolves in bounds',
        (tester) async {
      final controller = IndexedScrollController(scrollDuration: Duration.zero);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_list(controller, count: 60));
      await tester.pumpAndSettle();

      double? offsetAtResolve;
      final future = controller.scrollTo(59.5).then((_) {
        offsetAtResolve = controller.offset;
      });
      for (var i = 0; i < 2000 && offsetAtResolve == null; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await future;

      expect(offsetAtResolve, isNotNull);
      expect(offsetAtResolve,
          lessThanOrEqualTo(controller.position.maxScrollExtent));
      expect(offsetAtResolve,
          greaterThanOrEqualTo(controller.position.minScrollExtent));
    });
  });
}
