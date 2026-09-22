# Example

Demonstrates `IndexedScrollController` across multiple scenarios:

- **Vertical list:** standard indexed scrolling with variable-height rows
- **Horizontal list:** same behavior on the horizontal axis
- **Padding:** leading scroll offset with top or start padding
- **Reversed list:** reversed axis direction
- **Fingerprint invalidation:** automatic row-size tracking and measurement invalidation on data changes
- **Reshuffle:** re-randomizing row content and verifying scroll stability through layout-affecting changes
- **`ListView.separated`:** `separator()` registration and comparing `ScrollAlignmentTarget.row` vs `.item`

Run with `flutter run` (default: vertical). Tap "Scroll to Random Index (1s)" to trigger an indexed scroll operation. Each scroll waits for 1 second before animating to allow time for layout steps and search operations to complete.
