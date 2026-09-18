A scroll controller for Flutter's `ListView.builder` (vertical or horizontal) that enables navigation to items by logical index, even when those items have not been constructed or laid out yet.

## Features

`IndexedScrollController` extends `ScrollController` to support:

- **Scroll to logical index**: Use `scrollTo(index)` to navigate to any item by its logical index (0-based), even if not yet built.
- **Vertical and horizontal lists**: Works with both `Axis.vertical` and `Axis.horizontal` `ListView.builder`s. The controller reads the axis from the attached `ScrollPosition` and measures item extent along that axis (height for vertical, width for horizontal) — no separate configuration is needed.
- **Fractional indices**: Support for sub-item positioning via fractional indices (e.g. `2.5` for halfway through item 2).
- **Sequential measurement**: Unmeasured items are measured incrementally during the scroll; typical performance is O(n) frames for n items to traverse.
- **Automatic cleanup**: Measured sizes are cached; unmounting an item preserves its size. Call `invalidateMeasurements()` explicitly after changing list data (reordering, inserting, deleting, or resizing items) or after switching a list's `scrollDirection`.
- **Explicit cancellation**: Call `cancelScroll()` to stop an in-flight scroll programmatically.
- **User gestures win**: Wrap the list in `IndexedScrollGestureDetector` and a user's drag takes priority over an in-flight `scrollTo()`, which yields with `ScrollCancelReason.userGesture`. Without the wrapper the controller cannot detect a drag, and the search will take the position away from the gesture.

## Contract Notes

### Index identity: `watch(index:)` must be the row's physical position

`watch(index: ...)` requires two things, both actively enforced:

- **Continuity.** All registered logical indices must form a contiguous run starting at 0. If you register indices `0, 1, 2, 50, 51, 52`, attempting to scroll to index 50 throws `StateError` because indices 3–49 are not covered.
- **Identity.** `index` must equal the *physical position* the enclosing `ListView.builder` passes to its `itemBuilder` — the same value as that builder's `index` argument — not a stable record id from your data model. The controller compares each `watch(index:)` value against the row's actual position in the sliver as it lays out, and `scrollTo()` throws `StateError` if any index it depends on was last registered under a mismatched position, instead of silently landing at a numerically wrong offset. A full, contiguous `0..n-1` set of indices is not enough by itself if they are attached to the wrong rows.

### Reordering

After the underlying data is reordered, pass each row's **new physical position** to `watch(index:)` (so `watch()` continues to track slot order, per the identity contract above) and call `invalidateMeasurements()`. Under that contract, reordering works correctly: `scrollTo()` reaches the right offset for the row now at each position.

If instead the caller keeps passing indices that no longer match physical position (e.g. still keyed by a record id from before the reorder), `scrollTo()` does not silently return a wrong offset — it throws `StateError` naming the mismatched index. Calling `invalidateMeasurements()` does not by itself fix a mismatched `watch(index:)`: invalidation clears cached sizes, but the caller is still responsible for passing the correct positions afterward.

### Manual data invalidation

After the underlying list data changes — reordering, inserting, deleting, or changing item heights/widths — you **must** call `invalidateMeasurements()`. The controller cannot detect these mutations itself because it only sees indices and cached sizes, never the data driving them. The first `scrollTo()` call after invalidation can be issued immediately, with no intervening `pump`/frame and no manual `jumpTo(0)`/`cacheExtent` workaround required — the controller recovers any missing prefix internally via the same sequential search-and-measure pass it uses for a never-measured index.

The same rule applies if you switch a single controller/list from vertical to horizontal (or back): sizes measured under the old `scrollDirection`'s layout constraints are not valid under the new one, so call `invalidateMeasurements()` before the next `scrollTo()` after the switch. The controller does not detect or automate this switch itself.

### Scroll axis and item extent

`scrollTo()` reads `position.axis` from the attached `ScrollPosition` and uses it to pick which dimension of each measured `Size` counts as that item's extent: `Size.height` for `Axis.vertical`, `Size.width` for `Axis.horizontal`. This applies uniformly everywhere an item's length along the scroll direction is needed — summing the prefix before the target, the target item's own fractional contribution, and the `alignment` adjustment. There is no separate constructor parameter or mode switch for horizontal lists; a plain `ListView.builder(scrollDirection: Axis.horizontal, ...)` with the same `watch()`/`scrollTo()` API works as-is.

`alignment: 0` aligns the item to the start of the scroll axis (top for vertical, and for horizontal the edge `position.pixels == 0` corresponds to — the left edge under LTR, or the right edge under RTL, per Flutter's own `ListView`/`Directionality` semantics; this package does not alter that). `ListView.builder(reverse: true, ...)` is not supported, on either axis. Axis padding (`ListView.builder(padding: ...)`) is still not accounted for by the offset formula, per the "Padding limitations" note above — this applies along whichever axis the list scrolls.

### Cancellation stops the position immediately

`cancelScroll()` and `invalidateMeasurements()` stop the scroll position's current activity synchronously, before either call returns. The position does not keep coasting toward the in-flight step's intermediate target while the cancelled call's `Future` settles a few ticks later.

### Zero duration

Passing `duration: Duration.zero` (or omitting `duration` with a controller configured for it) skips animation throughout the whole `scrollTo()` path — both the final step and any intermediate sequential-measurement/search steps jump directly via `jumpTo` instead of animating.

### Performance and geometry

- **Sequential measurement cost**: Long jumps to unmeasured indices incur an O(n)-frame cost (typically 0.5–1.5 frames per item), not instantaneous. Actual frame count depends on item heights and viewport size.
- **Padding limitations**: The offset calculation ignores `ListView.builder(padding: ...)`. A list with top padding will undershoot the visually aligned target by `padding.top` pixels. This is a limitation of the current offset formula, not a clamping bug.
- **Clamping**: The final scroll position is always clamped to the list's physical bounds `[minScrollExtent, maxScrollExtent]`, even if `alignment` or a fractional index requests otherwise. The clamp is applied to the target itself, so the position is already in bounds when `scrollTo()`'s `Future` resolves — a caller that awaits the call and then reads `offset` never observes an out-of-range value.

### Error handling

- **RangeError**: Thrown if `scrollToIndex < 0` or if the index is not reachable (list ends before the target is measured).
- **ArgumentError**: Thrown if parameters are invalid: `scrollToIndex` is NaN/infinite, `duration` is negative, or `alignment` is NaN or outside `[0, 1]`.

All of the above are delivered through the `Future` that `scrollTo()` returns, because the method is `async` — including the parameter-validation errors, which are checked before any `await` and before the scroll position is touched (so a bad call never moves the list first). A bare `try`/`catch` around a call whose result is not awaited will not catch them:

```dart
// Caught:
try {
  await controller.scrollTo(index);
} on ArgumentError catch (_) { /* ... */ }

// Fire-and-forget still needs a handler:
controller.scrollTo(index).catchError((Object _) {});
```
- **StateError**: Thrown if logical indices are not contiguous (gap detected during prefix sum), if a `watch(index:)` value disagrees with its row's actual physical position in the sliver, if there is no attached position, if there are zero or multiple positions (only a single `ListView.builder` is supported, vertical or horizontal), or if `scrollTo()` is called before the attached position's first layout (e.g. from `ScrollController.onAttach`).
- **ScrollCancelledException**: Thrown when an in-flight `scrollTo` is cancelled by `cancelScroll()`, another `scrollTo` call, `invalidateMeasurements()`, a user drag (with `IndexedScrollGestureDetector`), `detach`, or `dispose`. The exception carries a `ScrollCancelReason` that distinguishes the cause.

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

For a horizontal list, pass `scrollDirection: Axis.horizontal` to `ListView.builder` — `watch()`/`scrollTo()` are used exactly the same way; the controller reads the axis from the attached `ScrollPosition` on its own:

```dart
ListView.builder(
  controller: scrollController,
  scrollDirection: Axis.horizontal,
  itemCount: items.length,
  itemBuilder: (context, index) {
    return scrollController.watch(
      index: index,
      child: MyItemWidget(item: items[index]), // sized along the width
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

### 4. Give user gestures priority (recommended)

Wrap the list in `IndexedScrollGestureDetector` so a user's drag takes priority over an in-flight `scrollTo()`:

```dart
IndexedScrollGestureDetector(
  controller: scrollController,
  child: ListView.builder(
    controller: scrollController,
    // ... rest of list config
  ),
)
```

This is strongly recommended for any list the user can drag. A drag and `scrollTo()`'s search loop cannot share a `ScrollPosition`: the search advances with `jumpTo`/`animateTo`, and both replace whatever scroll activity is installed — including the one holding the user's in-progress gesture. Without the wrapper, dragging during a `scrollTo()` leaves the finger driving a detached activity, so **the list stops following the drag** (and debug builds log repeated `activity!.isScrolling` assertion failures from the framework).

With the wrapper, the in-flight call's `Future` completes with `ScrollCancelReason.userGesture` and the drag proceeds normally. The scroll is not resumed afterwards — the user has moved the list somewhere of their own choosing. A `scrollTo()` issued *during* a drag is refused the same way, rather than interrupting the gesture.

Because a yielded scroll throws, a fire-and-forget call needs a handler:

```dart
scrollController.scrollTo(0).catchError((Object _) {});
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