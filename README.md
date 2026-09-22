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

## Separators and gestures

For ordinary separators, include the separator in the same `watch`-ed row. To align a `ListView.separated` item without its following separator, wrap the separator with `separator(index: index, ...)` and pass `alignmentTarget: ScrollAlignmentTarget.item` to `scrollTo`.

Wrap the scrollable with `IndexedScrollGestureDetector` when a user drag must cancel an active `scrollTo` operation:

```dart
IndexedScrollGestureDetector(
  controller: controller,
  child: list,
)
```

`scrollTo` throws `RangeError` for an invalid or unreachable index, `ArgumentError` for invalid arguments, `StateError` for an unsupported list state, and `ScrollCancelledException` when cancelled.

## Example

See the [example](example) application for vertical, horizontal, padding, reverse, and fingerprint-invalidation scenarios.
