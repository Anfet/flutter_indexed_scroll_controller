import 'dart:async';
import 'dart:collection' show UnmodifiableMapView;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

part 'indexed_scroll_item.dart';
part 'indexed_scroll_gesture_detector.dart';

/// Explains why a [IndexedScrollController.scrollTo] operation stopped.
enum ScrollCancelReason {
  /// A newer scroll request replaced this one.
  superseded,

  /// [IndexedScrollController.cancelScroll] stopped the operation.
  explicitCancel,

  /// Measurements or fingerprinted data changed during the operation.
  dataInvalidated,

  /// The controller detached from its scroll position.
  detached,

  /// The controller was disposed.
  disposed,

  /// A user drag took control of the scroll position.
  userGesture,
}

/// Selects the extent used by [IndexedScrollController.scrollTo] alignment.
enum ScrollAlignmentTarget {
  /// Align the complete row, including a registered trailing separator.
  row,

  /// Align the item without its registered trailing separator.
  item,
}

/// Thrown when [IndexedScrollController.scrollTo] is cancelled.
class ScrollCancelledException implements Exception {
  /// The cancellation cause.
  final ScrollCancelReason reason;

  /// The requested logical index.
  final double requestedIndex;

  /// Creates a cancellation exception.
  const ScrollCancelledException(this.reason, this.requestedIndex);

  @override
  String toString() =>
      'ScrollCancelledException(reason: $reason, requestedIndex: $requestedIndex)';
}

class _OperationFingerprintSnapshot {
  final int targetItemIndex;
  final int corridorHiIndex;
  final List<Object?> fingerprints;

  const _OperationFingerprintSnapshot({
    required this.targetItemIndex,
    required this.corridorHiIndex,
    required this.fingerprints,
  });
}

/// A [ScrollController] that navigates a single indexed `ListView.builder`.
///
/// Wrap each row with [watch] using the zero-based `itemBuilder` index.
class IndexedScrollController extends ScrollController {
  /// The default duration for [scrollTo].
  final Duration scrollDuration;

  /// The default curve for [scrollTo].
  final Curve curve;

  /// Returns the current item count for automatic invalidation.
  final int Function()? itemCount;

  /// Returns a size-affecting data fingerprint for an item.
  final Object? Function(int index)? contentFingerprint;

  final Map<int, Size> _sizes = {};

  final Map<int, Object?> _fingerprints = {};

  @visibleForTesting
  Map<int, Size> get measurementsSizes => UnmodifiableMapView(_sizes);

  final Map<int, Size> _separatorSizes = {};

  @visibleForTesting
  Map<int, Size> get separatorSizes => UnmodifiableMapView(_separatorSizes);

  @visibleForTesting
  bool hasSeparatorFor(int index) => _separatorSizes.containsKey(index);

  @visibleForTesting
  bool hasFingerprintFor(int index) => _fingerprints.containsKey(index);

  @visibleForTesting
  Object? fingerprintFor(int index) => _fingerprints[index];

  static const double _alreadyAtTargetTolerancePixels = 1.0;

  double _extentOf(Size size) =>
      position.axis == Axis.horizontal ? size.width : size.height;

  bool get _isReversed =>
      position.axisDirection == AxisDirection.up ||
      position.axisDirection == AxisDirection.left;

  int _currentOperationId = 0;

  bool _disposed = false;

  int? _activeOperationId;

  int? _explicitlyCancelledOperationId;

  int? _invalidatedOperationId;

  int? _userGestureCancelledOperationId;

  int _measurementGeneration = 0;

  @visibleForTesting
  int get measurementGeneration => _measurementGeneration;

  /// Creates a controller for indexed scrolling.
  ///
  /// Provide [itemCount] and [contentFingerprint] together to enable
  /// automatic invalidation; otherwise call [invalidateMeasurements] after
  /// size-affecting data changes.
  IndexedScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    super.onAttach,
    super.onDetach,
    required this.scrollDuration,
    this.curve = Curves.linear,
    this.itemCount,
    this.contentFingerprint,
  }) {
    if ((itemCount == null) != (contentFingerprint == null)) {
      throw ArgumentError(
        'itemCount and contentFingerprint must be provided together, or '
        'both omitted to use the manual invalidateMeasurements() mode.',
      );
    }
  }

  /// Wraps a row and records its laid-out size under [index].
  ///
  /// Indices must be consecutive and match the `itemBuilder` index.
  Widget watch({required int index, required Widget child}) {
    final fingerprintCallback = contentFingerprint;
    return _IndexedScrollItem(
      controller: this,
      index: index,
      hasFingerprintSnapshot: fingerprintCallback != null,
      fingerprintSnapshot: fingerprintCallback?.call(index),
      child: child,
    );
  }

  /// Wraps the separator that follows item [index] in a `ListView.separated`.
  ///
  /// Use with [ScrollAlignmentTarget.item] to align the item without its
  /// trailing separator.
  Widget separator({required int index, required Widget child}) {
    return _IndexedScrollSeparator(
      controller: this,
      index: index,
      child: child,
    );
  }

  final Map<int, _RenderIndexedScrollItem> _liveOwners = {};

  final Map<int, _RenderIndexedScrollSeparator> _liveSeparatorOwners = {};

  bool _separatorModeActive = false;

  final Map<int, int> _registrationCounts = {};

  @visibleForTesting
  int registrationCountFor(int index) => _registrationCounts[index] ?? 0;

  double _leadingAxisPadding = 0.0;

  double _precedingScrollExtent = 0.0;

  @visibleForTesting
  double get leadingAxisPaddingForTesting => _leadingAxisPadding;

  @visibleForTesting
  double get precedingScrollExtentForTesting => _precedingScrollExtent;

  @visibleForTesting
  bool get isReversedForTesting => _isReversed;

  void _registerSize(
    int index,
    Size size,
    _RenderIndexedScrollItem owner,
    int? physicalSliverIndex,
    double leadingAxisPadding,
    double precedingScrollExtent,
    bool hasFingerprintSnapshot,
    Object? fingerprintSnapshot,
  ) {
    _sizes[index] = size;
    _leadingAxisPadding = leadingAxisPadding;
    _precedingScrollExtent = precedingScrollExtent - leadingAxisPadding;
    if (hasFingerprintSnapshot) {
      _fingerprints[index] = fingerprintSnapshot;
    } else {
      _fingerprints.remove(index);
    }
    _registrationCounts[index] = (_registrationCounts[index] ?? 0) + 1;
    _liveOwners[index] = owner;
    if (physicalSliverIndex != null) {
      _lastPhysicalSlots[index] = physicalSliverIndex;
    } else {
      _lastPhysicalSlots.remove(index);
    }
  }

  final Map<int, int> _lastPhysicalSlots = {};

  bool _matchesExpectedSlot(int logicalIndex, int physicalSliverIndex) {
    if (!_separatorModeActive) {
      return physicalSliverIndex == logicalIndex;
    }
    return physicalSliverIndex == 2 * logicalIndex;
  }

  void _unregisterLiveOwner(_RenderIndexedScrollItem owner,
      {required int index}) {
    if (_liveOwners[index] == owner) {
      _liveOwners.remove(index);
    }
  }

  void _registerSeparatorSize(
      int index, Size size, _RenderIndexedScrollSeparator owner) {
    final existingOwner = _liveSeparatorOwners[index];
    if (existingOwner != null && existingOwner != owner) {
      throw StateError(
        'Two different separator(index: $index, ...) registrations were '
        'found for the same index. Each logical index must have at most '
        'one separator; check separatorBuilder for a duplicate index $index.',
      );
    }
    _separatorModeActive = true;
    _separatorSizes[index] = size;
    _liveSeparatorOwners[index] = owner;
  }

  void _unregisterLiveSeparatorOwner(_RenderIndexedScrollSeparator owner,
      {required int index}) {
    if (_liveSeparatorOwners[index] == owner) {
      _liveSeparatorOwners.remove(index);
    }
  }

  bool _hasCompletePrefix(int targetItemIndex) {
    for (int i = 0; i <= targetItemIndex; i++) {
      if (!_sizes.containsKey(i)) {
        return false;
      }
    }
    return true;
  }

  double _prefixExtentBefore(int index) {
    var result = 0.0;
    for (var i = 0; i < index; i++) {
      result += _extentOf(_sizeOrThrow(i)) + _separatorExtentBetween(i);
    }
    return result;
  }

  int? _genuineGapBelow(int targetItemIndex) {
    int? firstMissing;
    for (int i = 0; i <= targetItemIndex; i++) {
      if (!_sizes.containsKey(i)) {
        firstMissing = i;
        break;
      }
    }
    if (firstMissing == null) {
      return null;
    }
    for (int i = firstMissing + 1; i <= targetItemIndex; i++) {
      if (_sizes.containsKey(i)) {
        return firstMissing;
      }
    }
    return null;
  }

  Size _sizeOrThrow(int index) {
    final size = _sizes[index];
    if (size == null) {
      throw StateError(
        'Missing measurement for index $index; watch() indices must be '
        'contiguous from 0.',
      );
    }
    return size;
  }

  double _separatorExtentBetween(int index) {
    if (!_separatorModeActive) {
      return 0.0;
    }
    final size = _separatorSizes[index];
    if (size == null) {
      throw StateError(
        'Missing separator for index $index; separator(index: $index) must '
        'be registered because item $index and item ${index + 1} are both '
        'known to exist (this is not the legitimate "no separator after the '
        'last item" case). Call separator(index: $index, child: ...) in '
        'separatorBuilder, or separator(index: $index, child: const '
        'SizedBox()) if this separator is intentionally empty.',
      );
    }
    return _extentOf(size);
  }

  double _rowExtentOrThrow(int index, ScrollAlignmentTarget alignmentTarget) {
    final rowSize = _sizeOrThrow(index);
    if (alignmentTarget == ScrollAlignmentTarget.row) {
      return _extentOf(rowSize);
    }
    if (!_separatorModeActive) {
      throw StateError(
        'alignmentTarget: ScrollAlignmentTarget.item requires separator() '
        'to have been used for this list (the ListView.separated form -- '
        'see separator()\'s Dartdoc). This list never registered a '
        'separator, so there is nothing for ScrollAlignmentTarget.item to '
        'isolate the item from; use the default ScrollAlignmentTarget.row '
        'instead.',
      );
    }
    return _extentOf(rowSize);
  }

  void _checkNoWatchIndexMismatch(int targetItemIndex) {
    for (int i = 0; i <= targetItemIndex; i++) {
      final physicalIndex = _lastPhysicalSlots[i];
      if (physicalIndex != null && !_matchesExpectedSlot(i, physicalIndex)) {
        throw StateError(
          'watch(index: $i) does not match its row\'s actual physical '
          'position ($physicalIndex) in the sliver. watch(index:) must equal '
          'the position ListView.builder passes to itemBuilder, not a '
          'stable record id — see the "Index continuity contract" section '
          'of watch()\'s Dartdoc. If the data was reordered, pass the new '
          'physical positions to watch() and call invalidateMeasurements(); '
          'invalidation alone does not fix a mismatched watch(index:).',
        );
      }
    }
  }

  void _checkNoOrphanSeparators() {
    for (final entry in _separatorSizes.entries) {
      if (!_sizes.containsKey(entry.key)) {
        throw StateError(
          'separator(index: ${entry.key}) was registered, but watch(index: '
          '${entry.key}) was not -- a separator must follow an item that '
          'this list actually builds. Either add watch(index: ${entry.key}, '
          'child: ...) for the corresponding row in itemBuilder, or remove '
          'the separator(index: ${entry.key}, ...) call from separatorBuilder '
          'if index ${entry.key} is not a real row.',
        );
      }
    }
  }

  double _clampToBounds(double pixels) {
    if (!position.hasContentDimensions) {
      return pixels;
    }
    return pixels.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  double _finitePrecedingScrollExtentOrThrow() {
    if (!_precedingScrollExtent.isFinite) {
      throw StateError(
        'Cannot scroll to an indexed item because a sliver with an unknown '
        'number of children appears before this list. Its preceding scroll '
        'extent is infinite, so this list has no finite scroll offset. Give '
        'the preceding sliver a childCount or place the indexed list before it.',
      );
    }
    return _precedingScrollExtent;
  }

  void _checkSearchCanReachIndexedListOrThrow() {
    if (!_precedingScrollExtent.isFinite ||
        (_sizes.isEmpty &&
            position.hasContentDimensions &&
            !position.maxScrollExtent.isFinite)) {
      throw StateError(
        'Cannot scroll to an indexed item because a sliver with an unknown '
        'number of children appears before this list. Its preceding scroll '
        'extent is infinite, so this list has no finite scroll offset. Give '
        'the preceding sliver a childCount or place the indexed list before it.',
      );
    }
  }

  bool _userDragging = false;

  void _notifyUserGestureStart() {
    _userDragging = true;
    final operationId = _activeOperationId;
    if (operationId != null) {
      _userGestureCancelledOperationId = operationId;
      _currentOperationId++;
    }
  }

  void _notifyUserGestureEnd() => _userDragging = false;

  void _checkOperationLive(
    int myOperationId,
    double scrollToIndex,
    _OperationFingerprintSnapshot? fingerprintSnapshot,
  ) {
    if (_currentOperationId != myOperationId) {
      if (_disposed) {
        throw ScrollCancelledException(
            ScrollCancelReason.disposed, scrollToIndex);
      }
      if (_invalidatedOperationId == myOperationId) {
        throw ScrollCancelledException(
            ScrollCancelReason.dataInvalidated, scrollToIndex);
      }
      if (_explicitlyCancelledOperationId == myOperationId) {
        throw ScrollCancelledException(
            ScrollCancelReason.explicitCancel, scrollToIndex);
      }
      if (_userGestureCancelledOperationId == myOperationId) {
        throw ScrollCancelledException(
            ScrollCancelReason.userGesture, scrollToIndex);
      }
      throw ScrollCancelledException(
          ScrollCancelReason.superseded, scrollToIndex);
    }
    if (!hasClients || positions.isEmpty) {
      throw ScrollCancelledException(
          ScrollCancelReason.detached, scrollToIndex);
    }
    if (_userDragging) {
      throw ScrollCancelledException(
          ScrollCancelReason.userGesture, scrollToIndex);
    }
    if (_hasOperationDataChanged(fingerprintSnapshot)) {
      _stopCoasting();
      _invalidatedOperationId = myOperationId;
      _currentOperationId++;
      throw ScrollCancelledException(
          ScrollCancelReason.dataInvalidated, scrollToIndex);
    }
  }

  _OperationFingerprintSnapshot? _captureOperationFingerprintSnapshot(
    int targetItemIndex,
    int? itemCountSnapshot,
    int? laidOutRangeMax,
  ) {
    final fingerprintCallback = contentFingerprint;
    if (fingerprintCallback == null || itemCountSnapshot == null) {
      return null;
    }
    var corridorHiIndex = laidOutRangeMax == null
        ? targetItemIndex
        : (laidOutRangeMax > targetItemIndex
            ? laidOutRangeMax
            : targetItemIndex);
    final highestValidIndex = itemCountSnapshot - 1;
    if (corridorHiIndex > highestValidIndex) {
      corridorHiIndex = highestValidIndex;
    }
    return _OperationFingerprintSnapshot(
      targetItemIndex: targetItemIndex,
      corridorHiIndex: corridorHiIndex,
      fingerprints:
          List<Object?>.generate(corridorHiIndex + 1, fingerprintCallback),
    );
  }

  bool _hasOperationDataChanged(_OperationFingerprintSnapshot? snapshot) {
    if (snapshot == null) {
      return false;
    }
    final itemCountCallback = itemCount!;
    final currentItemCount = itemCountCallback();
    if (snapshot.targetItemIndex >= currentItemCount ||
        snapshot.corridorHiIndex >= currentItemCount) {
      return true;
    }
    final fingerprintCallback = contentFingerprint!;
    for (int index = 0; index <= snapshot.corridorHiIndex; index++) {
      if (fingerprintCallback(index) != snapshot.fingerprints[index]) {
        return true;
      }
    }
    return false;
  }

  void _clearActiveOperation(int myOperationId) {
    if (_activeOperationId == myOperationId) {
      _activeOperationId = null;
    }
  }

  /// Stops the active [scrollTo] operation, if any.
  void cancelScroll() {
    final operationId = _activeOperationId;
    if (operationId == null) {
      return;
    }
    _stopCoasting();
    _explicitlyCancelledOperationId = operationId;
    _currentOperationId++;
  }

  void _stopCoasting() {
    if (!hasClients || positions.isEmpty) {
      return;
    }
    position.jumpTo(position.pixels);
  }

  /// Clears cached measurements after a size-affecting layout or data change.
  void invalidateMeasurements() {
    final operationId = _activeOperationId;
    if (operationId != null) {
      _stopCoasting();
      _invalidatedOperationId = operationId;
      _currentOperationId++;
    }

    _resetMeasurementCache();
  }

  void _resetMeasurementCache() {
    _sizes.clear();
    _fingerprints.clear();
    _lastPhysicalSlots.clear();
    _separatorSizes.clear();
    _measurementGeneration++;

    for (final owner in _liveOwners.values) {
      owner.invalidateMeasurement();
    }
    for (final owner in _liveSeparatorOwners.values) {
      owner.invalidateMeasurement();
    }
  }

  bool _hasFingerprintMismatchInPrefix(
    _OperationFingerprintSnapshot? fingerprintSnapshot,
  ) {
    if (fingerprintSnapshot == null) {
      return false;
    }

    for (int i = 0; i <= fingerprintSnapshot.corridorHiIndex; i++) {
      if (!hasFingerprintFor(i)) {
        return true;
      }
      if (fingerprintFor(i) != fingerprintSnapshot.fingerprints[i]) {
        return true;
      }
    }
    return false;
  }

  double? _anchoredPriorExtent(int itemIndex) {
    int? anchorIndex;
    double? anchorOffset;
    for (final index in _liveOwners.keys) {
      final offset = _sliverLayoutOffsetOf(index);
      if (offset == null) continue;
      if (anchorIndex == null ||
          (index - itemIndex).abs() < (anchorIndex - itemIndex).abs()) {
        anchorIndex = index;
        anchorOffset = offset;
      }
    }
    if (anchorIndex == null || anchorOffset == null) return null;

    if (!_geometryAgreesWithCache(anchorIndex)) return null;

    var total = anchorOffset;
    if (itemIndex >= anchorIndex) {
      for (var i = anchorIndex; i < itemIndex; i++) {
        if (!_sizes.containsKey(i)) return null;
        total += _extentOf(_sizeOrThrow(i)) + _separatorExtentBetween(i);
      }
    } else {
      for (var i = itemIndex; i < anchorIndex; i++) {
        if (!_sizes.containsKey(i)) return null;
        total -= _extentOf(_sizeOrThrow(i)) + _separatorExtentBetween(i);
      }
    }
    return total;
  }

  bool _geometryAgreesWithCache(int anchorIndex) {
    if (anchorIndex > 0 && !_hasCompletePrefix(anchorIndex - 1)) return false;
    final offset = _sliverLayoutOffsetOf(anchorIndex);
    if (offset == null) return false;
    final expected = _leadingAxisPadding + _prefixExtentBefore(anchorIndex);
    return (expected - offset).abs() <= _alreadyAtTargetTolerancePixels;
  }

  double? _sliverLayoutOffsetOf(int index) {
    final owner = _liveOwners[index];
    if (owner == null || !owner.attached) return null;
    for (RenderObject? node = owner; node != null; node = node.parent) {
      final pd = node.parentData;
      if (pd is SliverMultiBoxAdaptorParentData) {
        final physicalIndex = pd.index;
        if (physicalIndex == null) return null;
        return _matchesExpectedSlot(index, physicalIndex)
            ? pd.layoutOffset
            : null;
      }
    }
    return null;
  }

  Future<bool> _alignGeometryWithCache(
    int targetItemIndex,
    int operationId,
    double requestedIndex,
    _OperationFingerprintSnapshot? snapshot,
  ) async {
    final stride = position.viewportDimension + _viewportCacheExtent;
    if (stride <= 0) {
      throw StateError(
        'Cannot walk the fingerprint corridor toward index $targetItemIndex: the viewport has no '
        'usable extent (viewportDimension + cacheExtent <= 0).',
      );
    }

    _checkNoWatchIndexMismatch(targetItemIndex);

    double? lastDistanceToTarget;
    (int, int)? lastRange;
    int? lastRegistrationSum;
    var lastMaterialized = _targetIsMaterialized(targetItemIndex);
    var stalledSteps = 0;

    bool progressed() {
      final distance = (_targetPixelsEstimateForStallCheck(targetItemIndex) -
              position.pixels)
          .abs();
      final range = _laidOutIndexRange;
      final registrationSum =
          _corridorRegistrationSum(targetItemIndex, snapshot);
      final materialized = _targetIsMaterialized(targetItemIndex);

      var madeProgress = false;
      if (lastDistanceToTarget == null || distance < lastDistanceToTarget!) {
        madeProgress = true;
      }
      if (!madeProgress && lastRange != null && range != null) {
        final rangeAdvancedTowardTarget = targetItemIndex < range.$1
            ? range.$1 < lastRange!.$1
            : targetItemIndex > range.$2
                ? range.$2 > lastRange!.$2
                : true;
        if (rangeAdvancedTowardTarget) {
          madeProgress = true;
        }
      } else if (!madeProgress && lastRange == null && range != null) {
        madeProgress = true;
      }
      if (!madeProgress &&
          lastRegistrationSum != null &&
          registrationSum != lastRegistrationSum) {
        madeProgress = true;
      }
      if (!madeProgress && !lastMaterialized && materialized) {
        madeProgress = true;
      }

      lastDistanceToTarget = distance;
      lastRange = range;
      lastRegistrationSum = registrationSum;
      lastMaterialized = materialized;
      return madeProgress;
    }

    progressed();

    var sawBelowTargetMismatch = false;

    while (true) {
      final range = _laidOutIndexRange;

      final nextMismatch = _firstCorridorMismatch(snapshot);
      if (nextMismatch != null && nextMismatch < targetItemIndex) {
        sawBelowTargetMismatch = true;
      }
      if (nextMismatch == null && _targetIsMaterialized(targetItemIndex)) {
        return sawBelowTargetMismatch;
      }

      var stepAdvancedPosition = true;

      if (nextMismatch != null) {
        final onScreen = range != null &&
            nextMismatch >= range.$1 &&
            nextMismatch <= range.$2;
        if (onScreen) {
          final registrationsBefore = registrationCountFor(nextMismatch);
          _liveOwners[nextMismatch]?.invalidateMeasurement();
          await WidgetsBinding.instance.endOfFrame;
          _checkOperationLive(operationId, requestedIndex, snapshot);
          if (registrationCountFor(nextMismatch) <= registrationsBefore ||
              !hasFingerprintFor(nextMismatch) ||
              fingerprintFor(nextMismatch) !=
                  snapshot!.fingerprints[nextMismatch]) {
            throw StateError(
              'Missing fresh registration for index $nextMismatch after recovery anchor frame; rebuild the list before calling scrollTo again.',
            );
          }
          stepAdvancedPosition =
              false; // an anchor-frame recheck never moves position.pixels.
        } else {
          final forwards = range == null || nextMismatch > range.$2;
          stepAdvancedPosition = await _frontierStepTowards(
              forwards, stride, operationId, requestedIndex, snapshot);
        }
      } else {
        final forwards = range == null || targetItemIndex > range.$2;
        stepAdvancedPosition = await _frontierStepTowards(
            forwards, stride, operationId, requestedIndex, snapshot);
      }

      final madeProgress = progressed();
      if (!madeProgress) {
        stalledSteps++;
        if (stalledSteps >= 2) {
          throw StateError(
            'The fingerprint corridor walk toward index $targetItemIndex stalled: two consecutive steps '
            'produced none of pixel movement toward the target, a live-range edge advance, a fresh '
            'corridor registration, or target materialization. The target row may not exist, or the list '
            'may not be building it. See scrollTo\'s Dartdoc.',
          );
        }
      } else {
        stalledSteps = 0;
      }

      if (!stepAdvancedPosition && !madeProgress) {
        throw StateError(
          'The fingerprint corridor walk toward index $targetItemIndex reached a physical scroll bound '
          'without materializing the target or resolving every corridor mismatch. See scrollTo\'s Dartdoc.',
        );
      }
    }
  }

  Future<void> _reflowFromContentStart(
    int targetItemIndex,
    int operationId,
    double requestedIndex,
    _OperationFingerprintSnapshot? snapshot,
  ) async {
    final stride = position.viewportDimension + _viewportCacheExtent;
    if (stride <= 0) {
      throw StateError(
        'Cannot reflow toward index $targetItemIndex from the list-sliver\'s start: the viewport has no '
        'usable extent (viewportDimension + cacheExtent <= 0).',
      );
    }

    final rowZeroRegistrationsBefore = registrationCountFor(0);

    final contentStart = _clampToBounds(
        _finitePrecedingScrollExtentOrThrow() + _leadingAxisPadding);
    if ((contentStart - position.pixels).abs() >
        _alreadyAtTargetTolerancePixels) {
      position.jumpTo(contentStart);
      _checkOperationLive(operationId, requestedIndex, snapshot);
      await WidgetsBinding.instance.endOfFrame;
      _checkOperationLive(operationId, requestedIndex, snapshot);
    }

    var stalledSteps = 0;
    double? lastDistanceToRowZero;

    while (!_targetIsMaterialized(0)) {
      final distance = (contentStart - position.pixels).abs();
      final priorDistance = lastDistanceToRowZero;
      final madeProgress = priorDistance == null || distance < priorDistance;
      lastDistanceToRowZero = distance;
      if (!madeProgress) {
        stalledSteps++;
        if (stalledSteps >= 2) {
          throw StateError(
            'The absolute reflow toward index $targetItemIndex could not reach row 0: two consecutive '
            'steps made no progress toward the list-sliver\'s own start. See scrollTo\'s Dartdoc.',
          );
        }
      } else {
        stalledSteps = 0;
      }
      if (!await _stepTowards(
          false, stride, operationId, requestedIndex, snapshot)) {
        throw StateError(
          'The absolute reflow toward index $targetItemIndex reached a physical scroll bound before row 0 '
          'materialized. See scrollTo\'s Dartdoc.',
        );
      }
    }

    _liveOwners[0]?.invalidateMeasurement();
    await WidgetsBinding.instance.endOfFrame;
    _checkOperationLive(operationId, requestedIndex, snapshot);
    if (registrationCountFor(0) <= rowZeroRegistrationsBefore ||
        !_targetIsMaterialized(0) ||
        (snapshot != null &&
            0 <= snapshot.corridorHiIndex &&
            (!hasFingerprintFor(0) ||
                fingerprintFor(0) != snapshot.fingerprints[0]))) {
      throw StateError(
        'Missing fresh registration for index 0 after the reflow anchor frame toward index $targetItemIndex; '
        'rebuild the list before calling scrollTo again.',
      );
    }

    final targetRegistrationsBefore = registrationCountFor(targetItemIndex);
    stalledSteps = 0;
    double? lastDistanceToTarget;
    while (!_targetIsMaterialized(targetItemIndex)) {
      final distance = (_targetPixelsEstimateForStallCheck(targetItemIndex) -
              position.pixels)
          .abs();
      final priorDistance = lastDistanceToTarget;
      final madeProgress = priorDistance == null || distance < priorDistance;
      lastDistanceToTarget = distance;
      if (!madeProgress) {
        stalledSteps++;
        if (stalledSteps >= 2) {
          throw StateError(
            'The absolute reflow toward index $targetItemIndex stalled: two consecutive forward steps from '
            'row 0 made no progress toward the target. The target row may not exist, or the list may not '
            'be building it. See scrollTo\'s Dartdoc.',
          );
        }
      } else {
        stalledSteps = 0;
      }
      if (!await _stepTowards(
          true, stride, operationId, requestedIndex, snapshot)) {
        throw StateError(
          'The absolute reflow toward index $targetItemIndex reached a physical scroll bound before the '
          'target materialized. See scrollTo\'s Dartdoc.',
        );
      }
    }

    _liveOwners[targetItemIndex]?.invalidateMeasurement();
    await WidgetsBinding.instance.endOfFrame;
    _checkOperationLive(operationId, requestedIndex, snapshot);
    if (registrationCountFor(targetItemIndex) <= targetRegistrationsBefore ||
        !_targetIsMaterialized(targetItemIndex)) {
      throw StateError(
        'Missing fresh registration for target index $targetItemIndex after the reflow anchor frame; '
        'rebuild the list before calling scrollTo again.',
      );
    }
  }

  double _targetPixelsEstimateForStallCheck(int targetItemIndex) {
    if (_hasCompletePrefix(targetItemIndex)) {
      return _leadingAxisPadding + _prefixExtentBefore(targetItemIndex);
    }
    return targetItemIndex >= ((_laidOutIndexRange?.$1) ?? 0)
        ? double.infinity
        : 0.0;
  }

  int _corridorRegistrationSum(
      int targetItemIndex, _OperationFingerprintSnapshot? snapshot) {
    final hi = snapshot?.corridorHiIndex ??
        (_laidOutIndexRange?.$2 ?? targetItemIndex);
    var sum = 0;
    for (var i = 0; i <= hi; i++) {
      sum += registrationCountFor(i);
    }
    return sum;
  }

  bool _targetIsMaterialized(int targetItemIndex) {
    final owner = _liveOwners[targetItemIndex];
    if (owner == null || !owner.attached) return false;
    final offset = _sliverLayoutOffsetOf(targetItemIndex);
    return offset != null && offset.isFinite;
  }

  int? _firstCorridorMismatch(_OperationFingerprintSnapshot? snapshot) {
    if (snapshot == null) return null;
    for (var i = 0; i <= snapshot.corridorHiIndex; i++) {
      if (!hasFingerprintFor(i)) return i;
      if (fingerprintFor(i) != snapshot.fingerprints[i]) return i;
    }
    return null;
  }

  Future<bool> _stepTowards(
    bool forwards,
    double stride,
    int operationId,
    double requestedIndex,
    _OperationFingerprintSnapshot? snapshot,
  ) async {
    final next =
        _clampToBounds(position.pixels + (forwards ? stride : -stride));
    if ((next - position.pixels).abs() <= _alreadyAtTargetTolerancePixels) {
      return false;
    }
    position.jumpTo(next);
    _checkOperationLive(operationId, requestedIndex, snapshot);
    await WidgetsBinding.instance.endOfFrame;
    _checkOperationLive(operationId, requestedIndex, snapshot);
    return true;
  }

  double? _frontierJumpTarget(
      bool forwards, _OperationFingerprintSnapshot? snapshot) {
    final range = _laidOutIndexRange;
    if (range == null) return null;
    final frontierIndex = forwards ? range.$2 : range.$1;

    final owner = _liveOwners[frontierIndex];
    if (owner == null || !owner.attached) return null;
    final offset = _sliverLayoutOffsetOf(frontierIndex);
    if (offset == null || !offset.isFinite) return null;
    if (snapshot != null &&
        frontierIndex <= snapshot.corridorHiIndex &&
        (!hasFingerprintFor(frontierIndex) ||
            fingerprintFor(frontierIndex) !=
                snapshot.fingerprints[frontierIndex])) {
      return null;
    }

    final base =
        _finitePrecedingScrollExtentOrThrow() + _leadingAxisPadding + offset;

    if (!forwards) return base;
    if (!_sizes.containsKey(frontierIndex)) return null;
    return base +
        _extentOf(_sizeOrThrow(frontierIndex)) +
        _separatorExtentBetween(frontierIndex);
  }

  Future<bool> _frontierStepTowards(
    bool forwards,
    double stride,
    int operationId,
    double requestedIndex,
    _OperationFingerprintSnapshot? snapshot,
  ) async {
    final frontierTarget = _frontierJumpTarget(forwards, snapshot);
    if (frontierTarget != null) {
      final strideTarget = position.pixels + (forwards ? stride : -stride);
      final frontierGoesFurther = forwards
          ? frontierTarget > strideTarget
          : frontierTarget < strideTarget;
      if (frontierGoesFurther) {
        final next = _clampToBounds(frontierTarget);
        if ((next - position.pixels).abs() > _alreadyAtTargetTolerancePixels) {
          position.jumpTo(next);
          _checkOperationLive(operationId, requestedIndex, snapshot);
          await WidgetsBinding.instance.endOfFrame;
          _checkOperationLive(operationId, requestedIndex, snapshot);
          return true;
        }
      }
    }
    return _stepTowards(
        forwards, stride, operationId, requestedIndex, snapshot);
  }

  Future _animateTo(
    double scrollToIndex,
    double scrollPosition,
    double viewportSize,
    double minVisibleIndex,
    Duration duration,
    Curve curve,
    double alignment,
    ScrollAlignmentTarget alignmentTarget,
    int myOperationId, {
    required bool awaitInitialFrame,
    required _OperationFingerprintSnapshot? fingerprintSnapshot,
  }) async {
    try {
      await _runAnimateTo(
        scrollToIndex,
        scrollPosition,
        viewportSize,
        minVisibleIndex,
        duration,
        curve,
        alignment,
        alignmentTarget,
        myOperationId,
        awaitInitialFrame: awaitInitialFrame,
        fingerprintSnapshot: fingerprintSnapshot,
      );
    } finally {
      _clearActiveOperation(myOperationId);
    }
  }

  double get _viewportCacheExtent {
    for (final owner in _liveOwners.values) {
      if (!owner.attached) continue;
      for (RenderObject? node = owner; node != null; node = node.parent) {
        if (node is RenderViewportBase) {
          return node.scrollCacheExtent.style == CacheExtentStyle.viewport
              ? node.scrollCacheExtent.value * position.viewportDimension
              : node.scrollCacheExtent.value;
        }
      }
    }
    return RenderAbstractViewport.defaultCacheExtent;
  }

  (int min, int max)? get _laidOutIndexRange {
    int? lowest;
    int? highest;
    for (final entry in _liveOwners.entries) {
      if (!entry.value.attached) continue;
      final index = entry.key;
      if (lowest == null || index < lowest) lowest = index;
      if (highest == null || index > highest) highest = index;
    }
    return lowest == null ? null : (lowest, highest!);
  }

  Future _runAnimateTo(
    double scrollToIndex,
    double scrollPosition,
    double viewportSize,
    double minVisibleIndex,
    Duration duration,
    Curve curve,
    double alignment,
    ScrollAlignmentTarget alignmentTarget,
    int myOperationId, {
    required bool awaitInitialFrame,
    required _OperationFingerprintSnapshot? fingerprintSnapshot,
  }) async {
    final operationStartPixels = scrollPosition;
    var animateSign = minVisibleIndex > scrollToIndex ? -1 : 1;
    final itemIndex = scrollToIndex.truncate();
    var step = viewportSize * animateSign;
    if (!_hasCompletePrefix(itemIndex)) {
      var offset = scrollPosition;
      if (awaitInitialFrame) {
        await WidgetsBinding.instance.endOfFrame;
        _checkOperationLive(myOperationId, scrollToIndex, fingerprintSnapshot);
        scrollPosition = position.pixels;
        offset = scrollPosition;
      }
      var stalledSteps = 0;
      while (!_hasCompletePrefix(itemIndex)) {
        _checkSearchCanReachIndexedListOrThrow();
        final positionBefore = position.pixels;
        final measuredCountBefore = _sizes.length;

        offset += step;
        position.jumpTo(offset);
        _checkOperationLive(myOperationId, scrollToIndex, fingerprintSnapshot);
        await WidgetsBinding.instance.endOfFrame;
        _checkOperationLive(myOperationId, scrollToIndex, fingerprintSnapshot);

        if (_hasCompletePrefix(itemIndex)) {
          break;
        }

        final atOrPastPhysicalBound = position.hasContentDimensions &&
            (animateSign > 0
                ? position.pixels >= position.maxScrollExtent
                : position.pixels <= position.minScrollExtent);
        final madeProgress = _sizes.length != measuredCountBefore ||
            (position.pixels != positionBefore && !atOrPastPhysicalBound);
        if (madeProgress) {
          stalledSteps = 0;
        } else {
          stalledSteps++;
          if (stalledSteps >= 2) {
            final genuineGap = _genuineGapBelow(itemIndex);
            if (genuineGap != null) {
              throw StateError(
                'Missing measurement for index $genuineGap; watch() indices '
                'must be contiguous from 0.',
              );
            }
            throw RangeError.value(
              scrollToIndex,
              'scrollToIndex',
              'could not be reached; the list ended before this index was '
                  'measured',
            );
          }
        }
      }

      scrollPosition = position.pixels;
    }

    _checkNoWatchIndexMismatch(itemIndex);
    _checkNoOrphanSeparators();

    final corridorDirty = fingerprintSnapshot != null &&
        _hasFingerprintMismatchInPrefix(fingerprintSnapshot);
    var sawBelowTargetMismatch = false;
    if (corridorDirty) {
      sawBelowTargetMismatch = await _alignGeometryWithCache(
          itemIndex, myOperationId, scrollToIndex, fingerprintSnapshot);
      scrollPosition = position.pixels;
      viewportSize = position.viewportDimension;
    }

    final priorItems =
        _anchoredPriorExtent(itemIndex) ?? _prefixExtentBefore(itemIndex);

    var fraction = scrollToIndex - scrollToIndex.truncate();
    var extent = _rowExtentOrThrow(itemIndex, alignmentTarget);
    var effectiveAlignment = _isReversed ? 1.0 - alignment : alignment;
    var alignmentAdjust = -(viewportSize - extent) * effectiveAlignment;
    var targetPixels = _clampToBounds(
      _finitePrecedingScrollExtentOrThrow() +
          _leadingAxisPadding +
          priorItems +
          extent * fraction +
          alignmentAdjust,
    );
    var remaining = (targetPixels - scrollPosition).abs();
    var scrollLimit = viewportSize;
    if ((remaining - scrollLimit) > 0) {
      var jumpingPosition = targetPixels + step * -1;
      position.jumpTo(jumpingPosition);
      _checkOperationLive(myOperationId, scrollToIndex, fingerprintSnapshot);

      await WidgetsBinding.instance.endOfFrame;
      _checkOperationLive(myOperationId, scrollToIndex, fingerprintSnapshot);
    }

    if (!_targetIsMaterialized(itemIndex)) {
      final stride = viewportSize + _viewportCacheExtent;
      var guard = stride > 0 && position.hasContentDimensions
          ? ((position.maxScrollExtent - position.minScrollExtent).abs() /
                      stride)
                  .ceil() +
              2
          : 8;
      var stepsTaken = 0;
      while (!_targetIsMaterialized(itemIndex)) {
        if (stride <= 0 || stepsTaken >= guard) {
          throw StateError(
            'Target index $itemIndex did not materialize after a bounded local approach; '
            'the list may not be building it. See scrollTo\'s Dartdoc.',
          );
        }
        stepsTaken++;
        final forwards = animateSign > 0;
        if (!await _stepTowards(forwards, stride, myOperationId, scrollToIndex,
            fingerprintSnapshot)) {
          throw StateError(
            'Target index $itemIndex did not materialize before the scrollable reached its bound; '
            'see scrollTo\'s Dartdoc.',
          );
        }
      }
      scrollPosition = position.pixels;
      viewportSize = position.viewportDimension;
    }

    if (sawBelowTargetMismatch) {
      await _reflowFromContentStart(
          itemIndex, myOperationId, scrollToIndex, fingerprintSnapshot);
      scrollPosition = position.pixels;
      viewportSize = position.viewportDimension;
    }

    final liveRowStart = _sliverLayoutOffsetOf(itemIndex);
    if (liveRowStart == null) {
      throw StateError(
        'Target index $itemIndex was confirmed materialized but that no longer held when the final leg '
        'tried to read it; this indicates a bug in scrollTo\'s materialization guarantee, not a caller '
        'error.',
      );
    }
    targetPixels = _clampToBounds(
      _finitePrecedingScrollExtentOrThrow() +
          _leadingAxisPadding +
          liveRowStart +
          extent * fraction +
          alignmentAdjust,
    );

    if (targetPixels == operationStartPixels) {
      if (position.pixels != operationStartPixels) {
        position.jumpTo(_clampToBounds(operationStartPixels));
        _checkOperationLive(myOperationId, scrollToIndex, fingerprintSnapshot);
      }
    } else {
      if (position.pixels != operationStartPixels) {
        final distanceFromStart = (targetPixels - operationStartPixels).abs();
        final legStart = distanceFromStart <= viewportSize
            ? operationStartPixels
            : targetPixels + step * -1;
        if ((legStart - position.pixels).abs() >
            _alreadyAtTargetTolerancePixels) {
          position.jumpTo(_clampToBounds(legStart));
          _checkOperationLive(
              myOperationId, scrollToIndex, fingerprintSnapshot);
        }
      }

      if (duration.inMicroseconds == 0) {
        position.jumpTo(targetPixels);
        await WidgetsBinding.instance.endOfFrame;
        _checkOperationLive(myOperationId, scrollToIndex, fingerprintSnapshot);
      } else {
        await position.animateTo(targetPixels,
            duration: duration, curve: curve);
        _checkOperationLive(myOperationId, scrollToIndex, fingerprintSnapshot);
      }
    }
  }

  /// Scrolls to [scrollToIndex].
  ///
  /// Fractional indices position within an item. [alignment] is in the
  /// inclusive range `0..1`; physical scroll bounds take priority.
  ///
  /// Throws [RangeError] for an unreachable index, [ArgumentError] for invalid
  /// arguments, [StateError] for an unsupported list state, and
  /// [ScrollCancelledException] when the operation is interrupted.
  Future<void> scrollTo(
    double scrollToIndex, {
    Duration? duration,
    Curve? curve,
    double alignment = 0.0,
    ScrollAlignmentTarget alignmentTarget = ScrollAlignmentTarget.row,
  }) async {
    if (scrollToIndex.isNaN || scrollToIndex.isInfinite) {
      throw ArgumentError.value(
        scrollToIndex,
        'scrollToIndex',
        'must be a finite number',
      );
    }
    if (scrollToIndex < 0) {
      throw RangeError.value(
        scrollToIndex,
        'scrollToIndex',
        'must not be negative',
      );
    }
    if (duration != null && duration.isNegative) {
      throw ArgumentError.value(
        duration,
        'duration',
        'must not be negative',
      );
    }
    if (alignment.isNaN || alignment < 0 || alignment > 1) {
      throw ArgumentError.value(
        alignment,
        'alignment',
        'must be within [0, 1]',
      );
    }

    int? itemCountSnapshot;
    final itemCountCallback = itemCount;
    if (itemCountCallback != null) {
      itemCountSnapshot = itemCountCallback();
      if (scrollToIndex.truncate() >= itemCountSnapshot) {
        throw RangeError.value(
          scrollToIndex,
          'scrollToIndex',
          'must be less than itemCount() ($itemCountSnapshot)',
        );
      }
    }

    if (!hasClients || positions.isEmpty) {
      throw StateError(
        'scrollTo requires an attached ScrollPosition, but this controller '
        'has no clients.',
      );
    }
    if (positions.length != 1) {
      throw StateError(
        'scrollTo requires exactly one attached ScrollPosition, but found '
        '${positions.length}. IndexedScrollController supports a single '
        'ListView.builder only, vertical or horizontal.',
      );
    }

    if (!position.hasViewportDimension || !position.hasPixels) {
      throw StateError(
        'scrollTo() called before the first layout — viewport metrics are '
        'not yet available; call it after the initial frame, not from '
        'onAttach.',
      );
    }

    if (_userDragging) {
      throw ScrollCancelledException(
          ScrollCancelReason.userGesture, scrollToIndex);
    }

    final myOperationId = ++_currentOperationId;
    _activeOperationId = myOperationId;

    try {
      final targetItemIndex = scrollToIndex.truncate();
      final fingerprintSnapshot = _captureOperationFingerprintSnapshot(
          targetItemIndex, itemCountSnapshot, _laidOutIndexRange?.$2);

      var viewportSize = position.viewportDimension;
      var scrollPosition = position.pixels;
      var index = 0.0;
      var minVisibleIndex = 0.0;

      var hasCompletePrefix = _hasCompletePrefix(targetItemIndex);

      final corridorDirty = hasCompletePrefix &&
          fingerprintSnapshot != null &&
          _hasFingerprintMismatchInPrefix(fingerprintSnapshot);
      final needsMaterialization =
          hasCompletePrefix && !_targetIsMaterialized(targetItemIndex);
      final canTakeFastPath =
          hasCompletePrefix && !corridorDirty && !needsMaterialization;

      if (!hasCompletePrefix) {
        if (scrollPosition != 0.0) {
          position.jumpTo(0.0);
          scrollPosition = position.pixels;
        }
      } else {
        _checkNoWatchIndexMismatch(targetItemIndex);
        _checkNoOrphanSeparators();

        var scrolledExtent = 0.0;
        var minFraction = 0.0;
        var isMinFound = false;
        while (index < _sizes.length) {
          var extent = _extentOf(_sizeOrThrow(index.toInt()));
          if (scrolledExtent + extent > scrollPosition && !isMinFound) {
            minVisibleIndex = index;
            minFraction = (scrollPosition - scrolledExtent) / extent;
            minVisibleIndex += minFraction;
            isMinFound = true;
            break;
          }

          scrolledExtent += extent + _separatorExtentBetween(index.toInt());
          index += 1.0;
        }

        if (canTakeFastPath) {
          final liveRowStart = _sliverLayoutOffsetOf(targetItemIndex);
          if (liveRowStart != null) {
            var fraction = scrollToIndex - targetItemIndex;
            var extent = _rowExtentOrThrow(targetItemIndex, alignmentTarget);
            var effectiveAlignment = _isReversed ? 1.0 - alignment : alignment;
            var alignmentAdjust = -(viewportSize - extent) * effectiveAlignment;
            var targetPixels = _finitePrecedingScrollExtentOrThrow() +
                _leadingAxisPadding +
                liveRowStart +
                extent * fraction +
                alignmentAdjust;
            if ((targetPixels - scrollPosition).abs() <=
                _alreadyAtTargetTolerancePixels) {
              _checkOperationLive(
                  myOperationId, scrollToIndex, fingerprintSnapshot);
              return;
            }
          }
        }
      }

      return await _animateTo(
        scrollToIndex,
        scrollPosition,
        viewportSize,
        minVisibleIndex,
        duration ?? scrollDuration,
        curve ?? this.curve,
        alignment,
        alignmentTarget,
        myOperationId,
        awaitInitialFrame: !hasCompletePrefix,
        fingerprintSnapshot: fingerprintSnapshot,
      );
    } finally {
      _clearActiveOperation(myOperationId);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _currentOperationId++;
    super.dispose();
  }
}
