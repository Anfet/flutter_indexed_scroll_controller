part of 'indexed_scroll_controller.dart';

class IndexedScrollItem extends SingleChildRenderObjectWidget {
  final IndexedScrollController controller;
  final int index;

  const IndexedScrollItem({
    super.key,
    required this.controller,
    required this.index,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderIndexedScrollItem(
        index: index,
        controller: controller,
      );

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) {
    (renderObject as _RenderIndexedScrollItem)
      ..index = index
      ..controller = controller;
  }
}

class _RenderIndexedScrollItem extends RenderProxyBox {
  int _index;
  IndexedScrollController _controller;

  _RenderIndexedScrollItem({
    RenderBox? child,
    required int index,
    required IndexedScrollController controller,
  })  : _index = index,
        _controller = controller,
        super(child);

  /// Forces this row's next frame to run [performLayout] again, so
  /// [IndexedScrollController._registerSize] re-registers a fresh size
  /// instead of leaving whatever stale entry [invalidateMeasurements]
  /// cleared. Called by [IndexedScrollController.invalidateMeasurements]
  /// (ISC-31) on every currently-live row: a row's `RenderBox.size` is only
  /// ever current as of its last completed layout, and a data mutation
  /// followed immediately by invalidation (no intervening frame) does not by
  /// itself guarantee a relayout already happened.
  void invalidateMeasurement() => markNeedsLayout();

  int get index => _index;

  /// ISC-35: reassigning `index` on an already-attached row (via
  /// [IndexedScrollItem.updateRenderObject]) must not leave the OLD index's
  /// live-registration entry pointing at this object inside the CURRENT
  /// [_controller]. [detach] only ever unregisters this object from
  /// whichever controller/index it holds AT DETACH TIME -- if the index
  /// changes here first, [detach] can never again reach the old index's
  /// entry under this same controller, so it would otherwise leak for as
  /// long as the controller lives (mirrors the ISC-34 leak, but within one
  /// controller instead of across two). Unregistering here, before `_index`
  /// is updated, still has the old index available and reuses the same
  /// identity-checked removal [detach] uses (ISC-11) -- only removing the
  /// entry if this object is still the one currently registered there,
  /// never blindly deleting whatever another row may have since claimed.
  set index(int value) {
    if (_index == value) return;
    if (attached) {
      _controller._unregisterLiveOwner(this, index: _index);
    }
    _index = value;
    markNeedsLayout();
  }

  IndexedScrollController get controller => _controller;

  /// ISC-35: same reasoning as the [index] setter, but for a controller
  /// switch. [detach] would otherwise only ever notify whichever controller
  /// this object is CURRENTLY assigned to -- once reassigned to a new
  /// controller, the OLD controller is never consulted again, so its
  /// `_liveOwners[oldIndex]` entry for this object would leak for the OLD
  /// controller's entire remaining lifetime (the exact gap ISC-34's test
  /// demonstrated). Unregistering from the OLD controller here, before
  /// `_controller` is updated, closes that gap at the point of reassignment
  /// instead of relying on a detach that will never reach it again.
  set controller(IndexedScrollController value) {
    if (_controller == value) return;
    if (attached) {
      _controller._unregisterLiveOwner(this, index: _index);
    }
    _controller = value;
    markNeedsLayout();
  }

  /// The physical position of this row as assigned by its enclosing sliver
  /// (e.g. `SliverList`/`ListView.builder`), or `null` if no ancestor up to
  /// the render tree root carries a `SliverMultiBoxAdaptorParentData` (for
  /// example, not yet attached, or used outside a supported list).
  ///
  /// ISC-28/ISC-27: `watch(index:)` is documented to equal the physical
  /// position the sliver passes to `itemBuilder`. That position is not
  /// something this widget receives as a constructor argument -- it is
  /// assigned by the parent sliver onto its immediate child's [parentData]
  /// as a [SliverMultiBoxAdaptorParentData.index], confirmed against the
  /// Flutter SDK source (`sliver_multi_box_adaptor.dart`, e.g.
  /// `RenderSliverMultiBoxAdaptor.indexOf`), which reads exactly this field
  /// the same way. Critically, "immediate child" here means the sliver's
  /// direct child in the render tree, not necessarily *this* render object:
  /// `ListView.builder`'s default `SliverChildBuilderDelegate` wraps every
  /// item in `RepaintBoundary` and `AutomaticKeepAlive` (on by default via
  /// `addRepaintBoundaries`/`addAutomaticKeepAlives`), so the sliver's actual
  /// child is one of those wrappers, and `this.parentData` is theirs, not the
  /// sliver's -- confirmed empirically: a direct `parentData` read here
  /// always observed `null` in a real `ListView.builder`, not a
  /// `SliverMultiBoxAdaptorParentData`. This walks up through those wrapper
  /// render objects (there are at most a couple, and the walk stops the
  /// moment a `SliverMultiBoxAdaptorParentData` is found) until it finds the
  /// one immediately parented by the sliver itself, or runs out of parents.
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

  @override
  void performLayout() {
    size = child != null ? ChildLayoutHelper.layoutChild(child!, constraints) : constraints.smallest;
    controller._registerSize(index, size, this, _physicalSliverIndex);
  }

  @override
  void detach() {
    controller._unregisterLiveOwner(this, index: index);
    super.detach();
  }
}
