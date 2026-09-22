import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'support/scroll_harness.dart';

void main() {
  group('ISC-97: fingerprint-corridor frontier jump with a preceding sliver', () {
    testWidgets('the frontier jump lands on the row\'s coordinate including precedingScrollExtent, not the raw sliver-local layoutOffset', (
      tester,
    ) async {
      // ISC-97 third acceptance round: _frontierJumpTarget's live layoutOffset
      // is a coordinate WITHIN the list sliver, not within the scrollable's
      // own coordinate space position.pixels/jumpTo use. A preceding sliver
      // shifts every live layoutOffset by its own extent, so a frontier jump
      // that forgot to add precedingScrollExtent would land
      // precedingScrollExtent px short of the correct scrollable-space
      // coordinate on the jump itself.
      //
      // The walk's OWN final resting position is not a reliable observable
      // for this: ISC-97/98's architecture always re-derives the final leg's
      // targetPixels from live geometry once materialized
      // (_anchoredPriorExtent/_prefixExtentBefore in _runAnimateTo, both
      // already preceding-extent-correct), so a wrong frontier-jump landing
      // spot silently self-corrects by the time scrollTo() resolves --
      // confirmed directly by reverting the fix locally and observing the
      // final position.pixels stay unchanged. The jump itself, captured via
      // a ScrollPosition listener the moment it happens, is the only place
      // this bug is actually observable.
      //
      // Needs the already-materialized span to genuinely exceed one
      // `viewportDimension + cacheExtent` stride, or the walk never takes
      // the frontier-jump branch at all (confirmed separately: a uniform-
      // height list's live range rarely exceeds that on its own). Reusing
      // the overgrown-row shape from
      // isc96_contiguous_viewport_walk_probe_test.dart's tall-row
      // regression -- known to force the frontier-jump branch -- with a
      // preceding sliver added.
      const precedingHeight = 150.0;
      const viewportHeight = 500.0;
      const targetIndex = 2;
      final rowHeights = [100.0, 10000.0, 100.0];
      final revisions = [0, 0, 0];
      final rowKeys = <int, GlobalKey>{};
      final controller = IndexedScrollController(
        scrollDuration: Duration.zero,
        itemCount: () => 3,
        contentFingerprint: (index) => revisions[index],
      );
      late StateSetter setOuterState;
      addTearDown(controller.dispose);

      GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return CustomScrollView(
                    controller: controller,
                    slivers: [
                      const SliverToBoxAdapter(child: SizedBox(height: precedingHeight)),
                      SliverList.builder(
                        itemCount: 3,
                        itemBuilder: (context, index) => controller.watch(
                          index: index,
                          child: SizedBox(
                            key: rowKeyFor(index),
                            height: rowHeights[index],
                            child: Text('Row $index'),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.precedingScrollExtentForTesting, precedingHeight);

      await pumpUntilComplete(tester, controller.scrollTo(2, duration: Duration.zero));
      await pumpUntilComplete(tester, controller.scrollTo(0, duration: Duration.zero));

      setOuterState(() {
        rowHeights[1] = 12000.0;
        revisions[1]++;
      });

      // Row 1's now 12000px extent guarantees the already-materialized span
      // the frontier jump would cross (viewportHeight, since it and row 0
      // are the only rows currently live below the target) exceeds an
      // ordinary stride, forcing the walk to take the frontier-jump branch.
      final observedJumps = <double>[];
      void recordJump() => observedJumps.add(controller.position.pixels);
      controller.addListener(recordJump);
      addTearDown(() => controller.removeListener(recordJump));

      await pumpUntilComplete(
        tester,
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero),
        maxPumps: 600,
      );

      expect(controller.fingerprintFor(1), revisions[1]);
      expect(controller.measurementsSizes[1]?.height, closeTo(12000.0, 0.5));
      expect(
        _sliverLayoutOffsetOf(rowKeys[targetIndex]),
        isNotNull,
        reason: 'target row must be materialized once scrollTo completes',
      );

      // Moving forwards, the frontier jump targets row 1's own start PLUS its
      // extent (the coordinate where row 2, the not-yet-materialized next
      // row, begins) -- see _frontierJumpTarget's Dartdoc. In scrollable
      // (not sliver-local) coordinates that is precedingHeight + row 0's
      // extent + row 1's extent.
      final correctFrontierLanding = precedingHeight + rowHeights[0] + rowHeights[1];
      final wrongFrontierLanding = correctFrontierLanding - precedingHeight; // the pre-fix bug's landing spot.
      expect(
        observedJumps.any((pixels) => (pixels - correctFrontierLanding).abs() <= 1.0),
        isTrue,
        reason: 'the frontier jump must land on precedingScrollExtent + the sliver-local coordinate '
            '($correctFrontierLanding), not the raw layoutOffset alone ($wrongFrontierLanding) -- '
            'observed jumps: $observedJumps',
      );
    });
  });

  group('ISC-75: preceding sliver extent', () {
    testWidgets('CustomScrollView accounts for a preceding sliver when aligning a measured target', (tester) async {
      const precedingHeight = 150.0;
      const itemHeight = 80.0;
      const targetIndex = 20;
      final controller = IndexedScrollController(scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: precedingHeight)),
                SliverList.builder(
                  itemCount: 40,
                  itemBuilder: (context, index) => controller.watch(
                    index: index,
                    child: SizedBox(height: itemHeight, child: Text('Item $index')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.precedingScrollExtentForTesting, precedingHeight);

      await pumpUntilComplete(
        tester,
        controller.scrollTo(targetIndex.toDouble(), duration: const Duration(milliseconds: 100)),
      );

      expect(controller.position.pixels, closeTo(precedingHeight + targetIndex * itemHeight, 1.0));
      expect(tester.getTopLeft(find.text('Item $targetIndex')).dy, closeTo(0.0, 1.0));
    });
  });

  group('ISC-77: unbounded preceding sliver', () {
    testWidgets('an unbounded preceding SliverList makes scrollTo fail instead of searching forever', (tester) async {
      final controller = IndexedScrollController(scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => const SizedBox(height: 80.0),
                  ),
                ),
                SliverList.builder(
                  itemCount: 20,
                  itemBuilder: (context, index) => controller.watch(
                    index: index,
                    child: SizedBox(height: 80.0, child: Text('Indexed item $index')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.precedingScrollExtentForTesting.isFinite, isFalse);

      final expectation = expectLater(
        controller.scrollTo(5, duration: Duration.zero),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('unknown number of children'),
          ),
        ),
      );
      await tester.pump();
      await expectation;
    });
  });

  group('ISC-78: collapsing SliverAppBar', () {
    // todo.md's "Известные границы" flagged this as worth checking before
    // release, reasoning that a floating/snap SliverAppBar's visible extent
    // changes as it collapses/re-expands while scrolling, unlike a fixed
    // preceding sliver -- so SliverConstraints.precedingScrollExtent might
    // track that visible extent instead of a fixed value, silently
    // producing a moving target for the offset formula.
    //
    // It does not: precedingScrollExtent stays constant at expandedHeight
    // regardless of floating/pinned/snap or current scroll position --
    // confirmed by sweeping controller.precedingScrollExtentForTesting
    // across offsets 0..250 with a 200px floating+snap SliverAppBar and
    // seeing it read 200.0 throughout. The collapse/float animation is a
    // paint/layout-extent interaction, not a scrollExtent change, so the
    // sliver protocol's precedingScrollExtent contract (a fixed value per
    // ISC-75's Dartdoc) already covers this case; nothing here needed a
    // code change, only this test and the "verified, not a limitation"
    // update to README/CHANGELOG's known-limitations text.
    testWidgets('scrollTo lands at the exact offset with a floating+snap SliverAppBar preceding the list', (tester) async {
      const appBarHeight = 200.0;
      const itemHeight = 100.0;
      const targetIndex = 20;
      final controller = IndexedScrollController(scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: controller,
              slivers: [
                const SliverAppBar(
                  expandedHeight: appBarHeight,
                  floating: true,
                  pinned: false,
                  snap: true,
                  flexibleSpace: FlexibleSpaceBar(title: Text('Title')),
                ),
                SliverList.builder(
                  itemCount: 40,
                  itemBuilder: (context, index) => controller.watch(
                    index: index,
                    child: SizedBox(height: itemHeight, child: Text('Item $index')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.precedingScrollExtentForTesting, appBarHeight,
          reason: 'A floating+snap SliverAppBar still reports a fixed precedingScrollExtent, same as pinned');

      await pumpUntilComplete(
        tester,
        controller.scrollTo(targetIndex.toDouble(), duration: const Duration(milliseconds: 100)),
      );

      expect(controller.position.pixels, closeTo(appBarHeight + targetIndex * itemHeight, 1.0));

      // Re-check after the app bar has scrolled away and collapsed (per its
      // own floating/snap animation), to confirm the formula does not
      // silently track a now-changed visible extent.
      expect(
        controller.precedingScrollExtentForTesting,
        appBarHeight,
        reason: 'precedingScrollExtent must still read the fixed expandedHeight after the app '
            'bar has scrolled out of view and collapsed, not some smaller "currently visible" '
            'extent',
      );
    });
  });
}

/// Same helper as `isc96_contiguous_viewport_walk_probe_test.dart`: the raw
/// sliver-space `layoutOffset` reported by [SliverMultiBoxAdaptorParentData]
/// for a live row, or `null` when it is not currently laid out. Used only to
/// confirm materialization here -- the position.pixels assertion (the actual
/// preceding-sliver-extent check under test) reads the scrollable's own
/// coordinate space instead, which is exactly the distinction the fix being
/// tested is about.
double? _sliverLayoutOffsetOf(GlobalKey? key) {
  final renderObject = key?.currentContext?.findRenderObject();
  if (renderObject == null || !renderObject.attached) return null;
  for (RenderObject? node = renderObject; node != null; node = node.parent) {
    final parentData = node.parentData;
    if (parentData is SliverMultiBoxAdaptorParentData) return parentData.layoutOffset;
  }
  return null;
}
