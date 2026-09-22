// ISC-82d: Locks down the two-mode time contract decided for ISC-82.
//
// Mode A (measured path, data unchanged): duration is honored tightly,
// within a small, frame-quantized margin, REGARDLESS of list size -- a
// fully-measured 1000-row list must not cost more than a fully-measured
// 100-row list. Before ISC-82a, an already-measured target more than one
// viewport away from the current position paid duration TWICE (the "jump
// closer" approach step animated too), so this file also guards that
// regression directly.
//
// Mode B (unmeasured path): time = (build frames) + duration, where build
// frames grow linearly with distance and are bounded by
// ceil(distance / step). This is the legitimate, bounded deviation ISC-82
// allows -- this file's job is to prove it stays bounded, not to celebrate
// that it exists.
//
// Model time (not pump count) is the right instrument for Mode A: a test
// that only counted pump() calls would pass as long as SOME number of
// frames elapsed, without checking that the elapsed model time actually
// matches `duration`. Each pump advances model time by the Duration passed
// to it, and tester.binding.clock.now() reads that same clock -- summing
// what's passed to pump() and cross-checking against the clock is how this
// file verifies "duration was honored", not merely "frames were pumped".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

Widget _list({
  required IndexedScrollController controller,
  required int itemCount,
  required double rowHeight,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ListView.builder(
      controller: controller,
      itemCount: itemCount,
      itemBuilder: (context, index) {
        return controller.watch(
          index: index,
          child: SizedBox(height: rowHeight, child: Text('Item $index')),
        );
      },
    ),
  );
}

Future<void> _pumpAtSurfaceSize(WidgetTester tester, Widget widget, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MediaQuery(data: MediaQueryData(size: size), child: widget));
}

/// Whether [actual] falls within a small, frame-quantized margin above
/// [expected] -- scrollTo() completing sooner than `expected` is never the
/// contract violation being tested for here, only completing later is.
///
/// The margin is 5 frame strides (80ms at the default 16ms stride), not 1:
/// measured directly (a plain scrollTo() with no search phase at all,
/// 300ms duration, 16ms pump stride) settles at 336ms = 21 pumped frames,
/// i.e. duration + 2.25 strides, not duration + 1. This is
/// AnimationController's own frame-quantized completion, independent of
/// anything ISC-82a touches -- the ticker only observes "animation ended"
/// on the frame after the tween crosses `duration`, and completing the
/// scrollTo() future takes one more pumped frame after that. A 1- or
/// 2-frame margin fails on this measured, correct floor.
///
/// ISC-97 widened this from 3 to 5 strides, architect-approved: a target
/// more than one viewport away that is also further than one cache extent
/// from the one-viewport approach jump's landing spot (ordinary geometry --
/// e.g. a 600px viewport with the SDK's 250px default cache extent: jumping
/// to within 600px of the target does not by itself bring it inside a 250px
/// cache extent of the NEW position) needs one additional bounded local step
/// to confirm the target materialized before the single final animateTo can
/// start (see IndexedScrollController's ISC-97 corridor-walk Dartdoc). That
/// step costs one more pumped frame ON TOP OF the approach jump that already
/// existed pre-ISC-97 (so two approach frames total instead of one) plus the
/// AnimationController quantization above -- measured directly at 368ms =
/// duration + 4.25 strides, both for the 100-row and the 1000-row Mode A
/// case (so list size still does not matter, confirming the extra frame is
/// the fixed one-time materialization check, not a per-size cost). 4 strides
/// (64ms) undershoots this measured floor by 4ms; 5 covers it with the same
/// kind of small headroom the original 3-strides comment used for the
/// pre-ISC-97 floor. This is not the search/corridor walk spending
/// `duration` -- Mode A's guarantee that the walk itself is not what
/// `duration` measures still holds -- it is a single confirmation frame the
/// materialization guarantee (ISC-96 point 4) requires before the animated
/// leg may start.
bool _withinFrameQuantizedMargin(Duration actual, Duration expected, {Duration frameStride = const Duration(milliseconds: 16)}) {
  return actual >= expected && actual <= expected + frameStride * 5;
}

/// Pumps 16ms frames until [future] completes or [maxPumps] is exhausted,
/// returning the model time elapsed (sum of pumped durations) and the
/// number of frames pumped.
///
/// Model time is what actually answers "was duration honored" -- a fixed
/// 16ms-per-frame stride means frame count and model time move together
/// here, but the test asserts on the clock-derived model time, not on
/// frame count, so it stays correct if the stride ever changes.
Future<({Duration modelTime, int frames})> _pumpUntilComplete(
  WidgetTester tester,
  Future<void> future, {
  int maxPumps = 2000,
  Duration frameStride = const Duration(milliseconds: 16),
}) async {
  var settled = false;
  future.then((_) => settled = true, onError: (_) => settled = true);

  final start = tester.binding.clock.now();
  var frames = 0;
  while (!settled && frames < maxPumps) {
    await tester.pump(frameStride);
    frames++;
  }
  final elapsed = tester.binding.clock.now().difference(start);

  expect(settled, isTrue, reason: 'scrollTo() did not complete within $maxPumps pumps');
  await future;
  return (modelTime: elapsed, frames: frames);
}

void main() {
  group('ISC-82d: Mode A (measured path) -- duration honored within a small margin, any list size', () {
    for (final itemCount in [100, 1000]) {
      testWidgets('scrollTo on a fully-measured $itemCount-row list completes within a frame-quantized margin of duration', (tester) async {
        const rowHeight = 20.0;
        const duration = Duration(milliseconds: 300);

        final controller = IndexedScrollController(scrollDuration: duration);
        addTearDown(controller.dispose);

        await _pumpAtSurfaceSize(
          tester,
          _list(controller: controller, itemCount: itemCount, rowHeight: rowHeight),
          const Size(400.0, 600.0),
        );
        await tester.pump();

        // Force full measurement of the whole list first (Mode B), then
        // discard that timing entirely -- only the SECOND, now-measured
        // call is what this scenario is about. A zero-duration scrollTo
        // still needs pumping alongside it (its search loop awaits
        // WidgetsBinding.instance.endOfFrame internally); a bare `await`
        // with no interleaved pump() never resolves.
        await _pumpUntilComplete(tester, controller.scrollTo((itemCount - 1).toDouble(), duration: Duration.zero));
        expect(controller.measurementsSizes.length, itemCount, reason: 'Setup must fully measure the list before the timed call');

        // Now scroll back to a target far from the current position (near
        // the start), on a list where every row's size is already known.
        // This is Mode A: no build frames should be needed at all.
        final result = await _pumpUntilComplete(
          tester,
          controller.scrollTo(0.0, duration: duration),
        );

        expect(
          _withinFrameQuantizedMargin(result.modelTime, duration),
          isTrue,
          reason: 'On a fully-measured $itemCount-row list, scrollTo must complete within a '
              'small, frame-quantized margin of the requested $duration -- got '
              '${result.modelTime} (${result.frames} frames). List size must not matter here: '
              'nothing needs building, only the final animateTo runs.',
        );
      });
    }

    testWidgets('the two list sizes above cost the same model time (this is what "any size" means)', (tester) async {
      // Re-derives both durations independently so this test does not
      // depend on execution order of the parameterized group above, then
      // asserts they match -- the loop above only proves each one
      // individually stays close to `duration`; this is the direct
      // same-size-doesn't-matter comparison the decision calls for.
      const rowHeight = 20.0;
      const duration = Duration(milliseconds: 300);

      Future<Duration> measuredModeATime(int itemCount) async {
        final controller = IndexedScrollController(scrollDuration: duration);
        addTearDown(controller.dispose);

        await _pumpAtSurfaceSize(
          tester,
          _list(controller: controller, itemCount: itemCount, rowHeight: rowHeight),
          const Size(400.0, 600.0),
        );
        await tester.pump();

        await _pumpUntilComplete(tester, controller.scrollTo((itemCount - 1).toDouble(), duration: Duration.zero));

        final result = await _pumpUntilComplete(tester, controller.scrollTo(0.0, duration: duration));
        return result.modelTime;
      }

      final time100 = await measuredModeATime(100);
      final time1000 = await measuredModeATime(1000);

      expect(
        (time1000 - time100).abs(),
        lessThanOrEqualTo(const Duration(milliseconds: 16)),
        reason: 'A fully-measured 100-row list and a fully-measured 1000-row list must cost the '
            'same model time ($time100 vs $time1000) -- Mode A\'s guarantee is "any size", not '
            '"small enough sizes"',
      );
    });

    testWidgets('scrolling back to a far, already-measured target does not double duration', (tester) async {
      // Regresses the exact defect ISC-82a fixed: before it, the
      // "jumpingPosition" approach step (getting within one viewport of an
      // already-known target) animated with the full duration whenever the
      // remaining distance exceeded one viewport, silently doubling the
      // wait to 2x duration for this scenario specifically. A short list
      // with a large per-row height keeps the total scroll extent well
      // over one viewport while the whole list is trivially fully
      // measured.
      const rowHeight = 400.0;
      const itemCount = 20;
      const duration = Duration(milliseconds: 300);

      final controller = IndexedScrollController(scrollDuration: duration);
      addTearDown(controller.dispose);

      await _pumpAtSurfaceSize(
        tester,
        _list(controller: controller, itemCount: itemCount, rowHeight: rowHeight),
        const Size(400.0, 600.0),
      );
      await tester.pump();

      // Scroll to the end first (Mode B, discarded), fully measuring the
      // list and leaving the position far from 0.
      await _pumpUntilComplete(tester, controller.scrollTo((itemCount - 1).toDouble(), duration: Duration.zero));
      expect(controller.measurementsSizes.length, itemCount);
      expect(controller.position.pixels, greaterThan(600.0 * 2),
          reason: 'Setup must land far enough from 0 that the return trip exceeds one viewport');

      // Scroll back to 0 -- a fully-measured target, more than one
      // viewport away. Mode A's tight guarantee applies here exactly as it
      // does to the forward case above.
      final result = await _pumpUntilComplete(
        tester,
        controller.scrollTo(0.0, duration: duration),
      );

      expect(
        _withinFrameQuantizedMargin(result.modelTime, duration),
        isTrue,
        reason: 'A backward scrollTo() to an already-measured target more than one viewport '
            'away must still cost only ~$duration, not 2x it -- got ${result.modelTime} '
            '(${result.frames} frames)',
      );
    });
  });

  group('ISC-82d: Mode B (unmeasured path) -- bounded, honest deviation', () {
    testWidgets('search frames stay within ceil(distance / step) of the theoretical bound, and the offset matches Mode A', (tester) async {
      const rowHeight = 20.0;
      const viewportHeight = 600.0;
      const itemCount = 2000;
      const targetIndex = 1500;
      const duration = Duration(milliseconds: 300);

      // Reference offset: what a fully-measured pass to the same target
      // resolves to, taken independently of the timed Mode B call below.
      final referenceController = IndexedScrollController(scrollDuration: Duration.zero);
      addTearDown(referenceController.dispose);
      await _pumpAtSurfaceSize(
        tester,
        _list(controller: referenceController, itemCount: itemCount, rowHeight: rowHeight),
        const Size(400.0, viewportHeight),
      );
      await tester.pump();
      await _pumpUntilComplete(tester, referenceController.scrollTo((itemCount - 1).toDouble(), duration: Duration.zero));
      await _pumpUntilComplete(tester, referenceController.scrollTo(targetIndex.toDouble(), duration: Duration.zero));
      final referenceOffset = referenceController.position.pixels;

      // Timed Mode B call: same target, fresh (unmeasured) controller.
      final controller = IndexedScrollController(scrollDuration: duration);
      addTearDown(controller.dispose);
      await _pumpAtSurfaceSize(
        tester,
        _list(controller: controller, itemCount: itemCount, rowHeight: rowHeight),
        const Size(400.0, viewportHeight),
      );
      await tester.pump();

      final result = await _pumpUntilComplete(
        tester,
        controller.scrollTo(targetIndex.toDouble(), duration: duration),
      );

      // The search step is exactly one viewport (see ISC-82a; ISC-82c may
      // change this, in which case this bound must be re-derived from the
      // step actually in use, not loosened arbitrarily).
      const distancePx = targetIndex * rowHeight;
      final theoreticalSteps = (distancePx / viewportHeight).ceil();

      // Each search step costs one frame (one endOfFrame await); a small
      // constant covers the initial-frame wait and the final approach/
      // animate steps, which are not part of the search proper.
      final maxExpectedFrames = theoreticalSteps + 5;

      expect(
        result.frames,
        lessThanOrEqualTo(maxExpectedFrames),
        reason: 'Search frames (${result.frames}) must stay within a small constant of the '
            'theoretical bound ($theoreticalSteps steps for ${distancePx}px at $viewportHeight'
            'px steps) -- a much higher count would mean the search regressed to something '
            'other than linear-in-distance',
      );

      expect(
        controller.position.pixels,
        closeTo(referenceOffset, 0.5),
        reason: 'Mode B must resolve to the exact same offset as Mode A for the same target -- '
            'a faster-but-wrong implementation (e.g. skipping the endOfFrame wait) would show up '
            'here as a mismatched offset, not just as suspiciously few frames',
      );
    });
  });
}
