# indexed_scroll_controller

`IndexedScrollController` scrolls a single Flutter `ListView.builder` to a logical item index, including items that have not yet been laid out.

## Installation

```sh
flutter pub add indexed_scroll_controller
```

```dart
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';
```

## Usage

Create one controller and wrap every list row with `watch`. The index must be the `itemBuilder` index: consecutive, zero-based, and in physical list order.

```dart
final controller = IndexedScrollController(
  scrollDuration: const Duration(milliseconds: 250),
);

ListView.builder(
  controller: controller,
  itemCount: items.length,
  itemBuilder: (context, index) => controller.watch(
    index: index,
    child: ListTile(title: Text(items[index].title)),
  ),
);

await controller.scrollTo(42, alignment: 0);
```

The controller supports vertical and horizontal `ListView.builder`s, fractional indices, reversed lists, leading padding, and indexed lists in a `CustomScrollView` with finite preceding slivers. It supports one attached `ScrollPosition`.

## Data changes

Call `invalidateMeasurements()` after inserting, deleting, reordering, or resizing rows, and after changing scroll axis. An in-flight operation is cancelled with `ScrollCancelReason.dataInvalidated`.

For automatic invalidation, provide both callbacks. A fingerprint must identify the row and every data value that can affect its size on the scroll axis. Layout changes outside row data, such as available width, text scale, or theme, still require manual invalidation.

```dart
final controller = IndexedScrollController(
  scrollDuration: const Duration(milliseconds: 250),
  itemCount: () => items.length,
  contentFingerprint: (index) => (items[index].id, items[index].expanded),
);
```

When data changes, the controller compares the fingerprint of each row to detect which measurements are invalid. The fingerprint does not estimate geometry; it is only a tag for invalidation. After a detected change, the controller re-measures the affected row and any preceding rows whose layout may have shifted.

## Separators

`ListView.builder` rows that include their own separator (for example a `Column` with the item and a trailing divider) need nothing extra: just `watch` the whole row as usual.

For `ListView.separated`, wrap every item with `watch` and every separator with `separator(index: index, ...)`, keyed by the same logical item index the separator follows:

```dart
ListView.separated(
  controller: controller,
  itemCount: items.length,
  itemBuilder: (context, index) => controller.watch(
    index: index,
    child: ListTile(title: Text(items[index].title)),
  ),
  separatorBuilder: (context, index) => controller.separator(
    index: index,
    child: const Divider(),
  ),
);
```

Every separator must be wrapped this way, even a zero-size one (`separator(index: index, child: const SizedBox())`) — an unwrapped separator throws `StateError` rather than silently landing at the wrong offset, because `watch`'s logical indices would otherwise skip every separator's physical slot.

By default, `scrollTo`'s `alignment` measures against the whole row (item plus its trailing separator) — `ScrollAlignmentTarget.row`. Pass `alignmentTarget: ScrollAlignmentTarget.item` to align the item alone, ignoring its separator:

```dart
await controller.scrollTo(10, alignment: 1, alignmentTarget: ScrollAlignmentTarget.item);
```

`ScrollAlignmentTarget.item` requires that item's separator to have been registered via `separator()` — it is meaningless without one.

## Gestures

Wrap the scrollable with `IndexedScrollGestureDetector` when a user drag must cancel an active `scrollTo` operation:

```dart
IndexedScrollGestureDetector(
  controller: controller,
  child: list,
)
```

`scrollTo` throws `RangeError` for an invalid or unreachable index, `ArgumentError` for invalid arguments, `StateError` for an unsupported list state, and `ScrollCancelledException` when cancelled.

## Example

See the [example](example) application for vertical, horizontal, padding, reverse, `ListView.separated`, and fingerprint-invalidation scenarios.
