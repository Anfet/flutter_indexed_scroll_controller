import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-48 acceptance criterion for the selective recovery work in ISC-49/50.
///
/// The automatic base mode deliberately clears and re-measures its full
/// required prefix after it finds a changed fingerprint. This test records the
/// promised improvement: two changed rows must be recovered without throwing
/// away trustworthy measurements between them. Flutter may still lay out
/// intermediary children while its SliverList recalculates geometry.
void main() {
  testWidgets(
    'two changed rows recover the exact offset without clearing unchanged measurements',
    (WidgetTester tester) async {
      const itemCount = 40;
      const rowHeight = 80.0;
      const firstChangedIndex = 3;
      const unchangedIndex = 12;
      const secondChangedIndex = 20;
      const targetIndex = 30;

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
            body: SizedBox(
              height: 200,
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        height: heights[index],
                        child: Text('row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Populate a continuous, trustworthy prefix before mutating two rows
      // that are outside the final viewport. Index 7 is deliberately between
      // them: an implementation that falls back to a full scan from zero
      // will lay it out again, while a selective recovery can keep its size.
      final initialScroll = controller.scrollTo(
        targetIndex.toDouble(),
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
      await initialScroll;
      final generationBeforeRecovery = controller.measurementGeneration;
      expect(controller.measurementsSizes.containsKey(unchangedIndex), isTrue);

      rebuild(() {
        heights[firstChangedIndex] = 120;
        fingerprints[firstChangedIndex] = 1;
        heights[secondChangedIndex] = 150;
        fingerprints[secondChangedIndex] = 1;
      });
      await tester.pumpAndSettle();

      final recovery = controller.scrollTo(
        targetIndex.toDouble(),
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
      await recovery;

      expect(
        controller.position.pixels,
        closeTo(2510, 1),
        reason: 'The target offset is 30 * 80 + (120 - 80) + (150 - 80).',
      );
      expect(
        controller.measurementGeneration,
        generationBeforeRecovery,
        reason: 'ISC-48: a fingerprint mismatch must not clear the complete '
            'measurement cache. SliverList may choose to lay out row '
            '$unchangedIndex while changing viewports, but the controller '
            'must retain its cached Size as a trustworthy anchor.',
      );
    },
  );
}
