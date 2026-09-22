import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'support/scroll_harness.dart';

/// ISC-96/ISC-97: the fingerprint-corridor recovery walk, exercised through
/// the PUBLIC `scrollTo` -- not by manually driving `controller.jumpTo` in a
/// loop the way this file's pre-ISC-97 version did. That version's green
/// result proved only that a hand-rolled walk matching the intended algorithm
/// could work, never that `scrollTo`'s own implementation of it did (see the
/// ISC-97 acceptance review in todo.md, point 4).
void main() {
  testWidgets('scrollTo(50) after scrollTo(90) refreshes changes between 90 and 50 without invalidation', (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 50;
    const initialHeights = [40.0, 50.0, 60.0];

    const changedIndices = [55, 64, 70, 81];
    final rowHeights = List<double>.generate(itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

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
                        child: Text('Row $index'),
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

    await pumpUntilComplete(tester, controller.scrollTo(90, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[90]), isNotNull, reason: 'the experiment must begin around row 90');

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    // The operation begins before another frame has rebuilt the changed rows.
    // Their cached fingerprints therefore still describe the previous data,
    // while the callback already exposes the new revisions.
    final changedInTravelCorridor = <int>[
      for (var index = targetIndex; index <= 90; index++)
        if (!controller.hasFingerprintFor(index) || controller.fingerprintFor(index) != revisions[index]) index,
    ];
    expect(changedInTravelCorridor, changedIndices, reason: 'the fingerprint scan must identify exactly the changed rows on the physical path');

    final registrationsBeforeWalk = <int, int>{for (final index in changedIndices) index: controller.registrationCountFor(index)};

    // The public entry point this whole recovery mechanism exists to serve --
    // scrollTo() itself must detect the mismatch, walk the corridor, and
    // materialize the target, with no test-side jumpTo loop standing in for
    // any part of that.
    await pumpUntilComplete(tester, controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    for (final index in changedIndices) {
      expect(
        controller.registrationCountFor(index),
        greaterThan(registrationsBeforeWalk[index]!),
        reason: 'changed row $index must perform a fresh layout while the walk passes over it',
      );
      expect(controller.fingerprintFor(index), revisions[index], reason: 'row $index must register the fingerprint of its rebuilt version');
      expect(
        controller.measurementsSizes[index]?.height,
        rowHeights[index],
        reason: 'changed row $index must publish its current size while the walk passes over it',
      );
    }

    // The corridor was walked, every changed row got a fresh registration,
    // and the target materialized -- confirmed above and by this assertion.
    expect(_sliverLayoutOffsetOf(rowKeys[targetIndex]), isNotNull, reason: 'target row must be materialized once scrollTo completes');
    // ISC-98's own scope, now landed: the target row is flush with the
    // viewport top, not merely materialized somewhere -- see
    // isc95_target_materialization_test.dart's file-level Dartdoc for the
    // live-layoutOffset contract this asserts.
    expect(
      _onScreenDelta(listKey, rowKeys[targetIndex]),
      closeTo(0, 0.5),
      reason: 'scrollTo must put row $targetIndex at the viewport start',
    );
  });

  testWidgets(
    'a mismatch and the target both already live in the same viewport: the target\'s own offset is not trusted stale',
    (tester) async {
      // ISC-98 second acceptance round (architect's decision, todo.md): an
      // onscreen anchor-frame recheck fixes ONLY the mismatched row's own
      // _sizes entry -- it does not force RenderSliverList to revisit
      // anything downstream. When the mismatch AND the target are both
      // already live in the current viewport before scrollTo is even
      // called, no corridor travel of any kind is needed to bring the
      // target on screen, so a naive "materialized == trustworthy" walk
      // would report success immediately after the single anchor-frame
      // recheck, with the target's own (never revisited) layoutOffset still
      // describing the pre-change content. This mirrors
      // selective_remeasurement_horizontal_test.dart's originally-found
      // case (horizontal, scrolled far from 0) with the opposite shape:
      // vertical, BOTH rows already on screen with nothing to scroll at
      // all.
      const itemCount = 20;
      const viewportHeight = 400.0;
      const rowHeight = 40.0; // 10 rows visible at once: 400 / 40.
      const changedIndex = 3;
      const targetIndex = 7;

      final rowHeights = List<double>.filled(itemCount, rowHeight);
      final revisions = List<int>.filled(itemCount, 0);
      final rowKeys = <int, GlobalKey>{};
      final listKey = GlobalKey();
      final controller = IndexedScrollController(
        scrollDuration: Duration.zero,
        itemCount: () => itemCount,
        contentFingerprint: (index) => revisions[index],
      );
      late StateSetter setOuterState;
      addTearDown(controller.dispose);

      GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

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
                          child: Text('Row $index'),
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

      // Every row from 0 is already live at the initial scroll offset (0) --
      // no scrollTo has run yet, and both changedIndex (3) and targetIndex
      // (7) sit well within the first viewport's worth of rows.
      expect(_sliverLayoutOffsetOf(rowKeys[changedIndex]), isNotNull, reason: 'sanity: the changed row must already be live before scrollTo runs');
      expect(_sliverLayoutOffsetOf(rowKeys[targetIndex]), isNotNull, reason: 'sanity: the target row must already be live before scrollTo runs');

      setOuterState(() {
        rowHeights[changedIndex] += 60.0; // 40 -> 100, a real, non-trivial growth.
        revisions[changedIndex]++;
      });

      final registrationsBeforeWalk = controller.registrationCountFor(changedIndex);

      // scrollTo(7) itself must detect the mismatch at row 3 (still live and
      // on screen), recover it, and -- the case this test exists for --
      // notice that row 7's OWN layoutOffset has not moved to reflect row
      // 3's growth, so it must keep working (not report success on the
      // stale offset) until row 7 is itself geometry-consistent.
      await pumpUntilComplete(tester, controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

      expect(
        controller.registrationCountFor(changedIndex),
        greaterThan(registrationsBeforeWalk),
        reason: 'the changed row must get a fresh layout',
      );
      expect(controller.fingerprintFor(changedIndex), revisions[changedIndex]);

      final expectedPixels = rowHeights.take(targetIndex).fold<double>(0, (a, b) => a + b);
      expect(
        controller.position.pixels,
        closeTo(expectedPixels, 0.5),
        reason: 'the computed offset must reflect row $changedIndex\'s growth ($expectedPixels), not a stale '
            'pre-growth sum a naive "materialized is enough" check would have trusted',
      );
      expect(
        _onScreenDelta(listKey, rowKeys[targetIndex]),
        closeTo(0, 0.5),
        reason: 'scrollTo must put row $targetIndex at the viewport start, using its own now-consistent layoutOffset',
      );
    },
  );

  testWidgets(
    'two below-target mismatches already live: only the minimal anchor catches their shared stale shift',
    (tester) async {
      // ISC-98 third acceptance round (architect's decision, todo.md): the
      // operation-local recovery certificate must use the LOWEST-index
      // below-target mismatch this operation fixes, not the most recently
      // fixed one. Two changed rows (2 and 4) both sit below target 7,
      // already live in the same viewport with nothing to scroll -- row 4,
      // checked alone against the target, can still agree with it while
      // both still carry the very same stale shift left over from row 2's
      // growth (the sliver absorbed 2's growth without revisiting anything
      // downstream in the same frame). Only anchoring on row 2 -- the
      // minimal mismatch -- exposes that shared shift.
      const itemCount = 20;
      const viewportHeight = 400.0;
      const rowHeight = 40.0; // 10 rows visible at once: 400 / 40.
      const firstChangedIndex = 2;
      const secondChangedIndex = 4;
      const targetIndex = 7;

      final rowHeights = List<double>.filled(itemCount, rowHeight);
      final revisions = List<int>.filled(itemCount, 0);
      final rowKeys = <int, GlobalKey>{};
      final listKey = GlobalKey();
      final controller = IndexedScrollController(
        scrollDuration: Duration.zero,
        itemCount: () => itemCount,
        contentFingerprint: (index) => revisions[index],
      );
      late StateSetter setOuterState;
      addTearDown(controller.dispose);

      GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

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
                          child: Text('Row $index'),
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

      expect(_sliverLayoutOffsetOf(rowKeys[firstChangedIndex]), isNotNull, reason: 'sanity: row 2 must already be live before scrollTo runs');
      expect(_sliverLayoutOffsetOf(rowKeys[secondChangedIndex]), isNotNull, reason: 'sanity: row 4 must already be live before scrollTo runs');
      expect(_sliverLayoutOffsetOf(rowKeys[targetIndex]), isNotNull, reason: 'sanity: the target row must already be live before scrollTo runs');

      setOuterState(() {
        rowHeights[firstChangedIndex] += 60.0; // 40 -> 100.
        revisions[firstChangedIndex]++;
        rowHeights[secondChangedIndex] += 20.0; // 40 -> 60.
        revisions[secondChangedIndex]++;
      });

      final registrationsBeforeWalk = {
        firstChangedIndex: controller.registrationCountFor(firstChangedIndex),
        secondChangedIndex: controller.registrationCountFor(secondChangedIndex),
      };

      await pumpUntilComplete(tester, controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

      for (final index in [firstChangedIndex, secondChangedIndex]) {
        expect(
          controller.registrationCountFor(index),
          greaterThan(registrationsBeforeWalk[index]!),
          reason: 'changed row $index must get a fresh layout',
        );
        expect(controller.fingerprintFor(index), revisions[index]);
      }

      final expectedPixels = rowHeights.take(targetIndex).fold<double>(0, (a, b) => a + b);
      expect(
        controller.position.pixels,
        closeTo(expectedPixels, 0.5),
        reason: 'the computed offset must reflect both rows\' growth ($expectedPixels), not a value that only '
            'accounted for one of them',
      );
      expect(
        _onScreenDelta(listKey, rowKeys[targetIndex]),
        closeTo(0, 0.5),
        reason: 'scrollTo must put row $targetIndex at the viewport start, using its own now-consistent layoutOffset',
      );
    },
  );

  testWidgets(
    'scrollTo(90) then grow(15, 60) then scrollTo(70): the target reflows from row 0, not a stale anchor chain',
    (tester) async {
      // ISC-98 final acceptance round (architect's decision, todo.md): two
      // below-target mismatches (15 and 60) physically far apart from each
      // other and from the target (70) and from the starting position (90).
      // Every local freshness signal tried before this decision --
      // materialization, registration count, an offset change, relative
      // agreement between an anchor and the target, even an OBSERVED
      // detach/rematerialize cycle for the target itself -- was measured to
      // report success while row 70's live layoutOffset still described the
      // PRE-growth content (3490px instead of the correct 3610px): the
      // sliver can relay out row 70 relative to its own still-stale internal
      // anchor chain even after a genuine detach and rematerialize. Only an
      // absolute reflow from the list-sliver's own row 0 -- monotonic,
      // ordinary strides only, no frontier jump -- closes this gap. Without
      // it, this scenario reproduces exactly 3490px; this test's whole
      // purpose is to fail that way if the reflow regresses.
      const itemCount = 100;
      const viewportHeight = 500.0;
      const startIndex = 90;
      const targetIndex = 70;
      const initialHeights = [40.0, 50.0, 60.0];
      const firstChangedIndex = 15;
      const secondChangedIndex = 60;

      final rowHeights = List<double>.generate(itemCount, (index) => initialHeights[index % initialHeights.length]);
      final revisions = List<int>.filled(itemCount, 0);
      final rowKeys = <int, GlobalKey>{};
      final listKey = GlobalKey();
      final controller = IndexedScrollController(
        scrollDuration: Duration.zero,
        itemCount: () => itemCount,
        contentFingerprint: (index) => revisions[index],
      );
      late StateSetter setOuterState;
      addTearDown(controller.dispose);

      GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

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
                          child: Text('Row $index'),
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

      // Build up the full 0..90 prefix first, so the later mismatches at 15
      // and 60 are genuinely STALE re-measurements (already cached, then
      // invalidated) rather than never-measured holes the ordinary search
      // path would fill anyway.
      await pumpUntilComplete(tester, controller.scrollTo(startIndex.toDouble(), duration: Duration.zero));
      expect(_sliverLayoutOffsetOf(rowKeys[startIndex]), isNotNull, reason: 'the experiment must begin around row 90');

      setOuterState(() {
        rowHeights[firstChangedIndex] += 60.0; // 40 -> 100.
        revisions[firstChangedIndex]++;
        rowHeights[secondChangedIndex] += 60.0; // 40 -> 100.
        revisions[secondChangedIndex]++;
      });

      // Sanity: both changed rows must be confirmed stale on entry -- their
      // fingerprint no longer matches the cached one -- otherwise this test
      // would not be exercising the scenario it exists for.
      expect(controller.fingerprintFor(firstChangedIndex), isNot(revisions[firstChangedIndex]));
      expect(controller.fingerprintFor(secondChangedIndex), isNot(revisions[secondChangedIndex]));

      final registrationsBeforeRow0 = controller.registrationCountFor(0);
      final registrationsBeforeTarget = controller.registrationCountFor(targetIndex);

      // Observe the mechanism itself, not merely the final pixels: the
      // reflow must actually visit content start -- row 0's own live
      // layoutOffset reaching its sliver-local zero, NOT raw
      // position.pixels, which RenderViewport can transiently correct away
      // from 0 on the very frame row 0 first lays out -- and register a
      // fresh layout of row 0 there BEFORE the forward pass ever registers a
      // fresh layout of the target (acceptance-review finding, todo.md -- a
      // route-blind test cannot distinguish a genuine reflow from a lucky
      // coincidence of the final pixels).
      var sawContentStart = false;
      var row0FreshBeforeTargetFresh = false;
      var targetRegisteredFreshYet = false;
      var monotonicSinceContentStart = true;
      double? lastPixelsSinceContentStart;
      var settled = false;
      final scrollFuture = controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero);
      scrollFuture.then((_) => settled = true, onError: (_) => settled = true);
      for (var i = 0; i < 300 && !settled; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final row0Offset = _sliverLayoutOffsetOf(rowKeys[0]);
        if (row0Offset != null && row0Offset.abs() <= 0.5) sawContentStart = true;
        if (sawContentStart) {
          if (controller.registrationCountFor(0) > registrationsBeforeRow0 && !targetRegisteredFreshYet) {
            row0FreshBeforeTargetFresh = true;
          }
          if (controller.registrationCountFor(targetIndex) > registrationsBeforeTarget) {
            targetRegisteredFreshYet = true;
          }
          final pixels = controller.position.pixels;
          final priorPixels = lastPixelsSinceContentStart;
          // The forward pass never moves backward once it has left content
          // start -- an anchor-frame recheck step does not move pixels at
          // all, which is not a decrease.
          if (priorPixels != null && pixels < priorPixels - 0.5) monotonicSinceContentStart = false;
          lastPixelsSinceContentStart = pixels;
        }
      }
      expect(settled, isTrue, reason: 'scrollTo() did not complete within 300 pumps');
      await scrollFuture;

      expect(sawContentStart, isTrue,
          reason: 'the reflow must physically lay out row 0 at its own sliver-local content start before reaching the target');
      expect(
        row0FreshBeforeTargetFresh,
        isTrue,
        reason: 'row 0 must register a fresh layout at content start before the target ever does -- proves the '
            'reflow, not just a lucky final offset',
      );
      expect(controller.registrationCountFor(0), greaterThan(registrationsBeforeRow0), reason: 'row 0 must end with a fresh registration');
      expect(controller.registrationCountFor(targetIndex), greaterThan(registrationsBeforeTarget),
          reason: 'the target must end with a fresh registration');
      expect(monotonicSinceContentStart, isTrue, reason: 'the forward pass from content start to the target must never move backward');

      final expectedPixels = rowHeights.take(targetIndex).fold<double>(0, (a, b) => a + b);
      expect(expectedPixels, 3610.0, reason: 'sanity check on the scenario\'s own arithmetic');
      expect(
        controller.position.pixels,
        closeTo(expectedPixels, 0.5),
        reason: 'the computed offset must reflect both rows\' growth ($expectedPixels) via a genuine reflow from '
            'row 0, not a coordinate inherited from a stale internal anchor chain (the measured regression '
            'value here was 3490.0, the pre-growth sum)',
      );
      expect(
        _onScreenDelta(listKey, rowKeys[targetIndex]),
        closeTo(0, 0.5),
        reason: 'scrollTo must put row $targetIndex at the viewport start',
      );
    },
  );

  testWidgets(
    'reverse: scrollTo(90) then grow(15, 60) then scrollTo(70) still reflows from row 0, not the visual edge',
    (tester) async {
      // Architect's ISC-98 acceptance-review decision (todo.md): the
      // absolute prefix-reflow branch has no dedicated reverse regression.
      // "Forward" inside _reflowFromContentStart means increasing LOGICAL
      // index, `_isReversed`-independent (see that method's Dartdoc and the
      // file-level Dartdoc on why `reverse` never inverts logical-index
      // semantics) -- row 0 is still the list-sliver's own logical start
      // even though it paints at the VISUAL bottom of the viewport under
      // `reverse: true`. This mirrors the non-reverse 15/60->70 scenario
      // above verbatim, just with `reverse: true` and the same mechanism
      // observation (row 0 fresh before target fresh, monotonic forward
      // pass), to prove that branch is exercised correctly under reverse
      // too, not merely that some reverse-agnostic formula happens to still
      // work.
      const itemCount = 100;
      const viewportHeight = 500.0;
      const startIndex = 90;
      const targetIndex = 70;
      const initialHeights = [40.0, 50.0, 60.0];
      const firstChangedIndex = 15;
      const secondChangedIndex = 60;

      final rowHeights = List<double>.generate(itemCount, (index) => initialHeights[index % initialHeights.length]);
      final revisions = List<int>.filled(itemCount, 0);
      final rowKeys = <int, GlobalKey>{};
      final listKey = GlobalKey();
      final controller = IndexedScrollController(
        scrollDuration: Duration.zero,
        itemCount: () => itemCount,
        contentFingerprint: (index) => revisions[index],
      );
      late StateSetter setOuterState;
      addTearDown(controller.dispose);

      GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

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
                      reverse: true,
                      itemCount: itemCount,
                      itemBuilder: (context, index) => controller.watch(
                        index: index,
                        child: SizedBox(
                          key: rowKeyFor(index),
                          height: rowHeights[index],
                          child: Text('Row $index'),
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

      await pumpUntilComplete(tester, controller.scrollTo(startIndex.toDouble(), duration: Duration.zero));
      expect(_sliverLayoutOffsetOf(rowKeys[startIndex]), isNotNull, reason: 'the experiment must begin around row 90');

      setOuterState(() {
        rowHeights[firstChangedIndex] += 60.0; // 40 -> 100.
        revisions[firstChangedIndex]++;
        rowHeights[secondChangedIndex] += 60.0; // 40 -> 100.
        revisions[secondChangedIndex]++;
      });

      expect(controller.fingerprintFor(firstChangedIndex), isNot(revisions[firstChangedIndex]));
      expect(controller.fingerprintFor(secondChangedIndex), isNot(revisions[secondChangedIndex]));

      final registrationsBeforeRow0 = controller.registrationCountFor(0);
      final registrationsBeforeTarget = controller.registrationCountFor(targetIndex);

      var sawContentStart = false;
      var row0FreshBeforeTargetFresh = false;
      var targetRegisteredFreshYet = false;
      var monotonicSinceContentStart = true;
      double? lastPixelsSinceContentStart;
      var settled = false;
      final scrollFuture = controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero);
      scrollFuture.then((_) => settled = true, onError: (_) => settled = true);
      for (var i = 0; i < 300 && !settled; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final row0Offset = _sliverLayoutOffsetOf(rowKeys[0]);
        if (row0Offset != null && row0Offset.abs() <= 0.5) sawContentStart = true;
        if (sawContentStart) {
          if (controller.registrationCountFor(0) > registrationsBeforeRow0 && !targetRegisteredFreshYet) {
            row0FreshBeforeTargetFresh = true;
          }
          if (controller.registrationCountFor(targetIndex) > registrationsBeforeTarget) {
            targetRegisteredFreshYet = true;
          }
          final pixels = controller.position.pixels;
          final priorPixels = lastPixelsSinceContentStart;
          if (priorPixels != null && pixels < priorPixels - 0.5) monotonicSinceContentStart = false;
          lastPixelsSinceContentStart = pixels;
        }
      }
      expect(settled, isTrue, reason: 'scrollTo() did not complete within 300 pumps');
      await scrollFuture;

      expect(sawContentStart, isTrue,
          reason: 'the reflow must physically lay out row 0 at its own sliver-local content start before reaching the target');
      expect(
        row0FreshBeforeTargetFresh,
        isTrue,
        reason: 'row 0 must register a fresh layout at content start before the target ever does, under reverse too',
      );
      expect(controller.registrationCountFor(0), greaterThan(registrationsBeforeRow0), reason: 'row 0 must end with a fresh registration');
      expect(controller.registrationCountFor(targetIndex), greaterThan(registrationsBeforeTarget),
          reason: 'the target must end with a fresh registration');
      expect(monotonicSinceContentStart, isTrue,
          reason: 'the forward pass from content start to the target must never move backward, under reverse too');

      final priorItems = rowHeights.take(targetIndex).fold<double>(0, (a, b) => a + b);
      expect(priorItems, 3610.0, reason: 'sanity check on the scenario\'s own arithmetic');
      // alignment: 0 (the default) means the visual START of the list under
      // reverse too -- which, since RenderSliverList never inverts indices,
      // is the FAR edge of the target row's own extent, not its near edge
      // (see the file-level Dartdoc, _isReversed's Dartdoc, and
      // scroll_to_reverse_regression_test.dart's own expectedOffset helper
      // for the same `effectiveAlignment = 1.0 - alignment` term).
      final extent = rowHeights[targetIndex];
      const effectiveAlignment = 1.0 - 0.0;
      final alignmentAdjust = -(controller.position.viewportDimension - extent) * effectiveAlignment;
      final expectedPixels = priorItems + alignmentAdjust;
      expect(
        controller.position.pixels,
        closeTo(expectedPixels, 0.5),
        reason: 'the computed offset must reflect both rows\' growth via a genuine reflow from row 0 under reverse '
            'too -- reverse never inverts logical-index semantics, only the visual alignment adjustment at the '
            'very end',
      );
    },
  );

  testWidgets('scrollTo(20) after scrollTo(90) still converges when the only changed row (81) sits far above the target', (tester) async {
    // ISC-97 acceptance review, point 4: the regression the row-by-row
    // "stop at the last mismatch" walk this replaced was vulnerable to --
    // every changed row sits between the STARTING range and the target, but
    // none of them is anywhere near the target itself. A walk that exits the
    // moment the last mismatch (81) is resolved, without separately
    // confirming the target materialized, would stop around row 81 and never
    // reach row 20 at all.
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 20;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndex = 81;

    final rowHeights = List<double>.generate(itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

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
                        child: Text('Row $index'),
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

    await pumpUntilComplete(tester, controller.scrollTo(90, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[90]), isNotNull, reason: 'the experiment must begin around row 90');

    setOuterState(() {
      rowHeights[changedIndex] += 35.0;
      revisions[changedIndex]++;
    });

    final registrationsBeforeWalk = controller.registrationCountFor(changedIndex);

    await pumpUntilComplete(tester, controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    expect(
      controller.registrationCountFor(changedIndex),
      greaterThan(registrationsBeforeWalk),
      reason: 'row $changedIndex must still get a fresh layout on the way, even though it sits far above the target',
    );
    expect(controller.fingerprintFor(changedIndex), revisions[changedIndex]);
    // The materialization guarantee this scenario exists to prove: the walk
    // must not stop merely because the last mismatch (81) was resolved.
    expect(
      _sliverLayoutOffsetOf(rowKeys[targetIndex]),
      isNotNull,
      reason: 'target row 20 must be materialized -- the walk must not stop merely because the last mismatch (81) was resolved',
    );
    // ISC-98, now landed: flush with the viewport top, not merely live.
    expect(
      _onScreenDelta(listKey, rowKeys[targetIndex]),
      closeTo(0, 0.5),
      reason: 'scrollTo must put row $targetIndex at the viewport start',
    );
  });

  testWidgets('a single row far taller than one stride still converges without a numeric stride-count guard', (tester) async {
    // ISC-97 third acceptance round: the numeric hard guard tried in the
    // previous round (a bound derived from the corridor's index span) was
    // itself wrong, because a single row's own physical height is
    // unrelated to how many logical indices the corridor spans. Found by
    // the reviewer's widget probe, reproduced verbatim here as a permanent
    // regression: three rows [100, 10000, 100]; after the middle row grows
    // to 12000px (fingerprint bumped, so this is a genuinely dirty
    // corridor), a corridor of index-span 2 can still need far more than
    // `2 * constant` overlapping strides of `viewportDimension +
    // cacheExtent` to physically cross that one row, even though
    // position.pixels keeps moving closer to the target the whole time.
    const viewportHeight = 500.0;
    const targetIndex = 2;
    final rowHeights = [100.0, 10000.0, 100.0];
    final revisions = [0, 0, 0];
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
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
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: 3,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
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

    await pumpUntilComplete(tester, controller.scrollTo(2, duration: Duration.zero));
    await pumpUntilComplete(tester, controller.scrollTo(0, duration: Duration.zero));

    setOuterState(() {
      rowHeights[1] = 12000.0;
      revisions[1]++;
    });

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
      reason: 'the walk must converge on row 2 by crossing the overgrown row 1, not be rejected by a stride-count/index-span guard',
    );
  });

  testWidgets('itemCount shrinking below the snapshot corridorHiIndex during a suspended walk cancels with dataInvalidated', (tester) async {
    // ISC-97 second acceptance round, point 1: _hasOperationDataChanged must
    // treat a shrink that drops itemCount to or below the snapshot's
    // corridorHiIndex as a data change, even though the TARGET itself is
    // still perfectly valid. Before the fix, the check only compared
    // targetItemIndex against the live itemCount and then silently clamped
    // its fingerprint scan down to whatever survived -- so a shrink of the
    // corridor's upper (still in-flight) portion went unnoticed and the walk
    // kept going instead of cancelling.
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 20;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndex = 81;

    var itemCountValue = itemCount;
    final rowHeights = List<double>.generate(itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCountValue,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

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
                    itemCount: itemCountValue,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
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

    await pumpUntilComplete(tester, controller.scrollTo(90, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[90]), isNotNull, reason: 'the experiment must begin around row 90');

    // A mismatch far above the target (same shape as the previous test) so
    // the recovery walk takes multiple pumped steps instead of resolving on
    // its very first one -- there must be a genuine window, mid-walk, for
    // the shrink below to land inside.
    setOuterState(() {
      rowHeights[changedIndex] += 35.0;
      revisions[changedIndex]++;
    });

    final recovery = controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero);
    Object? error;
    var done = false;
    recovery.then(
      (_) {
        done = true;
      },
      onError: (Object e) {
        done = true;
        error = e;
      },
    );

    // Shrink itemCount to just above the (still-valid) target, dropping the
    // corridor's captured upper edge (90) out of range, while the walk is
    // still in flight -- the snapshot's fingerprints for indices 21..90
    // become unreadable, so the very next _checkOperationLive must cancel
    // rather than let the walk press on with a truncated comparison.
    itemCountValue = targetIndex + 1;
    setOuterState(() {});

    for (var i = 0; i < 300 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(done, isTrue, reason: 'scrollTo must not hang after the corridor shrink');
    expect(error, isA<ScrollCancelledException>());
    expect(
      (error as ScrollCancelledException).reason,
      ScrollCancelReason.dataInvalidated,
      reason: 'a shrink that drops itemCount to or below the snapshot corridorHiIndex must cancel as a data change, '
          'even though the target index itself is still valid',
    );
  });

  testWidgets('a long valid walk still converges even though maxScrollExtent starts far below the corridor\'s true extent', (tester) async {
    // ISC-97 second acceptance round, point 2: the guard budget must not be
    // derived from position.maxScrollExtent, because that estimate only
    // covers the rows built so far and keeps growing as the walk discovers
    // more of the list -- a budget computed from the LOW starting estimate
    // could exhaust itself well before a genuinely reachable mismatch, even
    // though the walk keeps making real progress the whole time (the
    // stall-guard would never fire). Constructed so the corridor spans many
    // more strides than the tiny initially-measured range's own
    // maxScrollExtent would suggest are needed: two widely separated
    // mismatches near opposite ends of a 300-row corridor, reached only
    // after scrolling back from deep in the list, mirroring the ISC-90
    // "zigzag" trial that first measured this cost (7 strides for two
    // far-apart mismatches on a 100-row corridor); this corridor is 3x
    // wider.
    const itemCount = 300;
    const viewportHeight = 500.0;
    const targetIndex = 299;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [16, 290];

    final rowHeights = List<double>.generate(itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

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
                        child: Text('Row $index'),
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

    // Only the first viewport's worth of rows is measured at this point, so
    // position.maxScrollExtent's estimate starts small -- exactly the
    // starting condition the old geometry-derived guard budget relied on.
    await pumpUntilComplete(tester, controller.scrollTo(299, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[299]), isNotNull, reason: 'the experiment must begin at the far end, with the whole list now measured once');

    await pumpUntilComplete(tester, controller.scrollTo(0, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    final registrationsBeforeWalk = <int, int>{for (final index in changedIndices) index: controller.registrationCountFor(index)};

    await pumpUntilComplete(tester, controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero), maxPumps: 600);

    for (final index in changedIndices) {
      expect(
        controller.registrationCountFor(index),
        greaterThan(registrationsBeforeWalk[index]!),
        reason: 'changed row $index must still get a fresh layout during the long walk',
      );
      expect(controller.fingerprintFor(index), revisions[index]);
    }
    expect(
      _sliverLayoutOffsetOf(rowKeys[targetIndex]),
      isNotNull,
      reason: 'the walk must converge on the far target despite maxScrollExtent starting out far below the corridor\'s true extent',
    );
  });

  testWidgets('clean corridor: scrollTo(50) after scrollTo(90) with no data changes takes no multi-step recovery walk', (tester) async {
    // The counterpart to the two tests above: when nothing in the corridor
    // changed, the fast (already-measured) path must be taken, not the
    // multi-step recovery walk -- ISC-97's acceptance criterion explicitly
    // calls for proving the ABSENCE of the extra walk on a clean corridor,
    // not merely the presence of one on a dirty corridor.
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 50;
    const initialHeights = [40.0, 50.0, 60.0];

    final rowHeights = List<double>.generate(itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: ListView.builder(
                key: listKey,
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(
                    key: rowKeyFor(index),
                    height: rowHeights[index],
                    child: Text('Row $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(tester, controller.scrollTo(90, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[90]), isNotNull);

    // Scroll back to a target already measured, already inside the
    // fingerprint-clean prefix. No fingerprint has changed, so the recovery
    // walk's per-step endOfFrame cost must not be paid -- one pump should be
    // enough for the whole operation on the Duration.zero fast path.
    var pumps = 0;
    var done = false;
    controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero).then((_) => done = true);
    while (!done && pumps < 10) {
      await tester.pump(const Duration(milliseconds: 16));
      pumps++;
    }
    expect(done, isTrue, reason: 'clean-corridor scrollTo must complete');
    expect(
      pumps,
      lessThanOrEqualTo(3),
      reason: 'a clean corridor to an already-measured, already-inside-the-prefix target must not pay the '
          'multi-step recovery walk\'s per-step frame cost -- got $pumps pumps',
    );
    expect(
      _onScreenDelta(listKey, rowKeys[targetIndex]),
      closeTo(0, 0.5),
      reason: 'scrollTo must put row 50 at the viewport start',
    );
  });
}

double? _sliverLayoutOffsetOf(GlobalKey? key) {
  final renderObject = key?.currentContext?.findRenderObject();
  if (renderObject == null || !renderObject.attached) return null;
  for (RenderObject? node = renderObject; node != null; node = node.parent) {
    final parentData = node.parentData;
    if (parentData is SliverMultiBoxAdaptorParentData) return parentData.layoutOffset;
  }
  return null;
}

double? _onScreenDelta(GlobalKey listKey, GlobalKey? rowKey) {
  final list = listKey.currentContext?.findRenderObject();
  final row = rowKey?.currentContext?.findRenderObject();
  if (list is! RenderBox || row is! RenderBox || !row.attached) return null;
  return row.localToGlobal(Offset.zero).dy - list.localToGlobal(Offset.zero).dy;
}
