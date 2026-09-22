import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-51: selective recovery must use widths on a horizontal ListView and
/// retain the usual fractional-index and Duration.zero semantics.
void main() {
  testWidgets(
    'horizontal fractional target uses recovered widths with Duration.zero',
    (tester) async {
      const itemCount = 10;
      final widths = List<double>.filled(itemCount, 100);
      final fingerprints = List<int>.filled(itemCount, 0);
      late StateSetter rebuild;
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
        contentFingerprint: (index) => fingerprints[index],
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 100,
            width: 200,
            child: StatefulBuilder(builder: (context, setState) {
              rebuild = setState;
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(width: widths[index], child: Text('$index')),
                ),
              );
            }),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final initial = controller.scrollTo(8, duration: Duration.zero);
      await tester.pumpAndSettle();
      await initial;

      rebuild(() {
        widths[2] = 150;
        fingerprints[2] = 1;
      });
      await tester.pumpAndSettle();

      final recovery = controller.scrollTo(5.5, duration: Duration.zero);
      await tester.pumpAndSettle();
      await recovery;
      expect(controller.position.pixels, closeTo(600, 1));
    },
  );
}
