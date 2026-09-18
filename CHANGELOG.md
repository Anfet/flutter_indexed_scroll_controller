## 0.1.0

### Added

- **Horizontal list support**: `ListView.builder(scrollDirection: Axis.horizontal)` is now supported. The controller reads `position.axis` from the attached `ScrollPosition` and measures each item's extent along that axis (`Size.height` for vertical, `Size.width` for horizontal) — in the summed prefix, the target's fractional contribution, and the `alignment` adjustment alike. No new constructor parameter or mode switch: `watch()`/`scrollTo()` are used exactly as with a vertical list. If a single controller/list switches `scrollDirection`, call `invalidateMeasurements()` first — sizes measured under the old axis's constraints are not valid under the new one.
- **`IndexedScrollGestureDetector`**: Wrap a list in it to give a user's drag priority over an in-flight `scrollTo()`. The scroll yields with the new `ScrollCancelReason.userGesture`, and a `scrollTo()` issued during a drag is refused the same way instead of interrupting the gesture.
- **`ScrollCancelReason.userGesture`**: New cancellation reason, distinct from `explicitCancel` so callers can tell "the user took over the list" from "I cancelled this myself" — retrying is wrong in the first case.

### Fixed

- **`scrollTo()` now resolves with an in-bounds `offset`.** The offset formula sums measured extents and subtracts an `alignment` adjustment, so it routinely produces targets outside `[minScrollExtent, maxScrollExtent]` — `scrollTo(0, alignment: 1)` asks for a negative offset, and a target near the end can exceed `maxScrollExtent`. Flutter corrected these on the next layout pass, but that landed a frame *after* the `Future` resolved, so `await scrollTo(...)` followed by reading `offset` returned the raw out-of-range value (e.g. `-500.0` against a `minScrollExtent` of `0.0`). The final target is now clamped directly, making the documented "physical list bounds take priority" contract true at the moment the call completes.
- **A user drag during an in-flight `scrollTo()` no longer breaks the gesture.** The search loop advances with `jumpTo`/`animateTo`, which replace whatever `ScrollActivity` is installed — including the one holding the user's in-progress drag. The gesture recognizer then kept delivering updates into a detached drag, so the list stopped following the finger (and debug builds logged repeated `activity!.isScrolling` assertion failures from `ScrollPositionWithSingleContext.setPixels`). This affected any draggable list, with or without the previously documented `cancelScroll()` wiring; that manual wiring did not prevent it. Wrap the list in `IndexedScrollGestureDetector` to opt into the fix.

### Changed

- The README's "Handle user gestures" section previously recommended a `NotificationListener` + `cancelScroll()` pattern that did not actually preserve the drag. It now documents `IndexedScrollGestureDetector` instead.
- Corrected a stale README reference describing only a *vertical* `ListView.builder` as supported.

### Known limitations

- **ListView padding**: The offset calculation does not account for `ListView.builder(padding: ...)` along the scroll axis. A list with leading padding will undershoot the visually aligned target.
- **Single list only**: Exactly one `ListView.builder` (one attached `ScrollPosition`) is supported, vertical or horizontal. `reverse: true` is not supported on either axis.

## 0.0.1

### Initial release

- **Indexed scroll navigation**: Scroll to any item by logical index via `scrollTo(index)`, including items not yet built or measured.
- **Fractional indices**: Precise positioning within items via decimal indices (e.g. `2.5` for halfway through item 2). Zero-duration scrolls (`duration: Duration.zero`) skip animation throughout the whole `scrollTo()` path, including intermediate search/measurement steps, not just the final step.
- **Sequential measurement**: Unmeasured items are discovered and sized incrementally during the scroll; performance is O(n) frames for n items to traverse (typically 0.5–1.5 frames per item).
- **Measurement cache**: Measured heights are retained when rows leave the viewport, so ordinary widget unmounting does not discard known geometry.
- **Continuous index contract**: `watch(index: ...)` requires all logical indices to form a contiguous run starting from 0; violations raise `StateError` instead of unqualified type errors.
- **Index identity contract**: `watch(index:)` must equal the row's actual physical position in the sliver (the same value `ListView.builder`'s `itemBuilder` receives), not a stable record id. The controller actively compares each `watch(index:)` against the row's physical sliver position and `scrollTo()` throws `StateError` on a mismatch instead of silently returning a numerically wrong offset. Reordering is supported by passing each row's new physical position to `watch(index:)` and calling `invalidateMeasurements()`; passing stale/mismatched indices after a reorder is a documented, loud error rather than a silent wrong-offset result.
- **Manual data invalidation**: Call `invalidateMeasurements()` explicitly after reordering, inserting, deleting, or resizing items. The controller cannot detect mutations itself. The first `scrollTo()` call after invalidation can be issued immediately, with no intervening frame and no manual `jumpTo(0)`/`cacheExtent` workaround — the controller recovers any missing measurement prefix internally via its sequential search-and-measure pass.
- **Explicit cancellation**: Use `cancelScroll()` to stop an in-flight scroll, typically from a `NotificationListener<ScrollStartNotification>` when a user gesture begins. Cancellation (via `cancelScroll()` or `invalidateMeasurements()`) stops the scroll position's current activity immediately instead of letting it coast to the in-flight step's intermediate target before the `Future` settles.
- **Operation ownership and concurrency**: Multiple `scrollTo` calls are safely arbitrated; the latest call supersedes earlier ones. `detach` and `dispose` also cancel in-flight operations with specific `ScrollCancelReason` values.
- **Full error contract**: Distinct error types (`RangeError`, `ArgumentError`, `StateError`, `ScrollCancelledException`) for parameter validation, unreachable indices, state violations, and cancellation reasons. Calling `scrollTo()` before the attached position's first layout (e.g. from `ScrollController.onAttach`) throws a documented `StateError` instead of an unqualified `_TypeError`.
- **Alignment semantics**: Fractional indices and `alignment` parameters position items relative to the viewport, with physical list bounds taking priority over requested alignment.
- **`measurementsSizes`**: Exposes the controller's measured-size cache as a live, read-through, unmodifiable view — reads reflect later measurements without re-fetching the getter, and write attempts throw `UnsupportedError` instead of silently corrupting offsets computed by `scrollTo()`.
- **`ScrollController` compatibility**: `IndexedScrollController` extends Flutter's `ScrollController` and retains standard scrolling methods, listeners, `onAttach`/`onDetach`, and lifecycle behavior.

### Known limitations

- **ListView padding**: The offset calculation does not account for `ListView.builder(padding: ...)`. A list with top padding will undershoot the visually aligned target.
- **Single vertical list only**: This release supported exactly one vertical `ListView.builder`; multiple scroll views and horizontal/reverse modes were not supported. (Horizontal lists are supported as of 0.1.0.)
