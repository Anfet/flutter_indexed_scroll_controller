A scroll controller for Flutter's vertical `ListView.builder` that enables navigation to items by logical index, even when those items have not been constructed or laid out yet.

## Features

`IndexedScrollController` extends `ScrollController` to support:

- **Scroll to logical index**: Use `scrollTo(index)` to navigate to any item by its logical index (0-based), even if not yet built.
- **Fractional indices**: Support for sub-item positioning via fractional indices (e.g. `2.5` for halfway through item 2).
- **Sequential measurement**: Unmeasured items are measured incrementally during the scroll; typical performance is O(n) frames for n items to traverse.
- **Automatic cleanup**: Measured heights are cached; unmounting an item preserves its height. Call `invalidateMeasurements()` explicitly after changing list data (reordering, inserting, deleting, or resizing items).
- **Explicit cancellation**: Call `cancelScroll()` to stop an in-flight scroll (e.g. when a user gesture starts). The controller does not automatically cancel on drag; you must integrate it with your gesture handling.

## Contract Notes

### Index identity: `watch(index:)` must be the row's physical position

`watch(index: ...)` requires two things, both actively enforced:

- **Continuity.** All registered logical indices must form a contiguous run starting at 0. If you register indices `0, 1, 2, 50, 51, 52`, attempting to scroll to index 50 throws `StateError` because indices 3–49 are not covered.
- **Identity.** `index` must equal the *physical position* the enclosing `ListView.builder` passes to its `itemBuilder` — the same value as that builder's `index` argument — not a stable record id from your data model. The controller compares each `watch(index:)` value against the row's actual position in the sliver as it lays out, and `scrollTo()` throws `StateError` if any index it depends on was last registered under a mismatched position, instead of silently landing at a numerically wrong offset. A full, contiguous `0..n-1` set of indices is not enough by itself if they are attached to the wrong rows.

### Reordering

After the underlying data is reordered, pass each row's **new physical position** to `watch(index:)` (so `watch()` continues to track slot order, per the identity contract above) and call `invalidateMeasurements()`. Under that contract, reordering works correctly: `scrollTo()` reaches the right offset for the row now at each position.

If instead the caller keeps passing indices that no longer match physical position (e.g. still keyed by a record id from before the reorder), `scrollTo()` does not silently return a wrong offset — it throws `StateError` naming the mismatched index. Calling `invalidateMeasurements()` does not by itself fix a mismatched `watch(index:)`: invalidation clears cached sizes, but the caller is still responsible for passing the correct positions afterward.

### Manual data invalidation

After the underlying list data changes — reordering, inserting, deleting, or changing item heights — you **must** call `invalidateMeasurements()`. The controller cannot detect these mutations itself because it only sees indices and cached sizes, never the data driving them. The first `scrollTo()` call after invalidation can be issued immediately, with no intervening `pump`/frame and no manual `jumpTo(0)`/`cacheExtent` workaround required — the controller recovers any missing prefix internally via the same sequential search-and-measure pass it uses for a never-measured index.

### Cancellation stops the position immediately

`cancelScroll()` and `invalidateMeasurements()` stop the scroll position's current activity synchronously, before either call returns. The position does not keep coasting toward the in-flight step's intermediate target while the cancelled call's `Future` settles a few ticks later.

### Zero duration

Passing `duration: Duration.zero` (or omitting `duration` with a controller configured for it) skips animation throughout the whole `scrollTo()` path — both the final step and any intermediate sequential-measurement/search steps jump directly via `jumpTo` instead of animating.

### Performance and geometry

- **Sequential measurement cost**: Long jumps to unmeasured indices incur an O(n)-frame cost (typically 0.5–1.5 frames per item), not instantaneous. Actual frame count depends on item heights and viewport size.
- **Padding limitations**: The offset calculation ignores `ListView.builder(padding: ...)`. A list with top padding will undershoot the visually aligned target by `padding.top` pixels. This is a limitation of the current offset formula, not a clamping bug.
- **Clamping**: The final scroll position is always clamped to the list's physical bounds `[0, maxScrollExtent]`, even if `alignment` requests otherwise.

### Error handling

- **RangeError**: Thrown if `scrollToIndex < 0` or if the index is not reachable (list ends before the target is measured).
- **ArgumentError**: Thrown if parameters are invalid: `scrollToIndex` is NaN/infinite, `duration` is negative, or `alignment` is NaN or outside `[0, 1]`.
- **StateError**: Thrown if logical indices are not contiguous (gap detected during prefix sum), if a `watch(index:)` value disagrees with its row's actual physical position in the sliver, if there is no attached position, if there are zero or multiple positions (only a single vertical `ListView.builder` is supported), or if `scrollTo()` is called before the attached position's first layout (e.g. from `ScrollController.onAttach`).
- **ScrollCancelledException**: Thrown when an in-flight `scrollTo` is cancelled by `cancelScroll()`, another `scrollTo` call, `invalidateMeasurements()`, `detach`, or `dispose`. The exception carries a `ScrollCancelReason` that distinguishes the cause.

## Usage

### 1. Create a controller

```dart
late final IndexedScrollController scrollController;

@override
void initState() {
  scrollController = IndexedScrollController(
    scrollDuration: const Duration(milliseconds: 300),
  );
  super.initState();
}

@override
void dispose() {
  scrollController.dispose();
  super.dispose();
}
```

### 2. Wrap items with `watch()`

```dart
ListView.builder(
  controller: scrollController,
  itemCount: items.length,
  itemBuilder: (context, index) {
    return scrollController.watch(
      index: index,
      child: MyItemWidget(item: items[index]),
    );
  },
)
```

### 3. Scroll to a target index

```dart
await scrollController.scrollTo(
  targetIndex,
  duration: const Duration(milliseconds: 300),
  curve: Curves.linear,
  alignment: 0.5, // 0=top of item, 0.5=center, 1=bottom
);
```

Call `scrollTo()` after the list's first layout, not from `ScrollController.onAttach` — the attached position exists at that point, but its viewport metrics do not yet, and `scrollTo()` throws `StateError` rather than reading them.

### 4. Handle user gestures (optional)

To give user drag priority over an in-flight scroll, wrap your list in a `NotificationListener` and call `cancelScroll()`. `scrollTo()`'s own internal `animateTo()` calls also emit `ScrollStartNotification`, so check `dragDetails` to only cancel on a real user gesture, not the controller's own animation:

```dart
NotificationListener<ScrollStartNotification>(
  onNotification: (notification) {
    if (notification.dragDetails != null) {
      scrollController.cancelScroll();
    }
    return false;
  },
  child: ListView.builder(
    controller: scrollController,
    // ... rest of list config
  ),
)
```

### 5. Invalidate after data changes

If the underlying list data changes:

```dart
// User reordered, inserted, deleted, or resized items
items.removeAt(5);
scrollController.invalidateMeasurements();

// Now safe to call scrollTo again
await scrollController.scrollTo(targetIndex);
```

## Additional information

`IndexedScrollController` extends the standard Flutter `ScrollController` and preserves all standard scroll methods (`jumpTo`, `animateTo`, etc.). See the `example/` folder for a complete working app with gesture handling and status display.