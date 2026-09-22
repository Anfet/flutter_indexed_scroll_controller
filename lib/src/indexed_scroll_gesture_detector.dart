part of 'indexed_scroll_controller.dart';

/// Gives a user drag priority over an active [IndexedScrollController.scrollTo].
class IndexedScrollGestureDetector extends StatelessWidget {
  /// The controller that drives the wrapped scrollable.
  final IndexedScrollController controller;

  /// The scrollable to observe.
  final Widget child;

  /// Creates a gesture-priority wrapper.
  const IndexedScrollGestureDetector({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          controller._notifyUserGestureStart();
        } else if (notification is ScrollEndNotification) {
          controller._notifyUserGestureEnd();
        }
        return false;
      },
      child: child,
    );
  }
}
