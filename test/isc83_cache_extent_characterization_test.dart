// ISC-83: Characterizes how far Flutter's SliverList lays out rows beyond
// the visible viewport, so ISC-82's search-step size can be chosen from a
// measured fact instead of an emprically-tuned coefficient (the discredited
// `viewportSize * 1.5` from commit 22c0081).
//
// This file characterizes Flutter's own layout behavior (RenderViewportBase's
// cache extent, `rendering/viewport.dart`), not this package's. If a future
// Flutter version changes `RenderAbstractViewport.defaultCacheExtent` or the
// cache-extent mechanism itself, these tests SHOULD fail -- that is the
// point, not a regression to "fix" by adjusting the expected numbers back
// into passing. A failure here means ISC-82's step-size assumption needs
// re-deriving, not that the test is wrong.
//
// Every scenario reads `IndexedScrollController.measurementsSizes` as its
// oracle for "did Flutter lay this row out" -- `watch()` registers a row's
// size from `_RenderIndexedScrollItem.performLayout` (see
// `indexed_scroll_item.dart`), which only runs for a row Flutter's own
// SliverList actually built and laid out. This is a direct, non-inferred
// signal: no polling heuristic, no timing guess.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// The value read directly from Flutter's own source
/// (`RenderAbstractViewport.defaultCacheExtent`, `rendering/viewport.dart`
/// around line 289) -- the pixel cache extent `ListView.builder` applies on
/// both sides of the viewport when no `cacheExtent` is passed.
const double _defaultCacheExtent = 250.0;

/// Builds a vertical `ListView.builder` with every row wrapped in
/// [IndexedScrollController.watch], with direct control over `cacheExtent`
/// -- left unexposed by [ScrollHarness], which this characterization needs
/// to hold fixed as the independent variable.
///
/// Deliberately has no `Scaffold`/`AppBar` and no fixed-height wrapper: the
/// list fills whatever the test surface is. A `SizedBox(height: ...)`
/// wrapper looked like the obvious way to request a given viewport height,
/// but the default test surface is 800x600 -- a taller SizedBox is silently
/// clamped to 600, not granted its requested height (confirmed: a 900px
/// SizedBox produced viewportDimension 600.0, not 900.0). Setting the test
/// surface itself via [pumpAtSurfaceSize] is what actually controls
/// [ScrollPosition.viewportDimension].
Widget _harness({
  required IndexedScrollController controller,
  required int itemCount,
  required double Function(int) itemHeightBuilder,
  double? cacheExtent,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ListView.builder(
      controller: controller,
      scrollCacheExtent:
          cacheExtent != null ? ScrollCacheExtent.pixels(cacheExtent) : null,
      itemCount: itemCount,
      itemBuilder: (context, index) {
        return controller.watch(
          index: index,
          child: SizedBox(
            height: itemHeightBuilder(index),
            child: Text('Item $index'),
          ),
        );
      },
    ),
  );
}

/// Pumps [widget] into a test surface sized exactly [size], so
/// [ScrollPosition.viewportDimension] equals [size].height precisely --
/// the default 800x600 test surface silently clamps a taller in-tree
/// `SizedBox` instead of granting it (see [_harness]'s Dartdoc).
Future<void> _pumpAtSurfaceSize(
    WidgetTester tester, Widget widget, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size),
      child: widget,
    ),
  );
}

/// The highest logical index in [controller]'s measured map -- the
/// furthest row Flutter's SliverList has laid out so far.
int _maxMeasuredIndex(IndexedScrollController controller) {
  return controller.measurementsSizes.keys.reduce((a, b) => a > b ? a : b);
}

void main() {
  group('ISC-83: cache extent characterization', () {
    testWidgets(
        'base case: many small rows, default cache extent, measures viewport + 250px on both sides',
        (tester) async {
      // 20px rows, 500px viewport: viewport alone covers rows 0-24 (25
      // rows). The default 250px cache extent on the trailing edge should
      // add another 12-13 rows (250 / 20 = 12.5), so layout should reach
      // roughly to row 37, not further -- and not stop short at row 24
      // (which would mean the cache extent isn't being applied at all).
      const rowHeight = 20.0;
      const viewportHeight = 500.0;

      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await _pumpAtSurfaceSize(
        tester,
        _harness(
          controller: controller,
          itemCount: 500,
          itemHeightBuilder: (_) => rowHeight,
        ),
        const Size(400.0, viewportHeight),
      );
      await tester.pump();

      final maxIndex = _maxMeasuredIndex(controller);
      final maxBuiltExtentPx = (maxIndex + 1) * rowHeight;

      // Expected reach from the viewport's start: viewport + cache extent.
      // No leading cache extent to account for here -- position is 0, and a
      // correctedCacheOrigin clamps the leading cache area to what actually
      // exists above scrollOffset 0 (see viewport.dart's cacheOrigin
      // handling), so only the trailing side is testable from rest.
      const expectedReachPx = viewportHeight + _defaultCacheExtent;
      final expectedMaxIndex = (expectedReachPx / rowHeight).floor() - 1;

      expect(
        maxBuiltExtentPx,
        closeTo(expectedReachPx, rowHeight),
        reason:
            'Layout should reach viewport ($viewportHeight) + default cache extent '
            '($_defaultCacheExtent) = $expectedReachPx px past the list start, within one '
            'row height of slack; actually reached ${maxBuiltExtentPx}px (row $maxIndex)',
      );

      // Guard against the cache extent being silently ignored (a formula
      // change that stopped applying it would still "pass" a loose
      // tolerance check above if the tolerance were wide enough).
      expect(
        maxIndex,
        greaterThan((viewportHeight / rowHeight).ceil()),
        reason: 'Layout must reach past the viewport-only bound (row '
            '${(viewportHeight / rowHeight).ceil()}); reaching only that far would mean no '
            'cache extent was applied',
      );

      expect(maxIndex, lessThan(expectedMaxIndex + 5),
          reason:
              'Layout must not reach dramatically further than viewport + cache extent implies');
    });

    testWidgets(
        'cache extent reach is independent of viewport size (pixels, not a fraction of viewport)',
        (tester) async {
      // Same row height, two different viewport heights. If the reach past
      // the viewport were a FRACTION of viewport size (the "half a screen"
      // hypothesis behind the discredited 1.5x coefficient), the absolute
      // pixel overshoot would scale with viewport height. If it is the
      // documented pixel constant, the overshoot stays the same regardless
      // of viewport height.
      const rowHeight = 20.0;

      Future<double> overshootPastViewportPx(double viewportHeight) async {
        final controller = IndexedScrollController(
            scrollDuration: const Duration(milliseconds: 100));
        addTearDown(controller.dispose);

        await _pumpAtSurfaceSize(
          tester,
          _harness(
            controller: controller,
            itemCount: 500,
            itemHeightBuilder: (_) => rowHeight,
          ),
          Size(400.0, viewportHeight),
        );
        await tester.pump();

        final maxBuiltExtentPx =
            (_maxMeasuredIndex(controller) + 1) * rowHeight;
        return maxBuiltExtentPx - viewportHeight;
      }

      final overshootSmall = await overshootPastViewportPx(300.0);
      final overshootLarge = await overshootPastViewportPx(900.0);

      // Both should be close to the 250px constant, within a row height of
      // slack for the discrete row-boundary rounding.
      expect(overshootSmall, closeTo(_defaultCacheExtent, rowHeight));
      expect(overshootLarge, closeTo(_defaultCacheExtent, rowHeight));

      // The decisive comparison: if reach scaled with viewport (the "half a
      // screen" hypothesis), a 600px larger viewport would overshoot by
      // hundreds of pixels more. It does not.
      expect(
        (overshootLarge - overshootSmall).abs(),
        lessThan(rowHeight * 2),
        reason:
            'Overshoot past the viewport edge must not scale with viewport size: got '
            '${overshootSmall}px at 300px viewport vs ${overshootLarge}px at 900px viewport. '
            'A difference this large would mean cache extent is proportional to viewport, '
            'not the fixed-pixel constant the SDK documents -- and the step-size formula in '
            'ISC-82 would need to read the viewport-relative style instead.',
      );
    });

    testWidgets(
        'a row larger than viewport + cache extent is still built in full (SliverList is not lazy within a row)',
        (tester) async {
      // A 2000px row against a 100px viewport (built extent budget: 100 +
      // 250 = 350px) is not itself covered by the cache extent budget. If
      // SliverList built rows lazily WITHIN a row's own extent, this row
      // might report a partial/zero size, or the search step formula could
      // safely assume "a step never lands mid-row". Confirms it does not:
      // the whole oversized row is laid out and measured as one unit.
      const viewportHeight = 100.0;

      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await _pumpAtSurfaceSize(
        tester,
        _harness(
          controller: controller,
          itemCount: 10,
          itemHeightBuilder: (i) => i == 0 ? 2000.0 : 100.0,
        ),
        const Size(400.0, viewportHeight),
      );
      await tester.pump();

      expect(controller.measurementsSizes.containsKey(0), isTrue,
          reason:
              'The oversized row 0 must be built and measured despite exceeding viewport + cache extent');
      expect(controller.measurementsSizes[0]!.height, 2000.0);

      // Because row 0 alone consumes 2000px against a 350px build budget,
      // no further row should have been reached this frame -- row 0's own
      // extent is the effective step ceiling here, not viewport +
      // cacheExtent. This is the case ISC-82's step formula must never
      // exceed: a step landing inside row 0 would still need row 0's full
      // extent laid out before the next row is even attempted.
      expect(controller.measurementsSizes.containsKey(1), isFalse,
          reason:
              'An oversized leading row should exhaust the build budget on its own, before any row past it is reached');
    });

    testWidgets('an explicit pixel cacheExtent shifts the reach predictably',
        (tester) async {
      const rowHeight = 20.0;
      const viewportHeight = 500.0;
      const explicitCacheExtent = 1000.0;

      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await _pumpAtSurfaceSize(
        tester,
        _harness(
          controller: controller,
          itemCount: 500,
          itemHeightBuilder: (_) => rowHeight,
          cacheExtent: explicitCacheExtent,
        ),
        const Size(400.0, viewportHeight),
      );
      await tester.pump();

      final maxBuiltExtentPx = (_maxMeasuredIndex(controller) + 1) * rowHeight;

      expect(
        maxBuiltExtentPx,
        closeTo(viewportHeight + explicitCacheExtent, rowHeight),
        reason:
            'An explicit cacheExtent of $explicitCacheExtent should replace the default '
            '250px, reaching viewport + $explicitCacheExtent px, not viewport + $_defaultCacheExtent px',
      );

      // Decisive fact for ISC-82c: is the *effective* cache extent readable
      // from the render tree at runtime (via
      // RenderViewportBase.scrollCacheExtent), or only knowable because the
      // test itself set it? Read it back from the actual render object to
      // settle this -- if unreadable from outside the render tree, ISC-82c
      // must stay closed and the step size must stay at a conservative
      // 1.0x viewport.
      final renderViewport =
          tester.allRenderObjects.whereType<RenderViewport>().first;
      expect(
        renderViewport.scrollCacheExtent.style,
        CacheExtentStyle.pixel,
        reason:
            'An explicit double cacheExtent should be readable back as a pixel-style '
            'ScrollCacheExtent',
      );
      expect(
        renderViewport.scrollCacheExtent.value,
        explicitCacheExtent,
        reason:
            'RenderViewportBase.scrollCacheExtent must be readable from the render object '
            'at runtime for ISC-82c (a step formula of viewport + actual cache extent) to be '
            'possible at all',
      );
    });

    testWidgets(
        'a single jumpTo teleport does NOT retain a leading cache extent behind the new position',
        (tester) async {
      // This scenario set out to confirm the "before the leading edge"
      // half of scrollCacheExtent's contract after a jump -- and found the
      // opposite. Recorded as its own test because it directly bears on
      // ISC-82's search loop, which advances by repeated jumpTo calls.
      //
      // measurementsSizes is NOT the right oracle for "still built right
      // now": it is a write-only, cumulative cache (_sizes[index] = size,
      // never removed -- confirmed by reading
      // indexed_scroll_controller.dart's _registerSize), so a row measured
      // once stays in it forever, long after SliverList has deactivated
      // its render object and moved on. A row's *element* being currently
      // in the tree (find.text) is the actual "still built right now"
      // signal.
      const rowHeight = 20.0;
      const viewportHeight = 500.0;

      final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100));
      addTearDown(controller.dispose);

      await _pumpAtSurfaceSize(
        tester,
        _harness(
          controller: controller,
          itemCount: 500,
          itemHeightBuilder: (_) => rowHeight,
        ),
        const Size(400.0, viewportHeight),
      );
      await tester.pump();

      // A single jumpTo far past the current build range, not a sequence
      // of small steps -- this is what ISC-82a's search loop does on each
      // iteration.
      const scrollTarget = 5000.0;
      controller.jumpTo(scrollTarget);
      await tester.pump();

      final leadingRowIndexAtViewportStart = (scrollTarget / rowHeight).round();

      // Measured: after a single jumpTo + one pump, layout builds forward
      // from the viewport's new leading edge (confirmed: row exactly at
      // leadingRowIndexAtViewportStart is present) but nothing at all
      // behind it -- not even one row -- survives the jump. A gradual,
      // incremental scroll to the same position (many small jumpTo calls,
      // one pump each) DOES retain the expected ~12-13 rows behind the
      // edge; the difference is the teleport itself, not the destination.
      // Likely cause: a discontinuous jump gives the viewport nothing to
      // extend backward FROM -- the previous frame's built subtree near
      // the old position is simply irrelevant to the new scrollOffset, so
      // there is no history for a leading cache extent to preserve.
      expect(
        find.text('Item $leadingRowIndexAtViewportStart'),
        findsOneWidget,
        reason:
            'The row exactly at the new viewport start must be built immediately after '
            'the jump',
      );
      expect(
        find.text('Item ${leadingRowIndexAtViewportStart - 1}'),
        findsNothing,
        reason:
            'A single-frame jumpTo teleport must not retain ANY row behind the new '
            'viewport position -- confirmed: the leading cache extent only applies to '
            'positions reached by continuous/incremental scrolling, not a bare jump. '
            'ISC-82a\'s search loop (which jumps repeatedly) gets no free lookback from this '
            'mechanism and must not assume one.',
      );
    });
  });
}
