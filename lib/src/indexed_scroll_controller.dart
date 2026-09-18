import 'dart:async';
import 'dart:collection' show UnmodifiableMapView;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

part 'indexed_scroll_item.dart';
part 'indexed_scroll_gesture_detector.dart';

/// Why an in-flight [IndexedScrollController.scrollTo] was cancelled.
///
/// Each value identifies the source of the cancellation.
enum ScrollCancelReason {
  /// A newer [IndexedScrollController.scrollTo] call superseded this one
  /// before it finished.
  superseded,

  /// The caller explicitly cancelled the in-flight scroll via
  /// `cancelScroll()`.
  explicitCancel,

  /// The underlying data changed and measurements were invalidated via
  /// `invalidateMeasurements()`, so the target index may no longer refer
  /// to the same logical row.
  dataInvalidated,

  /// The controller detached from its [ScrollPosition] while a scroll was
  /// in flight.
  detached,

  /// The controller was disposed while a scroll was in flight.
  disposed,

  /// The user began dragging the list while a scroll was in flight, so the
  /// scroll yielded control of the position to the gesture.
  ///
  /// Unlike every other reason here, this one is raised by the controller
  /// itself rather than by an explicit caller action: a user's finger always
  /// outranks a programmatic scroll, and the two cannot share the position
  /// (see [IndexedScrollGestureDetector]).
  userGesture,
}

/// Thrown when [IndexedScrollController.scrollTo] is cancelled.
///
/// Inspect [reason] to determine why the operation stopped.
class ScrollCancelledException implements Exception {
  /// Why the scroll was cancelled.
  final ScrollCancelReason reason;

  /// The index that was requested via `scrollTo`, for diagnostics.
  final double requestedIndex;

  /// Creates a cancellation error for [requestedIndex].
  const ScrollCancelledException(this.reason, this.requestedIndex);

  @override
  String toString() => 'ScrollCancelledException(reason: $reason, requestedIndex: $requestedIndex)';
}

/// Scrolls a single non-reversed [ListView.builder] to an item by its
/// physical index.
///
/// Wrap every item with [watch]. Item sizes are measured as they are laid out,
/// allowing [scrollTo] to reach measured and unmeasured indices. The supported
/// list may be vertical or horizontal and must have one attached position.
class IndexedScrollController extends ScrollController {
  /// Default duration used by [scrollTo] when its `duration` is omitted.
  final Duration scrollDuration;

  /// Default curve used by [scrollTo] when its `curve` is omitted.
  final Curve curve;

  /// Measured sizes by logical index, summed linearly by [scrollTo] to
  /// locate a target offset.
  ///
  /// The map is intentionally summed linearly. The sequential measurement
  /// pass required for unmeasured rows is the dominant cost of a long jump,
  /// so a more complex prefix-sum structure would not improve that path.
  final Map<int, Size> _sizes = {};

  /// Live, unmodifiable view of the measured item sizes, for testing only.
  @visibleForTesting
  Map<int, Size> get measurementsSizes => UnmodifiableMapView(_sizes);

  static const double _alreadyAtTargetTolerancePixels = 1.0;

  /// Returns [size]'s extent along the attached position's scroll axis:
  /// [Size.height] for [Axis.vertical], [Size.width] for [Axis.horizontal].
  ///
  /// Every place that used to read `size.height` directly must instead call
  /// this, so a horizontal `ListView.builder` (items of equal height but
  /// varying width) sums the axis that actually determines `position.pixels`
  /// instead of a dimension that is constant and therefore wrong.
  double _extentOf(Size size) => position.axis == Axis.horizontal ? size.width : size.height;

  /// Monotonically increasing id of the current owner of the position.
  ///
  /// Each [scrollTo] call claims a new id, which supersedes whatever call
  /// was previously active — a supersededed call notices the mismatch after
  /// its next `await` and cancels itself rather than continuing to drive
  /// the position. [dispose] also bumps this so an in-flight search
  /// cancels instead of touching a position that may be mid-teardown; see
  /// [_disposed], which distinguishes that case from an ordinary
  /// supersession so the two report different [ScrollCancelReason]s.
  int _currentOperationId = 0;

  /// Set by [dispose] before it bumps [_currentOperationId], so a stale
  /// in-flight search can tell "disposed" apart from "a newer scrollTo call
  /// superseded me" even though both invalidate the id the same way.
  bool _disposed = false;

  /// Id of the [scrollTo] call currently driving the position, or `null` if
  /// none is in flight. Set when a call claims [_currentOperationId] and
  /// cleared once that call's [_animateTo] returns or throws — including a
  /// throw caused by that same call being superseded, so a new call's id
  /// never lingers here as "active" after it has already lost ownership.
  ///
  /// This exists only so [cancelScroll] can tell "there is an operation to
  /// cancel" apart from "nothing is running" without reusing
  /// [_currentOperationId] for that purpose — that field's only job is
  /// supersession, and overloading it here would conflate two different
  /// questions ("what is the latest id" vs "is a call still in flight").
  int? _activeOperationId;

  /// Set by [cancelScroll] to the operation id it just cancelled, so that
  /// operation's next [_checkOperationLive] check-in reports
  /// [ScrollCancelReason.explicitCancel] instead of the
  /// [ScrollCancelReason.superseded] a plain id mismatch would otherwise
  /// imply. [cancelScroll] cancels by bumping [_currentOperationId] — the
  /// same mechanism a superseding [scrollTo] call uses — so this field is
  /// the only thing that distinguishes the two reasons at the point where
  /// the stale call actually throws.
  int? _explicitlyCancelledOperationId;

  /// Set by [invalidateMeasurements] to the operation id it just cancelled,
  /// mirroring [_explicitlyCancelledOperationId] but for
  /// [ScrollCancelReason.dataInvalidated] instead of
  /// [ScrollCancelReason.explicitCancel]. Kept as a separate field rather
  /// than reusing [_explicitlyCancelledOperationId] because the two reasons
  /// are observably different to callers and must never be conflated: a
  /// caller catching [ScrollCancelReason.dataInvalidated] specifically to
  /// decide whether to retry the same logical index needs that decision to
  /// be correct, and retrying after [ScrollCancelReason.explicitCancel]
  /// would be wrong (the caller itself asked to stop).
  int? _invalidatedOperationId;

  /// Set by [_notifyUserGestureStart] to the operation id it just cancelled,
  /// mirroring [_explicitlyCancelledOperationId] but for
  /// [ScrollCancelReason.userGesture]. Kept separate for the same reason
  /// those two are: a caller that retries on supersession must not also
  /// retry when the user themselves took over the list, which would yank
  /// the position back out from under the finger that just moved it.
  int? _userGestureCancelledOperationId;

  /// Monotonically increasing generation of [_sizes].
  ///
  /// Bumped by [invalidateMeasurements] alongside clearing [_sizes]. Nothing
  /// in this class currently reads it for correctness — [_currentOperationId]
  /// already forces any in-flight [scrollTo] to cancel and any future call to
  /// re-derive its prefix sums from a freshly cleared [_sizes], so a
  /// generation counter is not required to make [scrollTo] itself correct
  /// after invalidation. It exists only as an observable "measurements
  /// changed" signal for callers/tests that want to confirm invalidation
  /// happened without depending on [_sizes] identity or contents (e.g.
  /// distinguishing "invalidated to an empty list" from "never invalidated
  /// and coincidentally empty").
  int _measurementGeneration = 0;

  /// Number of times [invalidateMeasurements] has reset the cache.
  ///
  /// For testing only.
  @visibleForTesting
  int get measurementGeneration => _measurementGeneration;

  /// Creates a controller for indexed scrolling.
  ///
  /// The remaining arguments have the same meaning as [ScrollController].
  IndexedScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    super.onAttach,
    super.onDetach,
    required this.scrollDuration,
    this.curve = Curves.linear,
  });

  /// Wraps a list item and records its laid-out size under [index].
  ///
  /// [index] must equal the physical index passed to `itemBuilder`. Indices must
  /// form a contiguous range starting at zero. After inserting, deleting,
  /// reordering, resizing items, or changing the scroll direction, call
  /// [invalidateMeasurements].
  Widget watch({required int index, required Widget child}) {
    return IndexedScrollItem(controller: this, index: index, child: child);
  }

  /// Tracks, per logical index, which [_RenderIndexedScrollItem] most
  /// recently registered a size for it.
  ///
  /// This is separate from [_sizes] because the two have different
  /// lifetimes: [_sizes] is the durable measurement history (an unmounted
  /// row keeps its last known height so prefix sums stay stable), while
  /// this map is "who currently owns the live registration for this index"
  /// — used only so [_unregisterLiveOwner] can tell a real unmount apart
  /// from a row that simply moved to a different index. Keying by object
  /// identity (not `==`) matters because two different render objects are
  /// never meant to be treated as the same owner even if they happened to
  /// hold equal field values.
  final Map<int, _RenderIndexedScrollItem> _liveOwners = {};

  /// Logical indices whose most recent registration disagreed with their
  /// row's actual physical position in the sliver, keyed by the logical
  /// index that was passed to `watch(index:)`.
  ///
  /// `watch(index:)` must equal the physical
  /// position the sliver assigns the row (its
  /// `SliverMultiBoxAdaptorParentData.index`). A caller that instead passes
  /// a stable record id, or otherwise reorders `watch()` indices without
  /// making them track physical slot order, produces a full, contiguous
  /// `0..n-1` key set in [_sizes] that the continuity check
  /// (`_sizeOrThrow`/`_hasCompletePrefix`) cannot distinguish from a correct
  /// registration -- every key is present, just attached to the wrong row
  /// This map records
  /// every such mismatch observed since the row was last (re)measured, so
  /// [scrollTo] can refuse to complete successfully once it depends on an
  /// index found here, instead of silently summing an offset that does not
  /// match the physical screen. A `null` physical index (row not parented by
  /// a supported multi-box sliver, e.g. not yet attached) is not treated as
  /// a mismatch -- there is nothing to compare against yet.
  final Map<int, int> _watchIndexMismatches = {};

  void _registerSize(
    int index,
    Size size,
    _RenderIndexedScrollItem owner,
    int? physicalSliverIndex,
  ) {
    _sizes[index] = size;
    _liveOwners[index] = owner;
    if (physicalSliverIndex != null && physicalSliverIndex != index) {
      _watchIndexMismatches[index] = physicalSliverIndex;
    } else {
      _watchIndexMismatches.remove(index);
    }
  }

  /// Removes the live-registration entry for [owner] at [index], but only if
  /// [owner] is still that index's registered owner (identity check, not
  /// `==`).
  ///
  /// [index] is passed explicitly, rather than read from [owner.index],
  /// because this is called from two different moments with two different
  /// notions of "current index":
  ///
  /// * [_RenderIndexedScrollItem.detach] calls this with the object's index
  ///   at detach time (an ordinary unmount, e.g. the row scrolled out of the
  ///   viewport).
  /// * The `index`/`controller` setters call this with the object's
  ///   OLD index/controller, *before* either field is updated, when
  ///   [IndexedScrollItem.updateRenderObject] reassigns an already-attached
  ///   row to a new index or a new controller. Without this, a row moved
  ///   from index 3 to index 7 (or from controller A to controller B) would
  ///   leave a stale `_liveOwners[3]` entry that nothing could ever remove:
  ///   [detach] only ever consults the object's CURRENT index/controller at
  ///   the time it fires, never a prior one, so the old entry would survive
  ///   for as long as the (old) controller lives — a leak which
  ///   also applies within a single controller across an index-only change.
  ///
  /// This intentionally leaves [_sizes] untouched in both cases — an
  /// ordinary reassignment or unmount must not erase the row's contributed
  /// height, or every prefix-sum computation that depends on it would go
  /// stale the moment the row moves or leaves the viewport. It also guards
  /// against clobbering a *different* render object's fresher ownership of
  /// the same index: if some other render object has since taken over
  /// [index], this call must not remove that other owner's entry.
  void _unregisterLiveOwner(_RenderIndexedScrollItem owner, {required int index}) {
    if (_liveOwners[index] == owner) {
      _liveOwners.remove(index);
    }
  }

  /// Whether [_sizes] currently holds a size for every logical index from 0
  /// up to and including [targetItemIndex].
  ///
  /// After [invalidateMeasurements] clears [_sizes], a target index
  /// that happens to already be live (e.g. still on screen) can end up back
  /// in [_sizes] the moment its row relays out — while indices below it that
  /// are off-screen remain missing. Trusting [_sizes] on the strength of
  /// `containsKey(targetItemIndex)` alone
  /// the [_runAnimateTo] search-skip condition both did) can silently sum a
  /// prefix with a hole in it via [_sizeOrThrow], or skip the search pass
  /// entirely while the prefix is still incomplete. This full-prefix check
  /// is the gate [scrollTo] uses to decide whether it may trust [_sizes] as
  /// -is, or whether it must fall back to an internal search-from-0 pass
  /// (see [scrollTo]'s Dartdoc "Recovery after invalidation" section).
  bool _hasCompletePrefix(int targetItemIndex) {
    for (int i = 0; i <= targetItemIndex; i++) {
      if (!_sizes.containsKey(i)) {
        return false;
      }
    }
    return true;
  }

  /// Returns the lowest index in `0..targetItemIndex` missing from [_sizes]
  /// that also has some *higher* index (up to and including
  /// [targetItemIndex]) already present — i.e. a genuine hole in the
  /// contiguous-`watch()`-indices contract, not merely "the search hasn't
  /// reached this far yet". Returns `null` if no such hole exists.
  ///
  /// The sequential search-from-0 loop in [_runAnimateTo] stalls
  /// identically at a stable physical edge whether the true cause is "the
  /// list has fewer physical rows than [scrollToIndex] requires" (a real
  /// out-of-bounds target — [RangeError])
  /// or "the caller's `watch()` indices skip a logical index entirely" (a
  /// [StateError] naming the missing index, the contiguous-index
  /// contract). Both look the same from progress-tracking alone: the
  /// scrollable stops moving and no new size appears. This scan
  /// distinguishes them by checking, once the search has genuinely stalled,
  /// whether everything reachable at or below [targetItemIndex] has already
  /// been measured *except* for a gap that something beyond it is already
  /// known to have skipped past — which can only happen if the missing index
  /// was never registered at all (the "50,51,52 without 3-49" case),
  /// because a merely-not-yet-reached tail index cannot have anything measured
  /// above it.
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

  /// Returns the measured size for [index], or throws a [StateError] naming
  /// the missing index.
  ///
  /// `watch()` requires callers to register a contiguous run of logical
  /// indices starting at 0 (see [scrollTo] Dartdoc). When that contract is
  /// violated — e.g. `watch()` is used with indices `0,1,2,50,51,52` — a
  /// prefix sum that reaches the gap must fail loudly instead of throwing an
  /// unqualified `_TypeError` from a null-asserted map lookup.
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

  /// Throws [StateError] if any logical index in `0..targetItemIndex` was
  /// last registered by a row whose actual physical sliver position
  /// disagreed with the `watch(index:)` value it was given (see
  /// [_watchIndexMismatches]).
  ///
  /// Called immediately before [scrollTo]/[_runAnimateTo] treat the
  /// `0..targetItemIndex` prefix as trustworthy and sum it into an offset —
  /// after the prefix is known to be *complete* (see [_hasCompletePrefix]),
  /// but before that completeness is mistaken for *correctness*. A
  /// contiguous, fully-populated prefix built from `watch()` indices that do
  /// not track physical slot order can result in:
  /// every required key is present, so [_hasCompletePrefix] and
  /// [_sizeOrThrow] both pass, yet the sum does not equal the true on-screen
  /// offset. This check closes that gap by refusing to complete
  /// successfully instead.
  void _checkNoWatchIndexMismatch(int targetItemIndex) {
    for (int i = 0; i <= targetItemIndex; i++) {
      final physicalIndex = _watchIndexMismatches[i];
      if (physicalIndex != null) {
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

  /// Clamps [pixels] to what the scrollable can actually reach.
  ///
  /// The offset formula sums measured extents and then subtracts an
  /// [alignment] adjustment, so it routinely produces targets outside
  /// `[minScrollExtent, maxScrollExtent]` — `scrollTo(0, alignment: 1)`
  /// asks for the first row's *bottom* at the viewport bottom, which is a
  /// negative offset, and aligning a row near the end can ask for more than
  /// `maxScrollExtent`. Flutter's own `ScrollPosition` absorbs these: the
  /// next layout pass corrects the position back to the bound. But that
  /// correction lands a frame *after* `scrollTo`'s Future resolves, so a
  /// caller doing `await scrollTo(...)` and then reading `offset` observed
  /// the raw out-of-range value (e.g. `-500.0` against a `minScrollExtent`
  /// of `0.0`) even though the list was already visually correct.
  ///
  /// Clamping here makes the documented "physical list bounds take priority
  /// over the requested alignment" contract true at the moment the Future
  /// settles, not merely one frame later.
  ///
  /// Content dimensions are only available once layout has run; before that
  /// there is no bound to clamp against, so [pixels] passes through
  /// unchanged.
  ///
  /// Only ever applied to a *final* target, never to an intermediate search
  /// or "jump closer" step. [ScrollPosition.maxScrollExtent] describes the
  /// content laid out so far, not the whole list: mid-search — and on the
  /// already-measured fast path for a target below the current viewport —
  /// rows beyond the current extent have not been built, so the bound is
  /// smaller than the finished list's. Clamping a step against it would
  /// stop the search at the edge of what is already known and never
  /// discover the rest, which is how index 5 of a 10-row list (target
  /// 500px, extent-so-far 400px) ends up stranded at 400.
  double _clampToBounds(double pixels) {
    if (!position.hasContentDimensions) {
      return pixels;
    }
    return pixels.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  /// Whether a user drag is currently driving the attached position.
  ///
  /// Maintained by [_notifyUserGestureStart]/[_notifyUserGestureEnd], which
  /// the package's `IndexedScrollGestureDetector` wrapper feeds from
  /// `ScrollStartNotification`/`ScrollEndNotification`. `ScrollPosition`
  /// exposes no *public* "is a finger down right now" flag — `activity` is
  /// `@protected`, and `userScrollDirection` is also set by ballistic
  /// settling, so neither can answer this question from outside the SDK.
  ///
  /// This matters because a drag and this controller's search loop cannot
  /// share the position. The search advances by calling `jumpTo`/`animateTo`,
  /// and both *replace* whatever activity is currently installed — including
  /// the `DragScrollActivity` holding the user's in-progress gesture. Once
  /// that happens the gesture recognizer keeps delivering updates into a
  /// drag whose activity is gone, and every one of them trips
  /// `ScrollPositionWithSingleContext.setPixels`'s `activity!.isScrolling`
  /// assertion. In a debug build that surfaces as a stream of framework
  /// assertion errors; in profile/release the assertion is compiled out but
  /// the drag is still dead, so the user's finger moves and the list does
  /// not follow it.
  bool _userDragging = false;

  /// Records that a user drag has begun, so an in-flight [scrollTo] yields
  /// the position to the gesture at its next check-in with
  /// [ScrollCancelReason.userGesture].
  ///
  /// Only a real drag counts: `scrollTo`'s own `animateTo` steps also emit
  /// `ScrollStartNotification`, and treating those as gestures would make
  /// every programmatic scroll cancel itself. Callers must therefore gate
  /// this on `notification.dragDetails != null`, which
  /// [IndexedScrollGestureDetector] does.
  void _notifyUserGestureStart() {
    _userDragging = true;
    final operationId = _activeOperationId;
    if (operationId != null) {
      _userGestureCancelledOperationId = operationId;
      _currentOperationId++;
    }
  }

  /// Records that the user's drag has ended, re-allowing programmatic
  /// scrolls. This deliberately does not resume the cancelled [scrollTo] —
  /// the user has moved the list somewhere of their own choosing, so
  /// silently continuing to the old target would fight them.
  void _notifyUserGestureEnd() => _userDragging = false;

  /// Throws [ScrollCancelledException] if [myOperationId] has been
  /// superseded (by a newer [scrollTo] call or by [dispose]), if the user
  /// started dragging, or if the controller no longer has an attached
  /// position (`detach`). Called after every `await` in [_animateTo] so a
  /// stale in-flight call notices before it touches the position again.
  void _checkOperationLive(int myOperationId, double scrollToIndex) {
    if (_currentOperationId != myOperationId) {
      if (_disposed) {
        throw ScrollCancelledException(ScrollCancelReason.disposed, scrollToIndex);
      }
      if (_invalidatedOperationId == myOperationId) {
        throw ScrollCancelledException(ScrollCancelReason.dataInvalidated, scrollToIndex);
      }
      if (_explicitlyCancelledOperationId == myOperationId) {
        throw ScrollCancelledException(ScrollCancelReason.explicitCancel, scrollToIndex);
      }
      if (_userGestureCancelledOperationId == myOperationId) {
        throw ScrollCancelledException(ScrollCancelReason.userGesture, scrollToIndex);
      }
      throw ScrollCancelledException(ScrollCancelReason.superseded, scrollToIndex);
    }
    if (!hasClients || positions.isEmpty) {
      throw ScrollCancelledException(ScrollCancelReason.detached, scrollToIndex);
    }
    // A drag that began *between* two check-ins must stop the search before
    // its next jumpTo/animateTo, not merely at the id bump in
    // _notifyUserGestureStart: the very next step would otherwise replace the
    // live DragScrollActivity and kill the gesture.
    if (_userDragging) {
      throw ScrollCancelledException(ScrollCancelReason.userGesture, scrollToIndex);
    }
  }

  /// Clears [_activeOperationId] if it still names [myOperationId].
  ///
  /// The guard matters because a superseded call reaches its own exit path
  /// (via the `finally` in [_animateTo]) after a newer call has already
  /// claimed [_activeOperationId] for itself; without the guard, the older
  /// call's cleanup would incorrectly erase the newer call's still-active id.
  void _clearActiveOperation(int myOperationId) {
    if (_activeOperationId == myOperationId) {
      _activeOperationId = null;
    }
  }

  /// Cancels the active [scrollTo], if any.
  ///
  /// The position stops immediately and the operation completes with
  /// [ScrollCancelReason.explicitCancel]. Calling this with no active operation
  /// is safe. Use [IndexedScrollGestureDetector] to give user drags priority.
  void cancelScroll() {
    final operationId = _activeOperationId;
    if (operationId == null) {
      return;
    }
    _stopCoasting();
    _explicitlyCancelledOperationId = operationId;
    _currentOperationId++;
  }

  /// Forces whatever [ScrollActivity] is currently driving the attached
  /// [ScrollPosition] (in particular a `DrivenScrollActivity` left running by
  /// an in-flight `animateTo` step) to be replaced with an idle one, so a
  /// cancellation takes visible effect immediately instead of only being
  /// noticed the next time [_checkOperationLive] runs. See [cancelScroll]'s
  /// Dartdoc for why this is needed and why `jumpTo` is the right tool for
  /// it.
  ///
  /// Safe to call whenever an operation might be active: guarded by
  /// [hasClients]/[positions] the same way [_checkOperationLive] is, since
  /// this can run from [cancelScroll] or [invalidateMeasurements] even after
  /// the controller has detached from its position.
  void _stopCoasting() {
    if (!hasClients || positions.isEmpty) {
      return;
    }
    position.jumpTo(position.pixels);
  }

  /// Discards every measured size and re-measures the currently built
  /// (live) rows, without waiting for a fresh [scrollTo] search pass.
  ///
  /// Call this after the underlying list data changes in a way that makes
  /// old measurements unsafe to reuse — reordering, inserting, deleting, or
  /// resizing a row identified by `watch(index: ...)` — or after switching
  /// the list's `scrollDirection` on the same controller instance, since
  /// sizes measured under the old axis's layout constraints are not valid
  /// under the new one. As documented on [scrollTo] and in the package's
  /// contract notes, the
  /// controller cannot detect these mutations itself (it only ever sees
  /// logical indices and measured sizes, never the data driving them), so
  /// calling this explicitly after mutating the list is part of the public
  /// contract for the manual `watch()` API. If the data did not change,
  /// there is no need to call this — in particular, do not call it on every
  /// `build`.
  ///
  /// This does two things, in order:
  ///
  /// 1. If a [scrollTo] call is currently searching or animating, the
  ///    position's current activity is stopped immediately (see
  ///    [_stopCoasting], the same mechanism [cancelScroll] uses) so a
  ///    coasting `animateTo` step does not keep visibly moving the position
  ///    toward a target based on now-stale measurements, and its [Future]
  ///    completes with a [ScrollCancelledException] carrying
  ///    [ScrollCancelReason.dataInvalidated] the next time it checks in
  ///    (after its next `await`) — the same operation-ownership mechanism
  ///    [cancelScroll] and a superseding [scrollTo] call use (see
  ///    [_checkOperationLive]). The in-flight call's target index may no
  ///    longer refer to the same logical row after invalidation, so it is
  ///    never silently resumed or retried automatically; the caller must
  ///    issue a new [scrollTo] if it still wants to reach an index.
  /// 2. Every entry in the measured-size cache is discarded, and the
  ///    measurement generation ([measurementGeneration], exposed for
  ///    testing) is incremented so the reset is independently observable.
  ///
  /// This deliberately does **not** eagerly re-populate [_sizes] from
  /// [_liveOwners]'s current `RenderBox.size`. Immediately after a mutation,
  /// a live row may still have its old layout because [performLayout] has not
  /// run again. Copying that size into the cleared cache would make it appear
  /// current. A [scrollTo] call made immediately afterward instead trusts only
  /// sizes obtained from a real, post-invalidation layout pass — see the
  /// "Recovery after invalidation" section of [scrollTo]'s DartDoc.
  ///
  /// [_liveOwners] itself is deliberately *not* cleared: it records which
  /// render object currently owns the live registration for each index, a
  /// question that is independent of whether that index's cached size is
  /// still trusted. Clearing it here would not by itself invalidate
  /// anything (the size cache is what [scrollTo] reads), and would only
  /// force spurious re-registration bookkeeping on the next unrelated
  /// layout or unmount.
  ///
  /// Every currently-live row (by [_liveOwners]) is marked via
  /// [_RenderIndexedScrollItem.invalidateMeasurement] to run
  /// [RenderBox.performLayout] again on the next frame, so a row whose
  /// content changed but has not relaid out yet (no intervening frame
  /// between the data mutation and this call) is
  /// guaranteed to re-register a fresh size instead of never doing so simply
  /// because its old size happened to still satisfy Flutter's "does this
  /// need a new layout" check under the old constraints.
  void invalidateMeasurements() {
    final operationId = _activeOperationId;
    if (operationId != null) {
      _stopCoasting();
      _invalidatedOperationId = operationId;
      _currentOperationId++;
    }

    _sizes.clear();
    // A mismatch recorded against the previous generation's layout
    // must not outlive it — invalidateMeasurement() below forces every live
    // row through performLayout() again, which re-derives (or clears) each
    // entry here from a fresh comparison. Without this clear, a row that
    // legitimately fixed its watch(index:) after a reorder could still trip
    // _checkNoWatchIndexMismatch on a stale record from before the fix.
    _watchIndexMismatches.clear();
    _measurementGeneration++;

    for (final owner in _liveOwners.values) {
      owner.invalidateMeasurement();
    }
  }

  Future _animateTo(
    double scrollToIndex,
    double scrollPosition,
    double viewportSize,
    double minVisibleIndex,
    Duration duration,
    Curve curve,
    double alignment,
    int myOperationId, {
    required bool awaitInitialFrame,
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
        myOperationId,
        awaitInitialFrame: awaitInitialFrame,
      );
    } finally {
      _clearActiveOperation(myOperationId);
    }
  }

  Future _runAnimateTo(
    double scrollToIndex,
    double scrollPosition,
    double viewportSize,
    double minVisibleIndex,
    Duration duration,
    Curve curve,
    double alignment,
    int myOperationId, {
    required bool awaitInitialFrame,
  }) async {
    var animateSign = minVisibleIndex > scrollToIndex ? -1 : 1;
    final itemIndex = scrollToIndex.truncate();
    var step = viewportSize * animateSign;
    // Search until the FULL prefix 0..itemIndex is known, not merely
    // until itemIndex itself has an entry. A target index can already be
    // present in _sizes (e.g. it is a currently-live row whose layout ran
    // again right after invalidateMeasurements() cleared the cache) while
    // some index below it is still missing — trusting containsKey(itemIndex)
    // alone would exit this loop with a hole still in the prefix, which the
    // summation below would then either throw a spurious StateError on, or
    // (if scrollTo's own hasCompletePrefix gate already routed here) is
    // exactly the case this loop must actually close.
    if (!_hasCompletePrefix(itemIndex)) {
      var offset = scrollPosition;
      if (awaitInitialFrame) {
        // scrollTo() jumped back to offset 0 (or was already there)
        // because the 0..itemIndex prefix was incomplete, but a bare jumpTo
        // only moves the scroll offset -- it does not by itself force row 0
        // (and the rest of the initial viewport) through a layout pass. The
        // search loop below steps forward by a full viewportSize on every
        // iteration, including its very first step when duration is
        // Duration.zero (its own jumpTo fast path just below, chosen
        // deliberately to honor "zero duration means no animation"). Without
        // waiting for a frame here first, that first search step fires before
        // row 0 has ever been built/laid out, so index 0 never registers a
        // measurement -- yet position.pixels still visibly changes on every
        // step (the jumps themselves move it), which satisfies the loop's
        // "did we make progress" check below and lets it keep stepping the
        // position past the physical end of the list forever instead of
        // stalling and reporting an error. Waiting for a real frame here
        // gives the initial rows a chance to lay out and register their
        // sizes in _sizes before the loop's own progress tracking ever runs,
        // so a genuinely-empty list still stalls and errors out instead of
        // spinning. This wait belongs inside _runAnimateTo (not scrollTo
        // itself) specifically so it runs under _animateTo's try/finally:
        // a cancellation observed here must still clear _activeOperationId
        // via _clearActiveOperation, the same as every other await in this
        // search.
        await WidgetsBinding.instance.endOfFrame;
        _checkOperationLive(myOperationId, scrollToIndex);
        scrollPosition = position.pixels;
        offset = scrollPosition;
      }
      var stalledSteps = 0;
      while (!_hasCompletePrefix(itemIndex)) {
        final positionBefore = position.pixels;
        final measuredCountBefore = _sizes.length;

        offset += step;
        if (duration.inMicroseconds == 0) {
          // Same fast-path fix as the "jump closer" step below: a zero
          // Duration alone does not make animateTo take Flutter's internal
          // jumpTo shortcut unless the target is already within tolerance,
          // so this search step must call jumpTo explicitly to honor
          // "duration: zero means no animation" here too.
          position.jumpTo(offset);
        } else {
          await position.animateTo(offset, duration: duration, curve: curve);
        }
        _checkOperationLive(myOperationId, scrollToIndex);
        await WidgetsBinding.instance.endOfFrame;
        _checkOperationLive(myOperationId, scrollToIndex);

        if (_hasCompletePrefix(itemIndex)) {
          break;
        }

        // A stable edge means the requested index does not exist: the
        // scrollable stopped moving (clamped at a physical bound) and no
        // new item was measured by this step, so continuing would repeat
        // the same step forever.
        //
        // Raw position.pixels != positionBefore is not a reliable
        // progress signal on its own. jumpTo() (the zero-duration fast path
        // above) writes position.pixels directly and is NOT clamped to
        // maxScrollExtent/minScrollExtent the way a ballistic/user-driven
        // scroll would be -- so once the search has stepped past the
        // physical end of a short list, every further jumpTo still moves
        // position.pixels (e.g. from 32000 to 32400), which would keep
        // looking like progress forever even though no new row has been
        // measured since. Once layout has run (hasContentDimensions) and the
        // position already sits at or beyond the physical bound in the
        // search direction, only a genuinely new measurement counts as
        // progress; a pixel change that is still on the far side of that
        // bound is just the unclamped jump continuing to walk off the end.
        final atOrPastPhysicalBound = position.hasContentDimensions &&
            (animateSign > 0 ? position.pixels >= position.maxScrollExtent : position.pixels <= position.minScrollExtent);
        final madeProgress = _sizes.length != measuredCountBefore || (position.pixels != positionBefore && !atOrPastPhysicalBound);
        if (madeProgress) {
          stalledSteps = 0;
        } else {
          stalledSteps++;
          if (stalledSteps >= 2) {
            // A stable edge with the prefix still incomplete has two
            // different honest causes that look identical from progress
            // tracking alone. If some index ABOVE the first missing one is
            // already measured, the physical list did not simply end early
            // — a logical index was skipped entirely by watch(), which is a
            // configuration error (the contiguous-index contract), not
            // an out-of-bounds target. Report that case with StateError
            // naming the missing index, matching the behavior for
            // this exact scenario (see the non-contiguous-watch() contract
            // test); an ordinary "list ended before the target" still gets
            // RangeError.
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

    // The prefix is complete (checked above), but completeness does
    // not imply correctness — see _checkNoWatchIndexMismatch.
    _checkNoWatchIndexMismatch(itemIndex);

    var priorItems = 0.0;
    for (int i = 0; i < itemIndex; i++) {
      priorItems += _extentOf(_sizeOrThrow(i));
    }

    var fraction = scrollToIndex - scrollToIndex.truncate();
    var extent = _extentOf(_sizeOrThrow(itemIndex));
    var alignmentAdjust = -(viewportSize - extent) * alignment;
    var targetPixels = _clampToBounds(priorItems + extent * fraction + alignmentAdjust);
    var remaining = (targetPixels - scrollPosition).abs();
    var scrollLimit = viewportSize;
    if ((remaining - scrollLimit) > 0) {
      var jumpingPosition = targetPixels + step * -1;
      if (duration.inMicroseconds == 0) {
        // Flutter's ScrollPosition.animateTo only takes the jumpTo fast
        // path itself when the target is already within tolerance of the
        // current position (see ScrollPositionWithSingleContext.animateTo);
        // a zero Duration otherwise still drives a real DrivenScrollActivity
        // through the ticker. Calling jumpTo explicitly here keeps this
        // intermediate step's "duration: zero means no animation" promise
        // consistent with the final step below, instead of only holding for
        // targets that happen to already be close.
        position.jumpTo(jumpingPosition);
      } else {
        await position.animateTo(jumpingPosition, duration: duration, curve: curve);
      }
      _checkOperationLive(myOperationId, scrollToIndex);

      await WidgetsBinding.instance.endOfFrame;
      _checkOperationLive(myOperationId, scrollToIndex);
    }

    if (duration.inMicroseconds == 0) {
      position.jumpTo(targetPixels);
      await WidgetsBinding.instance.endOfFrame;
      _checkOperationLive(myOperationId, scrollToIndex);
    } else {
      await position.animateTo(targetPixels, duration: duration, curve: curve);
      _checkOperationLive(myOperationId, scrollToIndex);
    }
  }

  /// Scrolls to [scrollToIndex] and positions it according to [alignment].
  ///
  /// The integer part selects the item; a fractional part selects an offset
  /// within it. The final offset is clamped to the scrollable's bounds.
  ///
  /// Supports vertical and horizontal non-reversed [ListView.builder]s. The
  /// list must use [watch] for every item, have exactly one attached
  /// [ScrollPosition], and have completed its first layout. Padding along the
  /// scroll axis is not included in the calculated offset.
  ///
  /// Items not yet measured are discovered in a sequential, multi-frame pass.
  /// After changing list data or scroll direction, call [invalidateMeasurements]
  /// before calling this method.
  ///
  /// Parameter validation happens before the position is touched. Because this
  /// method is `async`, errors are reported through its returned [Future]. It
  /// completes with [RangeError], [ArgumentError], [StateError], or
  /// [ScrollCancelledException] as applicable.
  Future<void> scrollTo(
    double scrollToIndex, {
    Duration? duration,
    Curve? curve,
    double alignment = 0.0,
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

    // A ScrollPosition is added to `positions` by
    // ScrollController.attach() itself, synchronously from inside
    // ScrollController.onAttach — well before RenderViewport.performLayout
    // ever runs. So the `hasClients`/`positions.length != 1` guards above can
    // both already be satisfied while `position.viewportDimension` and
    // `position.pixels` are still unset: each is a bare null-check getter
    // (`ScrollPosition.viewportDimension => _viewportDimension!`,
    // `ScrollPosition.pixels => _pixels!`) with no default, guarded by
    // `hasViewportDimension`/`hasPixels`. Reading either before the first
    // layout pass throws Flutter SDK's raw `_TypeError` instead of one of
    // this package's documented error types (see the behavior described for
    // this exact scenario from `onAttach`). Checking readiness here, before
    // either getter is touched, turns that into a documented `StateError`.
    //
    // This check must run before `_activeOperationId` is claimed below: if
    // it ran after, the early `throw` would leave `_activeOperationId` set
    // to an operation that never reaches `_animateTo`'s `finally` (the only
    // other place that clears it), dangling until some later call happens
    // to increment `_currentOperationId` past it.
    if (!position.hasViewportDimension || !position.hasPixels) {
      throw StateError(
        'scrollTo() called before the first layout — viewport metrics are '
        'not yet available; call it after the initial frame, not from '
        'onAttach.',
      );
    }

    // Starting a scroll mid-drag would replace the DragScrollActivity that
    // holds the user's in-progress gesture, killing it (see
    // [_userDragging]). The user's finger wins, so this call refuses
    // outright rather than fighting it.
    if (_userDragging) {
      throw ScrollCancelledException(ScrollCancelReason.userGesture, scrollToIndex);
    }

    // Claiming a new operation id supersedes whatever call was previously
    // active. That older call (if any) notices the mismatch the next time
    // it checks in, after its next `await`, and cancels itself instead of
    // continuing to drive the position toward its now-stale target.
    final myOperationId = ++_currentOperationId;
    _activeOperationId = myOperationId;

    var viewportSize = position.viewportDimension;
    var scrollPosition = position.pixels;
    var index = 0.0;
    var minVisibleIndex = 0.0;

    final targetItemIndex = scrollToIndex.truncate();

    // A target already present in _sizes does not by itself mean the
    // *prefix* 0..targetItemIndex is complete — invalidateMeasurements() may
    // have cleared _sizes and a still-live row at or near the target could
    // already be back in the cache (from its own next layout) while rows
    // below it remain unmeasured. Trusting _sizes here without checking the
    // whole prefix would either sum through a hole via _sizeOrThrow (a
    // spurious StateError even though the data is recoverable by searching)
    // or, worse, silently use a stale/partial prefix. When the prefix has a
    // hole, skip both the minVisibleIndex prefix-walk below and the
    // already-at-target fast path entirely, and fall back to the same
    // sequential search-and-measure pass already used for a
    // never-measured index — internally returning to offset 0 first, since
    // the search below only measures forward from wherever it starts and a
    // hole below the current position would otherwise never get filled.
    final hasCompletePrefix = _hasCompletePrefix(targetItemIndex);

    if (!hasCompletePrefix) {
      if (scrollPosition != 0.0) {
        position.jumpTo(0.0);
        scrollPosition = position.pixels;
      }
    } else {
      // The prefix is complete (checked above), but completeness
      // does not imply correctness — see _checkNoWatchIndexMismatch. Must
      // run before this fast path's already-at-target early return below,
      // or a mismatched watch(index:) that happens to already sum to a
      // numerically-close-enough offset would complete successfully anyway.
      _checkNoWatchIndexMismatch(targetItemIndex);

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

        scrolledExtent += extent;
        index += 1.0;
      }

      var priorItems = 0.0;
      for (int i = 0; i < targetItemIndex; i++) {
        priorItems += _extentOf(_sizeOrThrow(i));
      }
      var fraction = scrollToIndex - targetItemIndex;
      var extent = _extentOf(_sizeOrThrow(targetItemIndex));
      var alignmentAdjust = -(viewportSize - extent) * alignment;
      var targetPixels = priorItems + extent * fraction + alignmentAdjust;
      if ((targetPixels - scrollPosition).abs() <= _alreadyAtTargetTolerancePixels) {
        _clearActiveOperation(myOperationId);
        return Future.value();
      }
    }

    return _animateTo(
      scrollToIndex,
      scrollPosition,
      viewportSize,
      minVisibleIndex,
      duration ?? scrollDuration,
      curve ?? this.curve,
      alignment,
      myOperationId,
      // Only the recovery path -- prefix incomplete, so this call is
      // either searching a never-measured index or recovering from
      // invalidateMeasurements() -- needs to wait for a real frame before
      // _runAnimateTo's search loop starts stepping. The already-measured
      // fast path (hasCompletePrefix branch above) never reaches _animateTo
      // at all when it can complete synchronously, and when it does fall
      // through here it is because targetPixels was outside tolerance with a
      // fully trustworthy prefix already in hand -- there is no "row 0 not
      // laid out yet" risk to guard against in that case.
      awaitInitialFrame: !hasCompletePrefix,
    );
  }

  /// Bumps the operation id before disposing so an in-flight [scrollTo]
  /// search notices the mismatch at its next check-in and cancels itself
  /// with [ScrollCancelReason.disposed], instead of continuing to read
  /// [position] against a controller whose [ChangeNotifier] half is already
  /// torn down.
  ///
  /// [ScrollController.dispose] itself only removes this controller's
  /// listeners from each attached [ScrollPosition] and disposes the
  /// underlying [ChangeNotifier] — it does not detach positions or forbid
  /// reading them, so nothing here changes that contract; this override
  /// only adds the id bump ahead of it.
  @override
  void dispose() {
    _disposed = true;
    _currentOperationId++;
    super.dispose();
  }
}
