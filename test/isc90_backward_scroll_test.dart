import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'support/scroll_harness.dart';

/// ISC-90: regression test converted from the `isc_backward_scroll_probe_test`
/// diagnostic stand. Walks the list forward to build up measurements,
/// reshuffles five rows spread across the prefix, then scrolls BACKWARD past
/// them -- the direction the ISC-88 guard-condition bug used to break.
///
/// ISC-98 changed what "the arithmetic invariant" means here -- see
/// isc90_animated_reshuffle_test.dart's file-level Dartdoc: the final
/// coordinate now comes from the target row's own live layoutOffset, not a
/// summed prefix, so it can legitimately differ from the prefix sum in
/// exactly the reshuffled-row scenario this file exercises.
void main() {
  /// The live scroll offset the sliver has assigned to [index]'s row, read
  /// straight off `SliverMultiBoxAdaptorParentData` via its `GlobalKey`.
  double? sliverLayoutOffsetOf(GlobalKey? key) {
    final renderObject = key?.currentContext?.findRenderObject();
    if (renderObject == null || !renderObject.attached) return null;
    for (RenderObject? node = renderObject; node != null; node = node.parent) {
      final parentData = node.parentData;
      if (parentData is SliverMultiBoxAdaptorParentData) return parentData.layoutOffset;
    }
    return null;
  }

  testWidgets('forward to 90, reshuffle five rows, backward to 50 lands exactly', (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    // ~10 rows per screen: 40/50/60 average 50, so 500 / 50 == 10.
    const heights = [40.0, 50.0, 60.0];
    final rowHeights = List<double>.generate(itemCount, (i) => heights[i % 3]);
    final revisions = List<int>.filled(itemCount, 0);

    final controller = IndexedScrollController(
      scrollDuration: const Duration(seconds: 1),
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    addTearDown(controller.dispose);

    final listKey = GlobalKey();
    final rowKeys = <int, GlobalKey>{};
    GlobalKey rowKeyFor(int i) => rowKeys.putIfAbsent(i, () => GlobalKey());
    late StateSetter setOuterState;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: ColoredBox(
                          color: index.isEven ? const Color(0xFFBBDEFB) : const Color(0xFFFFE0B2),
                          child: Center(child: Text('Row $index')),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double prefixOf(int index) => rowHeights.take(index).fold<double>(0, (a, b) => a + b);

    double? onScreenDelta(int index) {
      final lb = listKey.currentContext!.findRenderObject()! as RenderBox;
      final rb = rowKeys[index]?.currentContext?.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) return null;
      return rb.localToGlobal(Offset.zero).dy - lb.localToGlobal(Offset.zero).dy;
    }

    // Phase 1: forward 0 -> 90, building measurements on the way.
    await pumpUntilComplete(tester, controller.scrollTo(90, duration: const Duration(seconds: 1), alignment: 0.0));

    // Phase 2: reshuffle five rows spread across the prefix, none of them
    // grown far enough to trigger ISC-94's stale-anchor limit.
    const touched = [12, 27, 41, 58, 73];
    setOuterState(() {
      for (final i in touched) {
        final others = heights.where((h) => h != rowHeights[i]).toList();
        rowHeights[i] = others[i % others.length];
        revisions[i]++;
      }
    });
    await tester.pump(const Duration(milliseconds: 16));

    // Phase 3: backward 90 -> 50, walking back past every reshuffled row.
    await pumpUntilComplete(tester, controller.scrollTo(50, duration: const Duration(seconds: 1), alignment: 0.0));

    // The arithmetic invariant the controller is actually responsible for
    // post-ISC-98: the computed offset equals the target row's own live
    // layoutOffset, not necessarily the prefix sum -- see the file-level
    // Dartdoc.
    final layoutOffset = sliverLayoutOffsetOf(rowKeys[50]);
    expect(layoutOffset, isNotNull, reason: 'target row must be materialized once scrollTo completes');
    expect(
      controller.offset,
      closeTo(layoutOffset!, 0.5),
      reason: 'the recovered offset must equal row 50\'s own live layoutOffset ($layoutOffset), not '
          'necessarily the prefix sum (${prefixOf(50)})',
    );
    for (var i = 0; i <= 50; i++) {
      expect(
        controller.measurementsSizes[i]?.height,
        rowHeights[i],
        reason: 'cache for row $i must match the current data after the backward walk',
      );
    }

    // The visible result: ISC-98 closes the ISC-94 gap by sourcing the final
    // coordinate from the sliver's own live layoutOffset, so row 50 lands
    // flush with the viewport top exactly, not merely within a
    // reshuffle-sized residual.
    expect(
      onScreenDelta(50),
      closeTo(0, 0.5),
      reason: 'row 50 must sit flush with the viewport top',
    );
  });
}
