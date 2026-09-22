import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-90: regression tests converted from the `isc_animated_reshuffle_test`
/// diagnostic stand -- the example app's real scenario, a 1-second ANIMATED
/// `scrollTo`, several in a row, each preceded by reshuffling a handful of
/// rows.
///
/// Split in two, per the trial data the diagnostic stand actually collected
/// (see ISC-90 in todo.md): the two concerns get separate, honestly-bounded
/// assertions instead of one that conflates them.
///
/// ISC-98 changed what the first ("arithmetic") test asserts. Before it, the
/// controller always computed `scrollTo`'s final coordinate as a prefix sum
/// over `_sizes`, so `controller.offset == realSum` (the true post-reshuffle
/// row-height sum) was the right invariant -- a residual visible gap
/// (ISC-94) was then a separate, sliver-paint-only defect the offset
/// computation itself did not cause. ISC-98 deliberately replaced that
/// prefix-sum source with the target row's own live `layoutOffset`, exactly
/// so the visual gap closes; the new, honest arithmetic invariant is that
/// `controller.offset` matches THAT live layoutOffset (translated into
/// scrollable-space coordinates), not the summed prefix, which the two can
/// now legitimately disagree with in precisely the reshuffled-row scenario
/// this file exercises.
void main() {
  /// The live scroll offset the sliver has assigned to [index]'s row, read
  /// straight off `SliverMultiBoxAdaptorParentData` via its `GlobalKey` --
  /// the same technique `isc95_target_materialization_test.dart` and
  /// `isc96_contiguous_viewport_walk_probe_test.dart` use, independent of
  /// anything the controller computes.
  double? sliverLayoutOffsetOf(GlobalKey? key) {
    final renderObject = key?.currentContext?.findRenderObject();
    if (renderObject == null || !renderObject.attached) return null;
    for (RenderObject? node = renderObject; node != null; node = node.parent) {
      final parentData = node.parentData;
      if (parentData is SliverMultiBoxAdaptorParentData) {
        return parentData.layoutOffset;
      }
    }
    return null;
  }

  /// Runs the reshuffle-then-animate loop and returns, for every trial, the
  /// data both tests below check against.
  Future<List<_TrialResult>> runTrials(WidgetTester tester) async {
    const itemCount = 100;
    const heights = [20.0, 40.0, 60.0];
    const duration = Duration(seconds: 1);
    final rowHeights = List<double>.generate(itemCount, (i) => heights[i % 3]);
    final revisions = List<int>.filled(itemCount, 0);

    // The automatic fingerprint mode, matching the example app: a reshuffle
    // bumps the row's revision, so scrollTo notices it and runs the recovery
    // pass. That pass is what these tests exercise.
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
          body: StatefulBuilder(
            builder: (context, setState) {
              setOuterState = setState;
              return SizedBox(
                height: 511,
                child: ListView.builder(
                  key: listKey,
                  controller: controller,
                  itemCount: itemCount,
                  itemBuilder: (context, index) => controller.watch(
                    index: index,
                    child: SizedBox(
                      key: rowKeyFor(index),
                      height: rowHeights[index],
                      child: ColoredBox(
                        color: index.isEven
                            ? const Color(0xFFBBDEFB)
                            : const Color(0xFFFFE0B2),
                        child: Center(child: Text('Row $index')),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    var seed = 11;
    int nextRandom(int max) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % max;
    }

    final results = <_TrialResult>[];

    for (var trial = 0; trial < 12; trial++) {
      final target = nextRandom(itemCount);
      final touched = <int>{};
      while (touched.length < 5) {
        touched.add(nextRandom(itemCount));
      }
      var totalTouchedDelta = 0.0;
      setOuterState(() {
        for (final i in touched) {
          final others = heights.where((h) => h != rowHeights[i]).toList();
          final was = rowHeights[i];
          rowHeights[i] = others[nextRandom(others.length)];
          totalTouchedDelta += (rowHeights[i] - was).abs();
          revisions[i]++;
        }
      });

      var done = false;
      Object? err;
      controller
          .scrollTo(target.toDouble(), duration: duration, alignment: 0.0)
          .then(
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

      final listBox = listKey.currentContext!.findRenderObject()! as RenderBox;
      final listTop = listBox.localToGlobal(Offset.zero).dy;
      final rowBox =
          rowKeys[target]?.currentContext?.findRenderObject() as RenderBox?;
      final rowTop = rowBox?.localToGlobal(Offset.zero).dy;
      final onScreenDelta = rowTop == null ? null : rowTop - listTop;
      final layoutOffset = sliverLayoutOffsetOf(rowKeys[target]);

      final realSum = rowHeights.take(target).fold<double>(0, (a, b) => a + b);
      // A clamp against maxScrollExtent's own estimate (see the SDK notes in
      // todo.md: it is an extrapolation, not the true content length) can
      // legitimately keep the offset below realSum with nothing wrong in the
      // controller's own arithmetic -- Flutter refuses to scroll past its
      // estimate, and the controller cannot force it to. Both assertions
      // below are scoped to "not clamped" for exactly that reason.
      //
      // `offset == maxScrollExtent` alone is not a reliable clamp signal:
      // near the LAST index, `alignment: 0.0` asks for a targetPixels below
      // maxScrollExtent by design (the row does not need to be pushed past
      // the viewport's own trailing edge), so a genuinely clamped call can
      // still land well short of maxScrollExtent -- measured on trial 5,
      // target 99: offset=3285.30, maxScrollExtent=3469, neither close to
      // the other, yet realSum=4020 was never reachable at all. The
      // reliable signal is realSum itself exceeding the estimate: whenever
      // that holds, _clampToBounds necessarily cut the requested
      // targetPixels short regardless of where alignment placed it.
      final atMax = realSum > controller.position.maxScrollExtent;

      results.add(
        _TrialResult(
          trial: trial,
          target: target,
          err: err,
          offset: controller.offset,
          realSum: realSum,
          layoutOffset: layoutOffset,
          onScreenDelta: onScreenDelta,
          totalTouchedDelta: totalTouchedDelta,
          atMax: atMax,
        ),
      );
    }

    return results;
  }

  testWidgets(
      'animated scrollTo + reshuffle: computed offset always matches the target row\'s live layoutOffset',
      (tester) async {
    final results = await runTrials(tester);

    for (final r in results) {
      expect(r.err, isNull,
          reason:
              'trial ${r.trial} (target ${r.target}): scrollTo must not throw');
      if (r.atMax) continue;
      expect(
        r.layoutOffset,
        isNotNull,
        reason:
            'trial ${r.trial} (target ${r.target}): target row must be materialized once scrollTo completes',
      );
      // ISC-98: controller.offset is now derived from the target row's own
      // live layoutOffset, not a summed prefix -- see the file-level
      // Dartdoc. This can legitimately diverge from realSum in exactly the
      // reshuffled-row scenario this file exercises (ISC-94); what must
      // hold is that the controller's own coordinate agrees with what the
      // sliver actually painted the target at.
      expect(
        r.offset,
        closeTo(r.layoutOffset!, 0.5),
        reason:
            'trial ${r.trial} (target ${r.target}): the computed offset must equal the target row\'s own '
            'live layoutOffset (${r.layoutOffset}), not necessarily the prefix sum (realSum=${r.realSum})',
      );
    }
  });

  testWidgets(
      'animated scrollTo + reshuffle: target row settles flush with the viewport top',
      (tester) async {
    final results = await runTrials(tester);

    for (final r in results) {
      expect(
        r.onScreenDelta,
        isNotNull,
        reason:
            'trial ${r.trial} (target ${r.target}): target row must be mounted after scrollTo',
      );
      // A trial clamped against maxScrollExtent's own estimate is not
      // expected to land flush -- see the arithmetic test's note on atMax.
      if (r.atMax) continue;
      // ISC-98 closes the ISC-94 gap: the target's own live layoutOffset is
      // now the coordinate scrollTo lands on, so the row is flush with the
      // viewport top exactly, not merely within a reshuffle-sized residual.
      expect(
        r.onScreenDelta!,
        closeTo(0, 0.5),
        reason:
            'trial ${r.trial} (target ${r.target}): target row must sit flush with the viewport top',
      );
    }
  });
}

class _TrialResult {
  final int trial;
  final int target;
  final Object? err;
  final double offset;
  final double realSum;

  /// The target row's own live `layoutOffset`, read straight from
  /// `SliverMultiBoxAdaptorParentData`. This harness has no preceding sliver
  /// (a bare `ListView.builder`), so this coincides with `controller.offset`
  /// in scrollable-space coordinates -- unlike a `CustomScrollView` with a
  /// preceding sliver, where the two would differ by `precedingScrollExtent`
  /// (see `scroll_to_preceding_sliver_test.dart`).
  final double? layoutOffset;
  final double? onScreenDelta;
  final double totalTouchedDelta;
  final bool atMax;

  _TrialResult({
    required this.trial,
    required this.target,
    required this.err,
    required this.offset,
    required this.realSum,
    required this.layoutOffset,
    required this.onScreenDelta,
    required this.totalTouchedDelta,
    required this.atMax,
  });
}
