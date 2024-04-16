import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class IndexedScrollController implements ScrollController {
  late final ScrollController _scrollController;
  final Duration scrollDuration;
  final Curve curve;

  final Map<int, Size> _sizes = {};

  double? _isWorking;

  IndexedScrollController({
    double initialScrollOffset = 0.0,
    bool keepScrollOffset = true,
    String? debugLabel,
    ScrollControllerCallback? onAttach,
    ScrollControllerCallback? onDetach,
    required this.scrollDuration,
    this.curve = Curves.linear,
  }) {
    _scrollController = ScrollController(
      debugLabel: debugLabel,
      initialScrollOffset: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      onAttach: onAttach,
      onDetach: onDetach,
    );
  }

  Widget watch({required int index, required Widget child}) {
    return IndexedScrollItem(controller: this, index: index, child: child);
  }

  void _registerSize(int index, Size size) {
    _sizes[index] = size;
  }

  Future _animateTo(
    double scrollToIndex,
    double scrollPosition,
    double viewportSize,
    double minVisibleIndex,
    Duration duration,
    Curve curve,
  ) async {
    _isWorking = scrollToIndex;
    try {
      var animateSign = minVisibleIndex > scrollToIndex ? -1 : 1;
      final itemIndex = scrollToIndex.truncate();
      var step = viewportSize * 1.5 * animateSign;
      if (!_sizes.containsKey(itemIndex)) {
        var offset = scrollPosition;
        while (_isWorking != null && offset + step < position.maxScrollExtent && !_sizes.containsKey(itemIndex)) {
          offset += step;
          position.jumpTo(offset);
          await WidgetsBinding.instance.endOfFrame;
        }

        scrollPosition = position.pixels;
      }

      if (_isWorking == null) {
        return;
      }

      var priorItems = 0.0;
      for (int i = 0; i < itemIndex; i++) {
        priorItems += _sizes[i]!.height;
      }

      var fraction = scrollToIndex - scrollToIndex.truncate();
      var targetPixels = priorItems + _sizes[itemIndex]!.height * fraction;
      var remaining = (targetPixels - scrollPosition).abs();

      var scrollLimit = viewportSize * 1.5;
      if ((remaining - scrollLimit) > 0) {
        var jumpingPosition = targetPixels + step * -1;
        position.jumpTo(jumpingPosition);
        await WidgetsBinding.instance.endOfFrame;
      }
      if (duration.inMicroseconds == 0) {
        position.jumpTo(targetPixels);
        await WidgetsBinding.instance.endOfFrame;
      } else {
        await position.animateTo(targetPixels, duration: duration, curve: curve);
      }
    } finally {
      _isWorking = null;
    }
  }

  Future<void> scrollTo(
    double scrollToIndex, {
    Duration? duration,
    Curve? curve,
  }) async {
    if (_isWorking != null) {
      await cancelScroll();
    }

    var position = _scrollController.position;
    var viewportSize = position.viewportDimension;
    var scrollPosition = position.pixels;
    var index = 0.0;
    var minVisibleIndex = 0.0;
    var maxVisibleIndex = 0.0;

    var scrolledWidgetHeights = 0.0;
    var minFraction = 0.0;
    var maxFraction = 0.0;
    var isMinFound = false;
    var isMaxFound = false;
    while (index < _sizes.length) {
      var size = _sizes[index]!;
      if (scrolledWidgetHeights + size.height > scrollPosition && !isMinFound) {
        minVisibleIndex = index;
        minFraction = (scrollPosition - scrolledWidgetHeights) / size.height;
        minVisibleIndex += minFraction;
        isMinFound = true;
      }

      if (isMinFound && !isMaxFound) {
        var heightWidthViewport = scrollPosition + viewportSize;
        if (scrolledWidgetHeights + size.height > heightWidthViewport) {
          maxVisibleIndex = index;
          maxFraction = (heightWidthViewport - scrolledWidgetHeights) / size.height;
          maxVisibleIndex += maxFraction;
          break;
        }
      }

      scrolledWidgetHeights += size.height;
      index += 1.0;
    }

    if (maxVisibleIndex <= scrollToIndex && maxVisibleIndex >= scrollToIndex) {
      return Future.value();
    }

    return _animateTo(scrollToIndex, scrollPosition, viewportSize, minVisibleIndex, duration ?? scrollDuration, curve ?? this.curve);
  }

  Future<void> cancelScroll() async {
    _isWorking = null;
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  void addListener(VoidCallback listener) => _scrollController.addListener(listener);

  @override
  Future<void> animateTo(double offset, {required Duration duration, required Curve curve}) =>
      _scrollController.animateTo(offset, duration: duration, curve: curve);

  @override
  void attach(ScrollPosition position) => _scrollController.attach(position);

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _scrollController.createScrollPosition(physics, context, oldPosition);

  @override
  void debugFillDescription(List<String> description) => _scrollController.debugFillDescription(description);

  @override
  String? get debugLabel => _scrollController.debugLabel;

  @override
  void detach(ScrollPosition position) => _scrollController.detach(position);

  @override
  void dispose() {
    _scrollController.dispose();
  }

  @override
  bool get hasClients => _scrollController.hasClients;

  @override
  bool get hasListeners => _scrollController.hasListeners;

  @override
  double get initialScrollOffset => _scrollController.initialScrollOffset;

  @override
  void jumpTo(double value) {
    _scrollController.jumpTo(value);
  }

  @override
  bool get keepScrollOffset => _scrollController.keepScrollOffset;

  @override
  void notifyListeners() {
    _scrollController.notifyListeners();
  }

  @override
  double get offset => _scrollController.offset;

  @override
  ScrollControllerCallback? get onAttach => _scrollController.onAttach;

  @override
  ScrollControllerCallback? get onDetach => _scrollController.onDetach;

  @override
  ScrollPosition get position => _scrollController.position;

  @override
  Iterable<ScrollPosition> get positions => _scrollController.positions;

  @override
  void removeListener(VoidCallback listener) => _scrollController.removeListener(listener);
}

class IndexedScrollItem extends SingleChildRenderObjectWidget {
  final IndexedScrollController controller;
  final int index;

  IndexedScrollItem({
    required this.controller,
    required this.index,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderIndexedScrollItem(
        index: index,
        controller: controller,
      );
}

class _RenderIndexedScrollItem extends RenderProxyBox {
  final int index;
  final IndexedScrollController controller;

  _RenderIndexedScrollItem({
    RenderBox? child,
    required this.index,
    required this.controller,
  }) : super(child);

  @override
  void performLayout() {
    size = child != null ? ChildLayoutHelper.layoutChild(child!, constraints) : constraints.smallest;
    controller._registerSize(index, size);
  }
}
