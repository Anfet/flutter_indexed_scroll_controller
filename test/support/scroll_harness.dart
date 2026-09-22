import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// Awaits [future] while pumping frames, bounded by [maxPumps], so a
/// `scrollTo()` call under test is proven to actually complete within the
/// harness's guard budget instead of merely leaving plausible-looking
/// `pixels` behind after a fixed, unconditional pump loop.
Future<void> pumpUntilComplete(
  WidgetTester tester,
  Future<void> future, {
  int maxPumps = 300,
}) async {
  var settled = false;
  // Both branches (not just the success one) must flip `settled`, or a
  // scrollTo() that fails with an error is indistinguishable from one that
  // never completes: the pump loop below would run for the full maxPumps
  // budget and this helper would report a spurious "did not complete"
  // instead of letting the awaited `future` below surface the real error.
  future.then((_) => settled = true, onError: (_) => settled = true);

  for (var i = 0; i < maxPumps && !settled; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }

  expect(settled, isTrue,
      reason: 'scrollTo() did not complete within $maxPumps pumps');
  await future;
}

/// A snapshot of scroll state at a particular frame.
class ScrollFrameSnapshot {
  final int frameNumber;
  final double scrollOffset;
  final double viewportHeight;
  final Map<int, Size> measuredSizes;

  ScrollFrameSnapshot({
    required this.frameNumber,
    required this.scrollOffset,
    required this.viewportHeight,
    required this.measuredSizes,
  });

  @override
  String toString() {
    return 'Frame $frameNumber: offset=$scrollOffset, viewport=$viewportHeight, '
        'measured=${measuredSizes.length} items';
  }
}

/// Frame-by-frame observation result after pump loop completes.
class ScrollObservationResult {
  /// Whether the loop completed normally (true) or hit guard limit (false).
  final bool completed;

  /// Number of frames pumped.
  final int frameCount;

  /// Snapshots collected at each frame.
  final List<ScrollFrameSnapshot> snapshots;

  /// Error message if the loop hit guard limit, null otherwise.
  String? get guardLimitExceededMessage =>
      completed ? null : 'Guard limit of $frameCount frames exceeded';

  ScrollObservationResult({
    required this.completed,
    required this.frameCount,
    required this.snapshots,
  });

  @override
  String toString() {
    return 'ScrollObservationResult(completed=$completed, frames=$frameCount, '
        'snapshots=${snapshots.length})';
  }
}

/// Configuration for scroll harness item heights.
typedef ItemHeightBuilder = double Function(int index);

/// Test harness for observing ListView with varied item heights.
///
/// Creates a `ListView.builder` (vertical by default, or horizontal when
/// [scrollDirection] is [Axis.horizontal] and [itemWidthBuilder] is
/// supplied) with configurable item count and extents, using the real
/// IndexedScrollController.watch() API. Provides frame-by-frame observation
/// loop with progress tracking and guard limit to prevent hangs.
class ScrollHarness extends StatefulWidget {
  /// Number of items in the list.
  final int itemCount;

  /// Function to compute item height by index.
  final ItemHeightBuilder itemHeightBuilder;

  /// Function to compute item width by index. Only used when
  /// [scrollDirection] is [Axis.horizontal]; defaults to a fixed width when
  /// omitted.
  final ItemHeightBuilder? itemWidthBuilder;

  /// Scroll axis for the underlying `ListView.builder`.
  final Axis scrollDirection;

  /// Text direction wrapping the `ListView.builder`, for RTL scenarios.
  final TextDirection textDirection;

  /// Padding applied to the underlying `ListView.builder` along its scroll
  /// axis (and cross-axis, if any), for padding-related scenarios.
  final EdgeInsets? padding;

  /// Guard limit for pump frames before failing the observation.
  ///
  /// Defaults to 500. Should be high enough to allow lengthy sequential
  /// height measurements, but protect against infinite loops.
  final int guardLimit;

  /// Optional callback when a frame snapshot is collected.
  final void Function(ScrollFrameSnapshot)? onSnapshot;

  const ScrollHarness({
    super.key,
    required this.itemCount,
    required this.itemHeightBuilder,
    this.itemWidthBuilder,
    this.scrollDirection = Axis.vertical,
    this.textDirection = TextDirection.ltr,
    this.padding,
    this.guardLimit = 500,
    this.onSnapshot,
  });

  @override
  State<ScrollHarness> createState() => ScrollHarnessState();
}

class ScrollHarnessState extends State<ScrollHarness> {
  late IndexedScrollController _controller;
  late ScrollFrameSnapshot? _latestSnapshot;

  @override
  void initState() {
    super.initState();
    _controller = IndexedScrollController(
      scrollDuration: const Duration(milliseconds: 100),
    );
    _latestSnapshot = null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Get the controller for scrolling operations.
  IndexedScrollController get controller => _controller;

  /// Record and return the current scroll state snapshot.
  ScrollFrameSnapshot _takeSnapshot(int frameNumber) {
    final position = _controller.position;
    final scrollOffset = position.pixels;
    final viewportHeight = position.viewportDimension;

    final snapshot = ScrollFrameSnapshot(
      frameNumber: frameNumber,
      scrollOffset: scrollOffset,
      viewportHeight: viewportHeight,
      measuredSizes: Map<int, Size>.from(_controller.measurementsSizes),
    );

    _latestSnapshot = snapshot;
    widget.onSnapshot?.call(snapshot);
    return snapshot;
  }

  /// Run pump loop with frame-by-frame observation.
  ///
  /// Pumps the widget frame by frame, collecting snapshots at each frame.
  /// Stops when [shouldContinue] returns false or guard limit is reached.
  /// Returns [ScrollObservationResult] with collected snapshots and completion status.
  Future<ScrollObservationResult> observeFrames({
    required WidgetTester tester,
    required bool Function(ScrollFrameSnapshot snapshot) shouldContinue,
  }) async {
    final snapshots = <ScrollFrameSnapshot>[];
    int frameNumber = 0;

    while (frameNumber < widget.guardLimit) {
      await tester.pump();
      frameNumber++;

      final snapshot = _takeSnapshot(frameNumber);
      snapshots.add(snapshot);

      if (!shouldContinue(snapshot)) {
        return ScrollObservationResult(
          completed: true,
          frameCount: frameNumber,
          snapshots: snapshots,
        );
      }
    }

    return ScrollObservationResult(
      completed: false,
      frameCount: frameNumber,
      snapshots: snapshots,
    );
  }

  /// Get the most recent snapshot (for test context).
  ScrollFrameSnapshot? get latestSnapshot => _latestSnapshot;

  @override
  Widget build(BuildContext context) {
    final isHorizontal = widget.scrollDirection == Axis.horizontal;
    return MaterialApp(
      home: Directionality(
        textDirection: widget.textDirection,
        child: Scaffold(
          body: ListView.builder(
            controller: _controller,
            scrollDirection: widget.scrollDirection,
            padding: widget.padding,
            itemCount: widget.itemCount,
            itemBuilder: (context, index) {
              final height = widget.itemHeightBuilder(index);
              final width = widget.itemWidthBuilder?.call(index) ?? 100.0;
              return _controller.watch(
                index: index,
                child: Container(
                  height: isHorizontal ? null : height,
                  width: isHorizontal ? width : null,
                  color: Colors.primaries[index % Colors.primaries.length],
                  child: Center(
                    child: Text(
                      'Item $index',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
