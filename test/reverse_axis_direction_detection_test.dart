import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group('ISC-66: private reverse detection via ScrollPosition.axisDirection', () {
    Future<void> pumpList(
      WidgetTester tester,
      IndexedScrollController controller, {
      required Axis scrollDirection,
      required bool reverse,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              scrollDirection: scrollDirection,
              reverse: reverse,
              itemCount: 20,
              itemBuilder: (context, index) => controller.watch(
                index: index,
                child: SizedBox(
                  height: scrollDirection == Axis.vertical ? 50.0 : double.infinity,
                  width: scrollDirection == Axis.horizontal ? 50.0 : double.infinity,
                  child: Text('Item $index'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'vertical, reverse: false (AxisDirection.down) is not reversed',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await pumpList(tester, controller, scrollDirection: Axis.vertical, reverse: false);

        expect(
          controller.position.axisDirection,
          AxisDirection.down,
          reason: 'Sanity check: a non-reversed vertical ListView must attach '
              'a position whose axisDirection is down.',
        );
        expect(
          controller.isReversedForTesting,
          isFalse,
          reason: 'AxisDirection.down is the non-reversed vertical direction, '
              'so _isReversed must read false.',
        );
      },
    );

    testWidgets(
      'vertical, reverse: true (AxisDirection.up) is reversed',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await pumpList(tester, controller, scrollDirection: Axis.vertical, reverse: true);

        expect(
          controller.position.axisDirection,
          AxisDirection.up,
          reason: 'Sanity check: reverse: true on a vertical ListView must '
              'attach a position whose axisDirection is up.',
        );
        expect(
          controller.isReversedForTesting,
          isTrue,
          reason: 'AxisDirection.up must be detected as reversed.',
        );
      },
    );

    testWidgets(
      'horizontal, reverse: false (AxisDirection.right) is not reversed',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await pumpList(tester, controller, scrollDirection: Axis.horizontal, reverse: false);

        expect(
          controller.position.axisDirection,
          AxisDirection.right,
          reason: 'Sanity check: a non-reversed horizontal ListView must '
              'attach a position whose axisDirection is right.',
        );
        expect(
          controller.isReversedForTesting,
          isFalse,
          reason: 'AxisDirection.right is the non-reversed horizontal '
              'direction, so _isReversed must read false.',
        );
      },
    );

    testWidgets(
      'horizontal, reverse: true (AxisDirection.left) is reversed',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await pumpList(tester, controller, scrollDirection: Axis.horizontal, reverse: true);

        expect(
          controller.position.axisDirection,
          AxisDirection.left,
          reason: 'Sanity check: reverse: true on a horizontal ListView must '
              'attach a position whose axisDirection is left.',
        );
        expect(
          controller.isReversedForTesting,
          isTrue,
          reason: 'AxisDirection.left must be detected as reversed.',
        );
      },
    );
  });
}
