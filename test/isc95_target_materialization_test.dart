import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-95: characterizes the ISC-94 defect with the boundary explicitly ruled
/// out, and measures the target row's materialization lifecycle during the
/// approach phase of `scrollTo`.
///
/// Every target below is chosen so neither the start nor the end of the
/// operation touches `minScrollExtent`/`maxScrollExtent` -- the reshuffle
/// tests (ISC-90) could not tell a stale-anchor bug apart from a clamp
/// because some of their random targets landed at the boundary. This file
/// keeps every trial in the interior of a 100-row list on purpose, so a
/// visible gap here can only be the sliver-anchor defect ISC-94 describes,
/// not physical clamping.
///
/// Production code is not touched by this file. The `layoutOffset` diagnostic
/// reads `SliverMultiBoxAdaptorParentData` directly off the row's render
/// object through its `GlobalKey` -- a public Flutter type, not a controller
/// internal -- exactly as `INVESTIGATION.md` did while designing ISC-96.
///
/// The first test below asserts `onScreenDelta` flush with the viewport top
/// (the actual public contract of `scrollTo(alignment: 0)`) -- green now that
/// ISC-96..ISC-98 landed the materialized-target fix. Its boundary exclusion
/// no longer requires `controller.offset == realSum`: ISC-98 deliberately
/// changed `scrollTo`'s final coordinate to come from the target row's own
/// live `layoutOffset` rather than a summed prefix, exactly so it can differ
/// from `realSum` in precisely the ISC-94 scenario (a reshuffled row the
/// sliver never revisited) while still landing the target flush on screen --
/// see `isc90_animated_reshuffle_test.dart`'s "computed offset always matches
/// the current row-height sum" test for that arithmetic-vs-visual distinction
/// made explicit. The only physical exclusion still needed here is room past
/// the target for a full viewport, which `maxScrollExtent` alone answers.
void main() {
  group('ISC-95: target materialization, interior targets only (no boundary)', () {
    /// The live scroll offset the sliver has actually assigned to [index]'s
    /// row, or `null` when that row is not currently laid out. Read straight
    /// off the render tree, independent of anything the controller computes.
    double? sliverLayoutOffsetOf(Map<int, GlobalKey> rowKeys, int index) {
      final renderObject = rowKeys[index]?.currentContext?.findRenderObject();
      if (renderObject == null || !renderObject.attached) return null;
      for (RenderObject? node = renderObject; node != null; node = node.parent) {
        final parentData = node.parentData;
        if (parentData is SliverMultiBoxAdaptorParentData) {
          return parentData.layoutOffset;
        }
      }
      return null;
    }

    /// The contiguous range of indices currently laid out (live) among
    /// [rowKeys], as `(lowest, highest)`, or `null` if none are live. Read
    /// the same way [sliverLayoutOffsetOf] reads a single row -- straight off
    /// the render tree via `SliverMultiBoxAdaptorParentData`, not from any
    /// controller-internal bookkeeping.
    (int, int)? liveRangeOf(Map<int, GlobalKey> rowKeys) {
      int? lowest;
      int? highest;
      for (final index in rowKeys.keys) {
        final renderObject = rowKeys[index]?.currentContext?.findRenderObject();
        if (renderObject == null || !renderObject.attached) continue;
        var isLive = false;
        for (RenderObject? node = renderObject; node != null; node = node.parent) {
          if (node.parentData is SliverMultiBoxAdaptorParentData) {
            isLive = true;
            break;
          }
        }
        if (!isLive) continue;
        if (lowest == null || index < lowest) lowest = index;
        if (highest == null || index > highest) highest = index;
      }
      if (lowest == null || highest == null) return null;
      return (lowest, highest);
    }

    testWidgets('reshuffle then animate to interior targets: target row is flush with the viewport top', (tester) async {
      const itemCount = 100;
      const heights = [20.0, 40.0, 60.0];
      const viewportHeight = 511.0;
      const duration = Duration(seconds: 1);
      final rowHeights = List<double>.generate(itemCount, (i) => heights[i % 3]);
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
            body: StatefulBuilder(
              builder: (context, setState) {
                setOuterState = setState;
                return SizedBox(
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
                        child: ColoredBox(
                          color: index.isEven ? const Color(0xFFBBDEFB) : const Color(0xFFFFE0B2),
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

      double? onScreenDelta(int index) {
        final lb = listKey.currentContext!.findRenderObject()! as RenderBox;
        final rb = rowKeys[index]?.currentContext?.findRenderObject() as RenderBox?;
        if (rb == null || !rb.attached) return null;
        return rb.localToGlobal(Offset.zero).dy - lb.localToGlobal(Offset.zero).dy;
      }

      // Fixed, hand-picked targets in the interior of the list -- never near
      // 0 or itemCount - 1, so neither minScrollExtent nor maxScrollExtent's
      // estimate can plausibly be reached. Reused verbatim across trials.
      const targets = [45, 22, 68, 30, 55];
      // Rows touched by the reshuffle before each target, also fixed and
      // also interior, so this file's result depends only on the mechanism
      // under test, not on a random seed's luck (ISC-90 depended on one).
      const touchedPerTrial = [
        [10, 15, 33, 41, 60],
        [8, 44, 50, 62, 71],
        [5, 20, 35, 58, 66],
        [12, 27, 39, 48, 53],
        [18, 25, 42, 57, 64],
      ];

      final results = <_TrialResult>[];

      for (var trial = 0; trial < targets.length; trial++) {
        final target = targets[trial];
        final touched = touchedPerTrial[trial];
        setOuterState(() {
          for (final i in touched) {
            final others = heights.where((h) => h != rowHeights[i]).toList();
            rowHeights[i] = others[(i + trial) % others.length];
            revisions[i]++;
          }
        });

        var done = false;
        Object? err;
        controller.scrollTo(target.toDouble(), duration: duration, alignment: 0.0).then(
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

        final realSum = rowHeights.take(target).fold<double>(0, (a, b) => a + b);
        // Excluding the boundary honestly: every target here is chosen deep
        // in the interior (see the file-level Dartdoc), but a trial's own
        // reshuffle could in principle still push maxScrollExtent's estimate
        // down far enough to clamp. `realSum` needing room for a full
        // viewport past it is the only exclusion still meaningful post-ISC-98
        // -- `controller.offset == realSum` is deliberately NOT required
        // anymore (see the file-level Dartdoc): the target's own live
        // `layoutOffset` is now the source of truth for where `scrollTo`
        // lands, and it can legitimately differ from the prefix sum while
        // still being the visually correct, flush position.
        final ruledOutBoundary = realSum + viewportHeight <= controller.position.maxScrollExtent;

        results.add(
          _TrialResult(
            trial: trial,
            target: target,
            err: err,
            offset: controller.offset,
            realSum: realSum,
            layoutOffset: sliverLayoutOffsetOf(rowKeys, target),
            onScreenDelta: onScreenDelta(target),
            ruledOutBoundary: ruledOutBoundary,
          ),
        );
      }

      for (final r in results) {
        expect(r.err, isNull, reason: 'trial ${r.trial} (target ${r.target}): scrollTo must not throw');
        expect(
          r.ruledOutBoundary,
          isTrue,
          reason: 'trial ${r.trial} (target ${r.target}): offset=${r.offset} realSum=${r.realSum} -- '
              'either the computed offset does not equal the true prefix sum (arithmetic regressed) or '
              'there was not a full viewport of room past the target (this trial cannot rule out the '
              'physical boundary, and must not be used as evidence either way -- pick a different target)',
        );
      }

      // The actual public contract: scrollTo(alignment: 0) must place the
      // target row flush with the viewport top. This is RED on current
      // HEAD -- ISC-94/ISC-95 exist because it is not true yet when the
      // sliver's retained geometry has fallen behind the measured cache.
      // It is expected to turn green only once ISC-96..ISC-98 land the
      // materialized-target fix; until then this failure IS the
      // characterization, not a false alarm to silence.
      for (final r in results) {
        expect(
          r.onScreenDelta,
          isNotNull,
          reason: 'trial ${r.trial} (target ${r.target}): target row must be mounted',
        );
        // The public contract ISC-98 exists to deliver: scrollTo(alignment:
        // 0) places the target row flush with the viewport top, even after a
        // reshuffle the sliver never travelled back over (the ISC-94
        // scenario) -- because the final coordinate now comes from the
        // target's own live layoutOffset, not a prefix sum that can disagree
        // with what the sliver actually painted. realSum/layoutOffset are
        // still recorded in the failure message for diagnosis if this ever
        // regresses.
        expect(
          r.onScreenDelta,
          closeTo(0, 0.5),
          reason: 'trial ${r.trial} (target ${r.target}): target row must sit flush with the viewport top -- '
              'realSum=${r.realSum} layoutOffset=${r.layoutOffset} onScreenDelta=${r.onScreenDelta}',
        );
      }
    });

    testWidgets('materialization lifecycle: layoutOffset is read at every phase of one scrollTo', (tester) async {
      const itemCount = 100;
      const heights = [20.0, 40.0, 60.0];
      const viewportHeight = 511.0;
      const duration = Duration(seconds: 1);
      const target = 62; // interior: far enough from both 0 and 99 to need a real search.
      final rowHeights = List<double>.generate(itemCount, (i) => heights[i % 3]);
      final revisions = List<int>.filled(itemCount, 0);

      final controller = IndexedScrollController(
        scrollDuration: duration,
        itemCount: () => itemCount,
        contentFingerprint: (index) => revisions[index],
      );
      addTearDown(controller.dispose);

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
                  height: viewportHeight,
                  child: ListView.builder(
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
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Reshuffle rows below the target, same mechanism as the first test,
      // so this call's approach phase is the one that hits the recovery
      // path (_alignGeometryWithCache) rather than a clean search.
      const touched = [8, 19, 33, 47];
      setOuterState(() {
        for (final i in touched) {
          final others = heights.where((h) => h != rowHeights[i]).toList();
          rowHeights[i] = others[i % others.length];
          revisions[i]++;
        }
      });
      await tester.pump(const Duration(milliseconds: 16));

      // Per-pump observations, purely READ-ONLY -- no extra jumpTo/scrollTo
      // is issued between measurements, per the methodical warning in
      // todo.md ("diagnostic that moves the position corrupts its own
      // measurement"). Each sample records the phase this pump belongs to
      // (approach vs. final animation) so the lifecycle can be reasoned
      // about per-phase, not just as an undifferentiated pump count.
      final samples = <_LifecycleSample>[];

      // The "before approach" baseline the review asked for: a sample taken
      // before scrollTo is ever called, so "materialized during approach"
      // below is judged against a real starting state, not merely inferred
      // from the first pump inside the loop.
      samples.add(
        _LifecycleSample(
          pumpIndex: -1,
          layoutOffset: sliverLayoutOffsetOf(rowKeys, target),
          positionPixels: controller.position.pixels,
          liveRange: liveRangeOf(rowKeys),
          wasJumpTo: false,
          jumpNumber: 0,
          isAfterZeroPump: false,
          isPreFinalAnimation: false,
          isFinalLeg: false,
        ),
      );

      var done = false;
      Object? err;
      controller.scrollTo(target.toDouble(), duration: duration, alignment: 0.0).then(
        (_) => done = true,
        onError: (Object e) {
          done = true;
          err = e;
        },
      );

      // Exact jumpTo detection, not a distance threshold: position.jumpTo
      // (used by every approach step -- the search loop, the geometry-align
      // walk, and the "get within one viewport" approach jump, all in
      // _runAnimateTo) writes position.pixels synchronously, so it is
      // already reflected after a Duration.zero pump that advances no
      // animation clock. position.animateTo's driven animation, in
      // contrast, only advances pixels across a pump that lets real time
      // pass. Reading pixels before and after a Duration.zero pump -- inside
      // the SAME iteration, before the 16ms pump that actually lets the
      // frame/animation run -- isolates exactly the synchronous jumpTo
      // contribution for that iteration from any animation contribution,
      // with no threshold to tune or get wrong on a small jumpTo. Verified
      // empirically (see the review response in todo.md): early pumps show
      // jumpDetected=true (approach's jumpTo steps, largest one full
      // viewportHeight=511px), every later pump shows jumpDetected=false
      // with a small, constant per-pump delta (the final animateTo leg).
      var jumpCount = 0;
      var sawPreFinalAnimation = false;

      for (var i = 0; i < 600 && !done; i++) {
        final beforeZeroPump = controller.position.pixels;
        await tester.pump(Duration.zero);
        final afterZeroPump = controller.position.pixels;
        final jumpDetected = (afterZeroPump - beforeZeroPump).abs() > 0.001;
        if (jumpDetected) jumpCount++;

        // This is a distinct lifecycle point: animateTo may now be scheduled,
        // but its first 16ms tick has not run yet. Recording it explicitly
        // fixes the otherwise missing "before final animation" observation.
        final isPreFinalAnimation = !sawPreFinalAnimation && jumpCount > 0 && !jumpDetected;
        if (isPreFinalAnimation) sawPreFinalAnimation = true;
        samples.add(
          _LifecycleSample(
            pumpIndex: i,
            layoutOffset: sliverLayoutOffsetOf(rowKeys, target),
            positionPixels: afterZeroPump,
            liveRange: liveRangeOf(rowKeys),
            wasJumpTo: jumpDetected,
            jumpNumber: jumpCount,
            isAfterZeroPump: true,
            isPreFinalAnimation: isPreFinalAnimation,
            isFinalLeg: sawPreFinalAnimation && !isPreFinalAnimation,
          ),
        );

        await tester.pump(const Duration(milliseconds: 16));
        final live = sliverLayoutOffsetOf(rowKeys, target);
        final pixelsNow = controller.position.pixels;

        samples.add(
          _LifecycleSample(
            pumpIndex: i,
            layoutOffset: live,
            positionPixels: pixelsNow,
            liveRange: liveRangeOf(rowKeys),
            wasJumpTo: jumpDetected,
            jumpNumber: jumpCount,
            isAfterZeroPump: false,
            isPreFinalAnimation: false,
            isFinalLeg: sawPreFinalAnimation,
          ),
        );
      }
      await tester.pump(const Duration(milliseconds: 16));

      expect(err, isNull, reason: 'scrollTo must not throw');
      expect(done, isTrue, reason: 'scrollTo must complete within the guard budget');

      // Baseline, before scrollTo was ever called: the review asked for this
      // state to actually be captured, not left implicit.
      final beforeApproach = samples.first;
      expect(
        beforeApproach.pumpIndex,
        -1,
        reason: 'the first sample must be the pre-scrollTo baseline',
      );

      final pumpedSamples = samples.where((s) => s.pumpIndex >= 0).toList();
      final liveSamples = pumpedSamples.where((s) => s.layoutOffset != null).toList();
      expect(
        liveSamples,
        isNotEmpty,
        reason: 'target row must materialize (enter the live render tree) at some '
            'point before the operation completes -- if this is empty, ISC-88 regressed',
      );

      final approachSamples = pumpedSamples.where((s) => !s.isPreFinalAnimation && !s.isFinalLeg).toList();
      final finalLegSamples = pumpedSamples.where((s) => s.isFinalLeg).toList();
      final preFinalSamples = pumpedSamples.where((s) => s.isPreFinalAnimation).toList();

      // The laid-out range boundary the review asked for: which phase the
      // target first became live in, stated explicitly rather than left as
      // a bare pump index.
      expect(
        finalLegSamples,
        isNotEmpty,
        reason: 'the observation window must include at least one final-leg pump, or the phase split '
            'above could not distinguish approach from the final animation',
      );
      expect(
        preFinalSamples,
        hasLength(1),
        reason: 'there must be exactly one zero-pump sample after the last approach jump and before the first '
            '16ms animateTo tick',
      );

      final liveDuringApproach = approachSamples.where((s) => s.layoutOffset != null).toList();
      final firstLiveDuringApproach = liveDuringApproach.isEmpty ? null : liveDuringApproach.first;
      // This is the assertion the previous version only printed: the target
      // must actually become live WHILE the approach phase is still running,
      // not for the first time once the final leg has already started. If it
      // materialized only during the final leg, ISC-96's "materialize before
      // sampling the coordinate" plan has nothing to sample from during
      // approach, and the whole design premise needs re-checking, not a
      // silently green test.
      expect(
        firstLiveDuringApproach,
        isNotNull,
        reason: 'target row must materialize during the APPROACH phase, before the final animation leg starts -- '
            'firstLive was ${liveSamples.first.pumpIndex >= 0 ? "pump ${liveSamples.first.pumpIndex}" : "the pre-approach baseline"}, '
            'finalLegSamples start at pump ${finalLegSamples.first.pumpIndex}; a target that only ever '
            'materializes once the final leg has already begun cannot be sampled beforehand the way ISC-96 plans to',
      );
      final firstLive = firstLiveDuringApproach!;
      final preFinalAnimation = preFinalSamples.single;
      final firstFinalLeg = finalLegSamples.first;

      expect(firstLive.jumpNumber, greaterThan(0), reason: 'the target must first materialize after a numbered approach jump');
      expect(preFinalAnimation.isAfterZeroPump, isTrue);
      expect(preFinalAnimation.wasJumpTo, isFalse);

      // ignore: avoid_print
      print(
        'target=$target beforeApproachLive=${beforeApproach.layoutOffset != null} beforeApproachLiveRange=${beforeApproach.liveRange} '
        'firstLiveAfterJump=${firstLive.jumpNumber} firstLivePump=${firstLive.pumpIndex} firstLiveRange=${firstLive.liveRange} '
        'preFinalAfterJump=${preFinalAnimation.jumpNumber} preFinalPump=${preFinalAnimation.pumpIndex} '
        'preFinalRange=${preFinalAnimation.liveRange} '
        'firstFinalLegPump=${firstFinalLeg.pumpIndex} firstFinalLegRange=${firstFinalLeg.liveRange} '
        'approachPumpCount=${approachSamples.length} finalLegPumpCount=${finalLegSamples.length} '
        'finalOffset=${controller.offset} finalLayoutOffset=${sliverLayoutOffsetOf(rowKeys, target)}',
      );

      // ISC-97 (third architect decision, todo.md): the binding contract is
      // only "the target is materialized on the LAST completed layout frame
      // before the coordinate is read and the final leg starts" -- this is
      // exactly preFinalAnimation, the sample taken after the last approach
      // jump and before the first animateTo tick. Everything this test
      // asserted about jumpNumber equality with firstLive, live-range
      // stability from firstLive through preFinal, continuous materialization
      // across that whole window, and a single stable layoutOffset across it
      // was this test's own exploratory lifecycle assertion, not part of the
      // ISC-96 contract -- and a later architect decision confirmed that
      // ISC-97's restoration jump (moving the position back toward legStart
      // for a proper, non-degenerate final leg) is explicitly allowed to
      // revisit different rows than the ones first materialization saw,
      // exactly the kind of range change this test used to forbid. The
      // now-corrected assertion below is the one that actually matters: the
      // row is live, right here, right before the leg that uses its
      // geometry -- read live layoutOffset itself is production's job
      // (ISC-98), not this file's, so this only proves materialization, not
      // the sampled value.
      expect(
        preFinalAnimation.layoutOffset,
        isNotNull,
        reason: 'the target row must be materialized on the last completed layout frame before the final leg -- '
            'preFinalPump=${preFinalAnimation.pumpIndex} preFinalRange=${preFinalAnimation.liveRange}; a null '
            'layoutOffset here means the contractual materialization guarantee (ISC-96 point 4) was not honored '
            'at the one point that actually matters: immediately before the coordinate is read and the final leg '
            'starts',
      );
    });
  });
}

class _TrialResult {
  final int trial;
  final int target;
  final Object? err;
  final double offset;
  final double realSum;

  /// The target row's own `layoutOffset`, read straight from
  /// `SliverMultiBoxAdaptorParentData` right after `scrollTo` settles -- the
  /// third number ISC-95's acceptance criterion asks to be recorded
  /// alongside `realSum`/`onScreenDelta`, per trial.
  final double? layoutOffset;
  final double? onScreenDelta;
  final bool ruledOutBoundary;

  _TrialResult({
    required this.trial,
    required this.target,
    required this.err,
    required this.offset,
    required this.realSum,
    required this.layoutOffset,
    required this.onScreenDelta,
    required this.ruledOutBoundary,
  });
}

class _LifecycleSample {
  /// Pump index within the observation loop, or `-1` for the one sample
  /// taken before `scrollTo` was ever called -- the "before approach"
  /// baseline the review asked for.
  final int pumpIndex;
  final double? layoutOffset;
  final double positionPixels;
  final (int, int)? liveRange;

  /// Whether this pump's own `Duration.zero` sub-pump (taken before the real
  /// 16ms pump) already showed `position.pixels` move -- the exact,
  /// threshold-free signal that `_runAnimateTo`'s approach phase issued a
  /// synchronous `jumpTo` this iteration, as opposed to `animateTo`'s driven
  /// animation, which only advances across a pump that lets time pass.
  final bool wasJumpTo;
  final int jumpNumber;

  /// Distinguishes the sample immediately after `pump(Duration.zero)` from
  /// the sample after the following 16ms animation frame of the same loop.
  final bool isAfterZeroPump;

  /// The one zero-pump sample after the final approach jump and before the
  /// first animation tick.
  final bool isPreFinalAnimation;
  final bool isFinalLeg;

  _LifecycleSample({
    required this.pumpIndex,
    required this.layoutOffset,
    required this.positionPixels,
    required this.liveRange,
    required this.wasJumpTo,
    required this.jumpNumber,
    required this.isAfterZeroPump,
    required this.isPreFinalAnimation,
    required this.isFinalLeg,
  });
}
