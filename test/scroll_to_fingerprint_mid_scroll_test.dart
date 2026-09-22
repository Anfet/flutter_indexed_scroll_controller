import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-47: an automatic-mode operation must not keep moving toward a target
/// computed from the data version that existed when it began.
void main() {
  testWidgets('a fingerprint change during an animated search cancels and stops at the current offset', (
    WidgetTester tester,
  ) async {
    const itemCount = 100;
    const rowHeight = 100.0;
    const changedRowHeight = 240.0;
    const targetIndex = 90;
    final heights = List<double>.filled(itemCount, rowHeight);
    final fingerprints = List<int>.filled(itemCount, 0);
    late StateSetter rebuild;

    final controller = IndexedScrollController(
      scrollDuration: const Duration(milliseconds: 100),
      itemCount: () => itemCount,
      contentFingerprint: (index) => fingerprints[index],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return ListView.builder(
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  return controller.watch(
                    index: index,
                    child: SizedBox(height: heights[index], child: Text('row $index')),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scroll = controller.scrollTo(targetIndex.toDouble(), duration: const Duration(milliseconds: 100));
    final cancellation = expectLater(
      scroll,
      throwsA(
        isA<ScrollCancelledException>().having(
          (error) => error.reason,
          'reason',
          ScrollCancelReason.dataInvalidated,
        ),
      ),
    );

    // The first frame starts the sequential search and leaves an animateTo
    // pending. Mutating afterward guarantees the change happens while this
    // operation is suspended, rather than before its start snapshot exists.
    await tester.pump();
    rebuild(() {
      heights[0] = changedRowHeight;
      fingerprints[0] = 1;
    });
    await tester.pump();
    for (int frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await cancellation;

    final offsetAtCancellation = controller.position.pixels;
    expect(
      offsetAtCancellation,
      lessThan(targetIndex * rowHeight),
      reason: 'The in-flight operation must stop before it reaches its old target.',
    );

    await tester.pump(const Duration(milliseconds: 500));
    expect(
      controller.position.pixels,
      closeTo(offsetAtCancellation, 0.1),
      reason: 'Stopping the Future alone is insufficient: no old animateTo activity may keep moving the viewport.',
    );
  });
}
