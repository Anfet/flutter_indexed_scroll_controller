import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-90: regression test converted from the `isc_converge_to_zero_test`
/// diagnostic stand. Grows five rows far behind the viewport, then scrolls
/// forward across the growth without walking back over it, then all the way
/// back to index 0.
///
/// ISC-88 fixed the target row mounting at all (it used to stay `onScreen ==
/// null`, clamped short of it); ISC-98 fixed the residual ISC-94 gap this
/// file previously asserted was expected: the computed offset now equals the
/// target row's own live layoutOffset, so `onScreenDelta(80)` after the
/// forward leg is asserted flush too, not merely mounted. Reaching index 0
/// is self-proving (`offset == minScrollExtent`) and does not depend on
/// `maxScrollExtent`'s estimate, which the SDK notes in todo.md document as
/// an extrapolation, not the true content length -- so it is not asserted
/// to a precise value here.
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

  testWidgets('growing rows far behind the viewport, forward then all the way back to 0', (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const duration = Duration(milliseconds: 300);
    // ~10 rows per screen to start with.
    final rowHeights = List<double>.generate(itemCount, (i) => [40.0, 50.0, 60.0][i % 3]);
    final revisions = List<int>.filled(itemCount, 0);

    final controller = IndexedScrollController(
      scrollDuration: duration,
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

    Future<void> animateTo(double target) async {
      var done = false;
      Object? err;
      controller.scrollTo(target, duration: duration, alignment: 0.0).then(
        (_) => done = true,
        onError: (Object e) {
          done = true;
          err = e;
        },
      );
      for (var i = 0; i < 600 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 16));
      if (err != null) {
        fail('scrollTo($target) threw: $err');
      }
      if (!done) {
        fail('scrollTo($target) never completed');
      }
    }

    double? onScreenDelta(int index) {
      final lb = listKey.currentContext!.findRenderObject()! as RenderBox;
      final rb = rowKeys[index]?.currentContext?.findRenderObject() as RenderBox?;
      if (rb == null || !rb.attached) return null;
      return rb.localToGlobal(Offset.zero).dy - lb.localToGlobal(Offset.zero).dy;
    }

    // Build up measurements on the way out to the middle of the list.
    await animateTo(50);

    // Grow rows that are far behind the viewport, by a lot: each of these is
    // several screens tall on its own, so a stale extent cannot be mistaken
    // for a rounding error.
    const grown = [3, 7, 12, 19, 26];
    setOuterState(() {
      for (final i in grown) {
        rowHeights[i] = 900.0;
        revisions[i]++;
      }
    });
    await tester.pump(const Duration(milliseconds: 16));

    // Forward first -- the grown rows are behind us and must not disturb it.
    await animateTo(80);
    expect(
      onScreenDelta(80),
      isNotNull,
      reason: 'row 80 must mount -- this is what ISC-88 fixed; it used to clamp short of the target '
          'and never mount at all',
    );
    final layoutOffsetAt80 = sliverLayoutOffsetOf(rowKeys[80]);
    expect(layoutOffsetAt80, isNotNull, reason: 'target row must be materialized once scrollTo completes');
    expect(
      controller.offset,
      closeTo(layoutOffsetAt80!, 0.5),
      reason: 'the computed offset must equal row 80\'s own live layoutOffset ($layoutOffsetAt80) -- '
          'ISC-98 sources the final coordinate from the sliver\'s own paint, closing the ISC-94 gap this '
          'file used to only tolerate',
    );
    // ISC-98: flush with the viewport top exactly, not merely mounted --
    // this is the visible half of the same fix the offset assertion above
    // proves arithmetically.
    expect(
      onScreenDelta(80),
      closeTo(0, 0.5),
      reason: 'row 80 must sit flush with the viewport top',
    );

    // Now all the way back. The walk passes every grown row, so by the time
    // index 0 is reached the list knows its true extents.
    await animateTo(0);

    expect(
      controller.offset,
      closeTo(controller.position.minScrollExtent, 0.5),
      reason: 'index 0 is the start of the content, so its aligned offset is minScrollExtent -- '
          'self-proving, no external reference needed',
    );
    expect(
      onScreenDelta(0),
      closeTo(0, 0.5),
      reason: 'row 0 should sit flush with the viewport top',
    );

    // The cache must hold the true, current sizes for every grown row --
    // reaching index 0 means the walk passed over all of them.
    for (final i in grown) {
      expect(
        controller.measurementsSizes[i]?.height,
        rowHeights[i],
        reason: 'cache for grown row $i must match its current height after the walk back to 0',
      );
    }
  });
}
