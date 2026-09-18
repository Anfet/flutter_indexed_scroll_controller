part of 'indexed_scroll_controller.dart';

/// Gives a user's drag priority over an in-flight
/// [IndexedScrollController.scrollTo].
///
/// Wrap a list that uses [controller]. When a drag starts, its active
/// [IndexedScrollController.scrollTo] completes with
/// [ScrollCancelReason.userGesture]. A new call during the drag is rejected
/// for the same reason.
class IndexedScrollGestureDetector extends StatelessWidget {
  /// The controller driving the wrapped scrollable.
  final IndexedScrollController controller;

  /// The scrollable to wrap — typically a `ListView.builder`.
  final Widget child;

  const IndexedScrollGestureDetector({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Only a real drag carries dragDetails. scrollTo()'s own animateTo()
        // steps emit ScrollStartNotification too, and treating those as
        // gestures would make every programmatic scroll cancel itself.
        if (notification is ScrollStartNotification && notification.dragDetails != null) {
          controller._notifyUserGestureStart();
        } else if (notification is ScrollEndNotification) {
          // ScrollEndNotification fires once the post-drag ballistic
          // settling finishes, which is the point the position is free
          // again. Its dragDetails is null by then, so it cannot be gated
          // the way the start notification is.
          controller._notifyUserGestureEnd();
        }
        return false;
      },
      child: child,
    );
  }
}
