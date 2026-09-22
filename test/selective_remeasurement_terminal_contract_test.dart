import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  testWidgets('changed last item as the target uses its recovered extent', (tester) async {
    const count = 20;
    final heights = List<double>.filled(count, 100);
    final fingerprints = List<int>.filled(count, 0);
    late StateSetter rebuild;
    final controller = IndexedScrollController(
      scrollDuration: const Duration(milliseconds: 100),
      itemCount: () => count,
      contentFingerprint: (index) => fingerprints[index],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 200,
          child: StatefulBuilder(builder: (context, setState) {
            rebuild = setState;
            return ListView.builder(
              controller: controller,
              itemCount: count,
              itemBuilder: (context, index) => controller.watch(
                index: index,
                child: SizedBox(height: heights[index], child: Text('$index')),
              ),
            );
          }),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final initial = controller.scrollTo(19, duration: Duration.zero);
    await tester.pumpAndSettle();
    await initial;

    rebuild(() {
      heights[19] = 300;
      fingerprints[19] = 1;
    });
    await tester.pumpAndSettle();
    final recovery = controller.scrollTo(19, alignment: 1, duration: Duration.zero);
    await tester.pumpAndSettle();
    await recovery;
    expect(controller.position.pixels, closeTo(2000, 1));
  });

  testWidgets('automatic mode rejects watch index differing from physical slot', (tester) async {
    const count = 10;
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => count,
      contentFingerprint: (index) => index,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: ListView.builder(
            controller: controller,
            itemCount: count,
            itemBuilder: (context, physicalIndex) => controller.watch(
              // Keep every logical key present while putting two of them in
              // the wrong physical slots. A missing-key fixture would only
              // exercise the earlier contiguous-index StateError.
              index: switch (physicalIndex) {
                2 => 3,
                3 => 2,
                _ => physicalIndex,
              },
              child: const SizedBox(height: 100),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final scroll = controller.scrollTo(3, duration: Duration.zero);
    final error = expectLater(
      scroll,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('does not match its row\'s actual physical position'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await error;
  });
}
