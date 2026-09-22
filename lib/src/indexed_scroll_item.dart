part of 'indexed_scroll_controller.dart';

/// A row wrapper that reports its laid-out size to an [IndexedScrollController].
///
/// Created internally by [IndexedScrollController.watch]; not part of the
/// public API.
class _IndexedScrollItem extends SingleChildRenderObjectWidget {
  final IndexedScrollController controller;

  final int index;

  final bool hasFingerprintSnapshot;

  final Object? fingerprintSnapshot;

  const _IndexedScrollItem({
    required this.controller,
    required this.index,
    this.hasFingerprintSnapshot = false,
    this.fingerprintSnapshot,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIndexedScrollItem(
        index: index,
        controller: controller,
        hasFingerprintSnapshot: hasFingerprintSnapshot,
        fingerprintSnapshot: fingerprintSnapshot,
      );

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderObject renderObject) {
    (renderObject as _RenderIndexedScrollItem)
      ..index = index
      ..controller = controller
      .._setFingerprintSnapshot(hasFingerprintSnapshot, fingerprintSnapshot);
  }
}

class _RenderIndexedScrollItem extends RenderProxyBox {
  int _index;
  IndexedScrollController _controller;
  bool _hasFingerprintSnapshot;
  Object? _fingerprintSnapshot;

  _RenderIndexedScrollItem({
    RenderBox? child,
    required int index,
    required IndexedScrollController controller,
    bool hasFingerprintSnapshot = false,
    Object? fingerprintSnapshot,
  })  : _index = index,
        _controller = controller,
        _hasFingerprintSnapshot = hasFingerprintSnapshot,
        _fingerprintSnapshot = fingerprintSnapshot,
        super(child);

  void _setFingerprintSnapshot(bool hasSnapshot, Object? snapshot) {
    _hasFingerprintSnapshot = hasSnapshot;
    _fingerprintSnapshot = snapshot;
  }

  void invalidateMeasurement() => markNeedsLayout();

  int get index => _index;

  set index(int value) {
    if (_index == value) return;
    if (attached) {
      _controller._unregisterLiveOwner(this, index: _index);
    }
    _index = value;
    markNeedsLayout();
  }

  IndexedScrollController get controller => _controller;

  set controller(IndexedScrollController value) {
    if (_controller == value) return;
    if (attached) {
      _controller._unregisterLiveOwner(this, index: _index);
    }
    _controller = value;
    markNeedsLayout();
  }

  int? get _physicalSliverIndex {
    RenderObject? node = this;
    while (node != null) {
      final data = node.parentData;
      if (data is SliverMultiBoxAdaptorParentData) {
        return data.index;
      }
      node = node.parent;
    }
    return null;
  }

  double get _leadingAxisPadding {
    var total = 0.0;
    RenderObject? node = this;
    while (node != null) {
      if (node is RenderSliverEdgeInsetsPadding) {
        total += node.beforePadding;
      }
      node = node.parent;
    }
    return total;
  }

  double get _precedingScrollExtent {
    RenderObject? node = this;
    while (node != null) {
      if (node is RenderSliver) {
        return node.constraints.precedingScrollExtent;
      }
      node = node.parent;
    }
    return 0.0;
  }

  @override
  void performLayout() {
    size = child != null
        ? ChildLayoutHelper.layoutChild(child!, constraints)
        : constraints.smallest;
    controller._registerSize(
      index,
      size,
      this,
      _physicalSliverIndex,
      _leadingAxisPadding,
      _precedingScrollExtent,
      _hasFingerprintSnapshot,
      _fingerprintSnapshot,
    );
  }

  @override
  void detach() {
    controller._unregisterLiveOwner(this, index: index);
    super.detach();
  }
}

/// A separator wrapper that reports its size independently from a list row.
///
/// Created internally by [IndexedScrollController.separator]; not part of
/// the public API.
class _IndexedScrollSeparator extends SingleChildRenderObjectWidget {
  final IndexedScrollController controller;

  final int index;

  const _IndexedScrollSeparator({
    required this.controller,
    required this.index,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIndexedScrollSeparator(
        index: index,
        controller: controller,
      );

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderObject renderObject) {
    (renderObject as _RenderIndexedScrollSeparator)
      ..index = index
      ..controller = controller;
  }
}

class _RenderIndexedScrollSeparator extends RenderProxyBox {
  int _index;
  IndexedScrollController _controller;

  _RenderIndexedScrollSeparator({
    RenderBox? child,
    required int index,
    required IndexedScrollController controller,
  })  : _index = index,
        _controller = controller,
        super(child);

  int get index => _index;

  set index(int value) {
    if (_index == value) return;
    if (attached) {
      _controller._unregisterLiveSeparatorOwner(this, index: _index);
    }
    _index = value;
    markNeedsLayout();
  }

  IndexedScrollController get controller => _controller;

  set controller(IndexedScrollController value) {
    if (_controller == value) return;
    if (attached) {
      _controller._unregisterLiveSeparatorOwner(this, index: _index);
    }
    _controller = value;
    markNeedsLayout();
  }

  void invalidateMeasurement() => markNeedsLayout();

  bool get _isNestedInsideOwnRow {
    RenderObject? node = parent;
    while (node != null) {
      if (node is _RenderIndexedScrollItem) {
        return node.index == index;
      }
      node = node.parent;
    }
    return false;
  }

  @override
  void performLayout() {
    size = child != null
        ? ChildLayoutHelper.layoutChild(child!, constraints)
        : constraints.smallest;
    if (_isNestedInsideOwnRow) {
      throw StateError(
        'separator(index: $index) is nested inside watch(index: $index)\'s '
        'own subtree. separator() is for the ListView.separated form, where '
        'the item and its separator are SIBLING slots in the sliver -- '
        'nesting separator() inside the row it follows double-counts the '
        'separator, since that row\'s watch() already measures the '
        'separator as part of its own extent. If the separator lives inside '
        'the same Column/Row as the item (the form ListView.builder + one '
        'watch() per row documents), leave it as an ordinary child; do not '
        'wrap it with separator() at all -- alignmentTarget: item is not '
        'available in that form.',
      );
    }
    controller._registerSeparatorSize(index, size, this);
  }

  @override
  void detach() {
    controller._unregisterLiveSeparatorOwner(this, index: index);
    super.detach();
  }
}
