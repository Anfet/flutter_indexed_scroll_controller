## 0.0.1

### Initial release

- **Indexed scroll navigation**: Scroll to any item by logical index via `scrollTo(index)`, including items not yet built or measured.
- **Fractional indices**: Precise positioning within items via decimal indices (e.g. `2.5` for halfway through item 2). Zero-duration scrolls (`duration: Duration.zero`) skip animation throughout the whole `scrollTo()` path, including intermediate search/measurement steps, not just the final step.
- **Sequential measurement**: Unmeasured items are discovered and sized incrementally during the scroll; performance is O(n) frames for n items to traverse (typically 0.5–1.5 frames per item).
- **Continuous index contract**: `watch(index: ...)` requires all logical indices to form a contiguous run starting from 0; violations raise `StateError` instead of unqualified type errors.
- **Index identity contract**: `watch(index:)` must equal the row's actual physical position in the sliver (the same value `ListView.builder`'s `itemBuilder` receives), not a stable record id. The controller actively compares each `watch(index:)` against the row's physical sliver position and `scrollTo()` throws `StateError` on a mismatch instead of silently returning a numerically wrong offset. Reordering is supported by passing each row's new physical position to `watch(index:)` and calling `invalidateMeasurements()`; passing stale/mismatched indices after a reorder is a documented, loud error rather than a silent wrong-offset result.
- **Manual data invalidation**: Call `invalidateMeasurements()` explicitly after reordering, inserting, deleting, or resizing items. The controller cannot detect mutations itself. The first `scrollTo()` call after invalidation can be issued immediately, with no intervening frame and no manual `jumpTo(0)`/`cacheExtent` workaround — the controller recovers any missing measurement prefix internally via its sequential search-and-measure pass.
- **Explicit cancellation**: Use `cancelScroll()` to stop an in-flight scroll, typically from a `NotificationListener<ScrollStartNotification>` when a user gesture begins. Cancellation (via `cancelScroll()` or `invalidateMeasurements()`) stops the scroll position's current activity immediately instead of letting it coast to the in-flight step's intermediate target before the `Future` settles.
- **Operation ownership and concurrency**: Multiple `scrollTo` calls are safely arbitrated; the latest call supersedes earlier ones. `detach` and `dispose` also cancel in-flight operations with specific `ScrollCancelReason` values.
- **Full error contract**: Distinct error types (`RangeError`, `ArgumentError`, `StateError`, `ScrollCancelledException`) for parameter validation, unreachable indices, state violations, and cancellation reasons. Calling `scrollTo()` before the attached position's first layout (e.g. from `ScrollController.onAttach`) throws a documented `StateError` instead of an unqualified `_TypeError`.
- **Alignment semantics**: Fractional indices and `alignment` parameters position items relative to the viewport, with physical list bounds taking priority over requested alignment.
- **`measurementsSizes`**: Exposes the controller's measured-size cache as a live, read-through, unmodifiable view — reads reflect later measurements without re-fetching the getter, and write attempts throw `UnsupportedError` instead of silently corrupting offsets computed by `scrollTo()`.

### Known limitations

- **ListView padding**: The offset calculation does not account for `ListView.builder(padding: ...)`. A list with top padding will undershoot the visually aligned target.
- **Single vertical list only**: The controller supports exactly one vertical `ListView.builder`; multiple scroll views or horizontal/reverse modes are not supported in this release.
