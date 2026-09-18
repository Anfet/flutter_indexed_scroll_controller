import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'support/scroll_harness.dart';

/// ISC-12A: Supported configuration for vertical ListView.builder
///
/// After jumpTo or initialScrollOffset (starting not from offset 0), verify:
/// 1. A continuous prefix of indices 0..N is measured (no gaps).
/// 2. Forward and backward scrollTo operations reach exact offsets.
/// 3. Non-contiguous watch() indices (0,1,2,50,51,52) raise StateError,
///    not _TypeError (this is covered by ISC-03 test, included here for
///    regression tracking of the original gap-handling failure).
///
/// These tests also verify that a vertical [ListView.builder] produces a
/// continuous measured prefix after `jumpTo` or `initialScrollOffset`.
void main() {
  group('ISC-12A: watch() index continuity and offset accuracy', () {
    testWidgets(
      'jumpTo to 12000px ensures continuous prefix is measured, then forward/back scrollTo reach exact offsets',
      (WidgetTester tester) async {
        // After jumpTo(12000), the ListView.builder configuration must measure
        // a continuous prefix. Forward and backward calls then reach exact offsets.
        //
        // Using 120 items x 100px each (total 12000px), so jumpTo(12000)
        // lands at the end. Verify that measurement fills from 0.
        const int itemCount = 120;
        const double itemHeight = 100.0;

        await tester.pumpWidget(
          ScrollHarness(
            itemCount: itemCount,
            itemHeightBuilder: (_) => itemHeight,
            guardLimit: 500,
          ),
        );
        final state = tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
        await tester.pumpAndSettle();

        // JumpTo a specific pixel offset (not starting from 0)
        state.controller.jumpTo(12000.0);
        await tester.pumpAndSettle();

        // Collect initial measurements after jumpTo
        final postJumpSizes = Map<int, Size>.from(
          state.controller.measurementsSizes,
        );

        // After jumpTo, there should be measured items. Check for continuity.
        expect(
          postJumpSizes.isNotEmpty,
          isTrue,
          reason: 'After jumpTo, the controller should have measured at least one item.',
        );

        // If there are measured items, check that they form a continuous prefix
        // starting from index 0. Find the maximum index measured.
        if (postJumpSizes.isNotEmpty) {
          final maxMeasuredIndex = postJumpSizes.keys.reduce((a, b) => a > b ? a : b);

          // Verify all indices from 0 to maxMeasuredIndex are present (no gaps).
          for (int i = 0; i <= maxMeasuredIndex; i++) {
            expect(
              postJumpSizes.containsKey(i),
              isTrue,
              reason: 'After jumpTo, indices should form a continuous prefix from 0; '
                  'index $i is missing between 0 and $maxMeasuredIndex.',
            );
          }
        }

        // Now scroll forward using scrollTo
        final scrollToFutureForward = state.controller.scrollTo(
          50.0, // Scroll to index 50
          duration: const Duration(milliseconds: 100),
        );

        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        // Verify forward scroll completed
        bool forwardCompleted = false;
        Object? forwardError;
        unawaited(
          scrollToFutureForward.then(
            (_) => forwardCompleted = true,
            onError: (Object e) {
              forwardError = e;
              forwardCompleted = true;
            },
          ),
        );

        // Wait for completion
        while (!forwardCompleted && tester.binding.transientCallbackCount > 0) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          forwardError,
          isNull,
          reason: 'scrollTo(50.0) must complete without error. Got: $forwardError',
        );

        final offsetAfterScrollToForward = state.controller.position.pixels;

        // Expected offset for index 50: sum of heights from 0 to 49
        // With uniform height of 100.0 each, this is 50 * 100 = 5000.0
        const double expectedOffsetForIndex50 = 50.0 * itemHeight;

        expect(
          offsetAfterScrollToForward,
          closeTo(expectedOffsetForIndex50, 2.0),
          reason: 'After scrollTo(50.0), offset should be approximately ${expectedOffsetForIndex50}px '
              '(sum of heights 0..49 with item height $itemHeight each), '
              'but got $offsetAfterScrollToForward.',
        );

        // Now scroll backward to a smaller index
        final scrollToFutureBack = state.controller.scrollTo(
          2.0,
          duration: const Duration(milliseconds: 100),
        );

        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        // Verify backward scroll completed
        bool backCompleted = false;
        Object? backError;
        unawaited(
          scrollToFutureBack.then(
            (_) => backCompleted = true,
            onError: (Object e) {
              backError = e;
              backCompleted = true;
            },
          ),
        );

        // Wait for completion
        while (!backCompleted && tester.binding.transientCallbackCount > 0) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          backError,
          isNull,
          reason: 'scrollTo(2.0) must complete without error. Got: $backError',
        );

        final offsetAfterScrollToBack = state.controller.position.pixels;

        // Expected offset for index 2: sum of heights from 0 to 1
        // With uniform height of 100.0 each, this is 2 * 100 = 200.0
        const double expectedOffsetForIndex2 = 2.0 * itemHeight;

        expect(
          offsetAfterScrollToBack,
          closeTo(expectedOffsetForIndex2, 2.0),
          reason: 'After scrollTo(2.0), offset should be approximately ${expectedOffsetForIndex2}px '
              '(sum of heights 0..1 with item height $itemHeight each), '
              'but got $offsetAfterScrollToBack.',
        );

        // Final check: verify continuous prefix is still measured up to at least index 2
        final finalSizes = state.controller.measurementsSizes;
        expect(
          finalSizes.containsKey(0) && finalSizes.containsKey(1) && finalSizes.containsKey(2),
          isTrue,
          reason: 'After both scrollTo operations, indices 0, 1, and 2 should be measured.',
        );
      },
    );

    testWidgets(
      'initialScrollOffset creates continuous prefix, scrollTo(2) returns exact offset',
      (WidgetTester tester) async {
        // The same continuous prefix is expected after initialScrollOffset.
        //
        // Using initialScrollOffset instead of jumpTo. With 120 items x 100px,
        // initialScrollOffset: 12000 lands at the very end.
        const int itemCount = 120;
        const double itemHeight = 100.0;

        // Create a custom harness with initialScrollOffset
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: _InitialOffsetHarness(
                itemCount: itemCount,
                itemHeightBuilder: (_) => itemHeight,
                initialScrollOffset: 12000.0,
              ),
            ),
          ),
        );

        final state = tester.state<_InitialOffsetHarnessState>(
          find.byType(_InitialOffsetHarness),
        );
        await tester.pumpAndSettle();

        // After settling, collect measurements
        final measuredSizes = Map<int, Size>.from(
          state.controller.measurementsSizes,
        );

        // Verify that some items are measured
        expect(
          measuredSizes.isNotEmpty,
          isTrue,
          reason: 'After initialScrollOffset, the controller should have measured at least one item.',
        );

        // Check continuity of measured indices from 0
        if (measuredSizes.isNotEmpty) {
          final maxMeasuredIndex = measuredSizes.keys.reduce((a, b) => a > b ? a : b);

          for (int i = 0; i <= maxMeasuredIndex; i++) {
            expect(
              measuredSizes.containsKey(i),
              isTrue,
              reason: 'After initialScrollOffset, indices should form a continuous prefix from 0; '
                  'index $i is missing between 0 and $maxMeasuredIndex.',
            );
          }
        }

        // ScrollTo a small index to verify exact offset
        final scrollToFuture = state.controller.scrollTo(
          2.0,
          duration: const Duration(milliseconds: 100),
        );

        for (int i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        bool scrollCompleted = false;
        Object? scrollError;
        unawaited(
          scrollToFuture.then(
            (_) => scrollCompleted = true,
            onError: (Object e) {
              scrollError = e;
              scrollCompleted = true;
            },
          ),
        );

        while (!scrollCompleted && tester.binding.transientCallbackCount > 0) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          scrollError,
          isNull,
          reason: 'scrollTo(2.0) must complete without error. Got: $scrollError',
        );

        final offsetAfterScroll = state.controller.position.pixels;
        const double expectedOffset = 2.0 * itemHeight; // 200.0

        expect(
          offsetAfterScroll,
          closeTo(expectedOffset, 2.0),
          reason: 'After scrollTo(2.0) from initialScrollOffset, offset should be '
              '$expectedOffset px, but got $offsetAfterScroll.',
        );
      },
    );

    testWidgets(
      'non-contiguous watch() indices raise StateError, not _TypeError (ISC-03 regression test)',
      (WidgetTester tester) async {
        // This case is covered by ISC-03's "non-contiguous watch() indices give
        // StateError naming the missing index" test. Including it here as a
        // regression anchor for ISC-12A: confirms that sparse logical indices
        // surface StateError through _sizeOrThrow().
        //
        // If this test fails, it indicates a regression in error handling of
        // discontinuous watch() index registration.
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        const logicalIndices = [0, 1, 2, 50, 51, 52];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: logicalIndices.length,
                itemBuilder: (context, i) {
                  final logicalIndex = logicalIndices[i];
                  return controller.watch(
                    index: logicalIndex,
                    child: SizedBox(
                      height: 100.0,
                      child: Text('Item $logicalIndex'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Attempting to scrollTo an index beyond the measured prefix should
        // raise StateError with the first missing index (3) in the message,
        // not a silent _TypeError.
        //
        // ISC-31: scrollTo() now checks the WHOLE prefix 0..target before
        // trusting _sizes, so this no longer throws synchronously (52's own
        // size was already cached, but the prefix under it has a hole) -- it
        // falls back to the internal sequential search-from-0 pass, which
        // only discovers and reports the gap once that search stalls, after
        // several pumped frames.
        Object? scrollError;
        bool scrollCompleted = false;
        unawaited(
          controller.scrollTo(52.0, duration: const Duration(milliseconds: 100)).then(
            (_) => scrollCompleted = true,
            onError: (Object e) {
              scrollError = e;
              scrollCompleted = true;
            },
          ),
        );

        for (int i = 0; i < 300 && !scrollCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        expect(
          scrollError,
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('3'),
          ),
          reason: 'Non-contiguous watch() indices must raise StateError naming the '
              'first missing index (3 in this case), not _TypeError.',
        );
      },
    );
  });
}

/// Custom harness that supports initialScrollOffset.
///
/// The default ScrollHarness does not expose initialScrollOffset parameter
/// to ListView.builder, so we create a minimal variant for this test.
class _InitialOffsetHarness extends StatefulWidget {
  final int itemCount;
  final double Function(int index) itemHeightBuilder;
  final double initialScrollOffset;

  const _InitialOffsetHarness({
    required this.itemCount,
    required this.itemHeightBuilder,
    required this.initialScrollOffset,
  });

  @override
  State<_InitialOffsetHarness> createState() => _InitialOffsetHarnessState();
}

class _InitialOffsetHarnessState extends State<_InitialOffsetHarness> {
  late IndexedScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = IndexedScrollController(
      scrollDuration: const Duration(milliseconds: 100),
      initialScrollOffset: widget.initialScrollOffset,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  IndexedScrollController get controller => _controller;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _controller,
      itemCount: widget.itemCount,
      itemBuilder: (context, index) {
        final height = widget.itemHeightBuilder(index);
        return _controller.watch(
          index: index,
          child: Container(
            height: height,
            color: Colors.primaries[index % Colors.primaries.length],
            child: Center(
              child: Text(
                'Item $index\n${height.toStringAsFixed(0)} px',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        );
      },
    );
  }
}
