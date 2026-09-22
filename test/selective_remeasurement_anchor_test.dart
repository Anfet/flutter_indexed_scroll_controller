import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-49: a layout of an old child is not evidence that it represents the
/// current data version. The selective path has one frame to obtain a fresh
/// registration for its anchor, then fails diagnostically.
void main() {
  testWidgets(
    'changed data without a rebuild reports StateError instead of accepting the old anchor layout',
    (WidgetTester tester) async {
      const itemCount = 30;
      const rowHeight = 80.0;
      const targetIndex = 18;
      const changedIndex = targetIndex;
      final heights = List<double>.filled(itemCount, rowHeight);
      final fingerprints = List<int>.filled(itemCount, 0);

      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => itemCount,
        contentFingerprint: (index) => fingerprints[index],
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: ListView.builder(
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(
                    height: heights[index],
                    child: Text('row $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final initialScroll = controller.scrollTo(
        targetIndex.toDouble(),
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
      await initialScroll;

      // Deliberately do not call setState or pump a new ListView. The data
      // callback exposes the new version, but every mounted child still
      // carries its old build-time fingerprint and geometry.
      heights[changedIndex] = 140;
      fingerprints[changedIndex] = 1;

      final recovery = controller.scrollTo(
        targetIndex.toDouble(),
        duration: Duration.zero,
      );
      final error = expectLater(
        recovery,
        throwsA(
          isA<StateError>().having(
            (exception) => exception.message,
            'message',
            contains('fresh registration'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await error;
    },
  );
}
