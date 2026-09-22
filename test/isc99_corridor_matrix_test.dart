import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'support/scroll_harness.dart';

/// ISC-99: the acceptance matrix for the fingerprint-corridor / live-offset
/// contract landed by ISC-95..ISC-98, covering combinations no earlier file
/// exercises together -- forward-direction dirty walks, a missing stored
/// fingerprint anywhere in the corridor, mismatches sitting at both corridor
/// edges at once, `reverse`, `ListView.separated`, axis padding, RTL,
/// non-zero `alignment`, and cancellation while the new corridor-walk /
/// `_reflowFromContentStart` phases are in flight -- none of which the
/// ISC-96/97/98 probe files, written to pin down one mechanism at a time,
/// ever combined with each other.
void main() {
  testWidgets(
      'forward dirty corridor: scrollTo(80) after scrollTo(10) refreshes changes between 10 and 80',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 80;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [20, 35, 55, 70];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(10, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[10]), isNotNull,
        reason: 'the experiment must begin around row 10');

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    final registrationsBeforeWalk = <int, int>{
      for (final index in changedIndices)
        index: controller.registrationCountFor(index)
    };

    await pumpUntilComplete(tester,
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    for (final index in changedIndices) {
      expect(
        controller.registrationCountFor(index),
        greaterThan(registrationsBeforeWalk[index]!),
        reason:
            'changed row $index must get a fresh layout while the forward walk passes over it',
      );
      expect(controller.fingerprintFor(index), revisions[index]);
    }
    expect(
      _onScreenDelta(listKey, rowKeys[targetIndex]),
      closeTo(0, 0.5),
      reason:
          'scrollTo must put row $targetIndex at the viewport start after a forward dirty walk',
    );
  });

  testWidgets(
      'mismatches at both corridor edges: scrollTo(70) after scrollTo(20) with changes at 21 and 69',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 70;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [21, 69];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(20, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[20]), isNotNull);

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += 30.0;
        revisions[index]++;
      }
    });

    await pumpUntilComplete(tester,
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    for (final index in changedIndices) {
      expect(controller.fingerprintFor(index), revisions[index],
          reason: 'row $index at a corridor edge must be refreshed');
    }
    expect(
      _onScreenDelta(listKey, rowKeys[targetIndex]),
      closeTo(0, 0.5),
      reason:
          'both-edge mismatches must not prevent target materialization at the correct offset',
    );
  });

  testWidgets(
      'a missing stored fingerprint anywhere in the corridor makes it dirty even with unchanged geometry',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 40;
    const initialHeights = [40.0, 50.0, 60.0];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: ListView.builder(
                key: listKey,
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(
                    key: rowKeyFor(index),
                    height: rowHeights[index],
                    child: Text('Row $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));
    expect(controller.hasFingerprintFor(30), isTrue,
        reason: 'row 30 must have been measured on the way to 90');

    // Simulate a lost registration -- e.g. a size cache entry evicted by
    // invalidateMeasurements()'s per-row API used unconventionally -- by
    // asserting the corridor walk treats an absent fingerprint as dirty; this
    // package has no direct "forget one row" API, so this test instead
    // documents and locks in the *contract* by relying on the never-measured
    // rows between 90 and target 40 (this ListView.builder never rebuilt
    // them individually since first materializing) -- rows above the highest
    // ever measured position are the naturally occurring case where a stored
    // fingerprint is absent for part of the corridor.
    controller.invalidateMeasurements();
    await tester.pump();
    expect(controller.hasFingerprintFor(30), isFalse,
        reason:
            'invalidateMeasurements must drop stored fingerprints for the missing-fingerprint scenario');

    await pumpUntilComplete(tester,
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    expect(controller.hasFingerprintFor(targetIndex), isTrue);
    expect(
      _onScreenDelta(listKey, rowKeys[targetIndex]),
      closeTo(0, 0.5),
      reason:
          'a corridor with missing fingerprints must still converge on the correct final offset',
    );
  });

  testWidgets(
      'reverse: dirty corridor walk still lands the target flush with the viewport\'s visual start',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 20;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [55, 64, 70, 81];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    reverse: true,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[90]), isNotNull);

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    await pumpUntilComplete(tester,
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    for (final index in changedIndices) {
      expect(controller.fingerprintFor(index), revisions[index]);
    }
    // Measured: under reverse: true, row.top == list.top at alignment: 0 --
    // scrollTo's target row is aligned within the render-box's own local
    // frame the same way as the non-reversed case (top edge for alignment:
    // 0); the axis flip that puts item 0 at the visual bottom is entirely
    // internal to how position.pixels maps onto layoutOffset, and does not
    // change which local edge alignment: 0 refers to.
    final listBox = listKey.currentContext!.findRenderObject()! as RenderBox;
    final rowBox =
        rowKeys[targetIndex]!.currentContext!.findRenderObject()! as RenderBox;
    final rowTop = rowBox.localToGlobal(Offset.zero).dy;
    final listTop = listBox.localToGlobal(Offset.zero).dy;
    expect(
      rowTop - listTop,
      closeTo(0, 0.5),
      reason:
          'reverse: true dirty corridor walk must put row $targetIndex at alignment: 0\'s target edge',
    );
  });

  testWidgets(
      'ListView.separated: dirty corridor walk with alignmentTarget.item lands past the preceding separator',
      (tester) async {
    const itemCount = 60;
    const viewportHeight = 400.0;
    const targetIndex = 45;
    const initialHeights = [40.0, 50.0];
    const separatorHeight = 8.0;
    const changedIndices = [15, 30];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.separated(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                    separatorBuilder: (context, index) => controller.separator(
                      index: index,
                      child: const SizedBox(height: separatorHeight),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(58, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[58]), isNotNull);

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += 20.0;
        revisions[index]++;
      }
    });

    await pumpUntilComplete(
      tester,
      controller.scrollTo(targetIndex.toDouble(),
          duration: Duration.zero, alignmentTarget: ScrollAlignmentTarget.item),
    );

    for (final index in changedIndices) {
      expect(controller.fingerprintFor(index), revisions[index]);
    }
    expect(
      _onScreenDelta(listKey, rowKeys[targetIndex]),
      closeTo(0, 0.5),
      reason:
          'separated list dirty corridor walk with alignmentTarget.item must land row $targetIndex flush with the viewport start',
    );
  });

  testWidgets(
      'axis padding: dirty corridor walk accounts for leading padding in the final live offset',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 60;
    const leadingPadding = 30.0;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [15, 40];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    padding: const EdgeInsets.only(top: leadingPadding),
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[90]), isNotNull);

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += 25.0;
        revisions[index]++;
      }
    });

    await pumpUntilComplete(tester,
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    for (final index in changedIndices) {
      expect(controller.fingerprintFor(index), revisions[index]);
    }
    expect(
      _onScreenDelta(listKey, rowKeys[targetIndex]),
      closeTo(0, 0.5),
      reason:
          'leading axis padding must still be honored by the final live-offset read after a dirty walk',
    );
  });

  testWidgets(
      'RTL horizontal: dirty corridor walk lands the target at the correct visual edge',
      (tester) async {
    const itemCount = 80;
    const viewportWidth = 500.0;
    const targetIndex = 50;
    const initialWidths = [60.0, 80.0, 100.0];
    const changedIndices = [10, 25];

    final rowWidths = List<double>.generate(
        itemCount, (index) => initialWidths[index % initialWidths.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: viewportWidth,
                height: 200.0,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setOuterState = setState;
                    return ListView.builder(
                      key: listKey,
                      controller: controller,
                      scrollDirection: Axis.horizontal,
                      itemCount: itemCount,
                      itemBuilder: (context, index) => controller.watch(
                        index: index,
                        child: SizedBox(
                          key: rowKeyFor(index),
                          width: rowWidths[index],
                          child: Text('Row $index'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(5, duration: Duration.zero));
    expect(_sliverLayoutOffsetOf(rowKeys[5]), isNotNull);

    setOuterState(() {
      for (final index in changedIndices) {
        rowWidths[index] += 20.0;
        revisions[index]++;
      }
    });

    await pumpUntilComplete(tester,
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    for (final index in changedIndices) {
      expect(controller.fingerprintFor(index), revisions[index]);
    }
    // RTL without reverse resolves _isReversed to true (see
    // scroll_to_horizontal_edge_cases_test.dart), which inverts
    // effectiveAlignment, not which local edge alignment: 0 refers to (see
    // the reverse: true test above for the same distinction) -- alignment: 0
    // still aligns the row's LEFT edge (its own local start) with the
    // viewport's left edge.
    final listBox = listKey.currentContext!.findRenderObject()! as RenderBox;
    final rowBox =
        rowKeys[targetIndex]!.currentContext!.findRenderObject()! as RenderBox;
    final rowLeft = rowBox.localToGlobal(Offset.zero).dx;
    final listLeft = listBox.localToGlobal(Offset.zero).dx;
    expect(
      rowLeft - listLeft,
      closeTo(0, 0.5),
      reason:
          'RTL dirty corridor walk must land row $targetIndex at alignment: 0\'s target edge',
    );
  });

  testWidgets(
      'alignment: 0.5 and alignment: 1.0 after a dirty corridor walk still center/end the target correctly',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 60;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [20, 40];

    for (final alignment in [0.5, 1.0]) {
      final rowHeights = List<double>.generate(
          itemCount, (index) => initialHeights[index % initialHeights.length]);
      final revisions = List<int>.filled(itemCount, 0);
      final rowKeys = <int, GlobalKey>{};
      final listKey = GlobalKey();
      final controller = IndexedScrollController(
        scrollDuration: Duration.zero,
        itemCount: () => itemCount,
        contentFingerprint: (index) => revisions[index],
      );
      late StateSetter setOuterState;
      addTearDown(controller.dispose);

      GlobalKey rowKeyFor(int index) =>
          rowKeys.putIfAbsent(index, GlobalKey.new);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                height: viewportHeight,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setOuterState = setState;
                    return ListView.builder(
                      key: listKey,
                      controller: controller,
                      itemCount: itemCount,
                      itemBuilder: (context, index) => controller.watch(
                        index: index,
                        child: SizedBox(
                          key: rowKeyFor(index),
                          height: rowHeights[index],
                          child: Text('Row $index'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await pumpUntilComplete(
          tester, controller.scrollTo(90, duration: Duration.zero));

      setOuterState(() {
        for (final index in changedIndices) {
          rowHeights[index] += 25.0;
          revisions[index]++;
        }
      });

      await pumpUntilComplete(
          tester,
          controller.scrollTo(targetIndex.toDouble(),
              duration: Duration.zero, alignment: alignment));

      final listBox = listKey.currentContext!.findRenderObject()! as RenderBox;
      final rowBox = rowKeys[targetIndex]!.currentContext!.findRenderObject()!
          as RenderBox;
      final rowTop = rowBox.localToGlobal(Offset.zero).dy;
      final listTop = listBox.localToGlobal(Offset.zero).dy;
      final viewportHeightActual = listBox.size.height;
      final expectedTop =
          (viewportHeightActual - rowBox.size.height) * alignment;
      expect(
        rowTop - listTop,
        closeTo(expectedTop, 0.5),
        reason:
            'alignment: $alignment after a dirty corridor walk must place row $targetIndex at the aligned position',
      );
    }
  });

  testWidgets(
      'cancelScroll() during the dirty corridor walk cancels with explicitCancel',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 20;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [55, 64, 70, 81];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    final operation =
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero);
    Object? error;
    var done = false;
    operation.then(
      (_) {
        done = true;
      },
      onError: (Object e) {
        done = true;
        error = e;
      },
    );

    // One pump lets the walk begin (its first jumpTo + endOfFrame) without
    // letting it run to completion, so the cancel below genuinely lands
    // mid-walk rather than after the operation already finished.
    await tester.pump(const Duration(milliseconds: 16));
    controller.cancelScroll();

    for (var i = 0; i < 300 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(done, isTrue,
        reason:
            'scrollTo must not hang after cancelScroll() during the corridor walk');
    expect(error, isA<ScrollCancelledException>());
    expect((error as ScrollCancelledException).reason,
        ScrollCancelReason.explicitCancel);
  });

  testWidgets(
      'repeated scrollTo calls to different dirty targets each converge to their own correct offset',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const initialHeights = [40.0, 50.0, 60.0];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));

    for (final targetIndex in [30, 70, 10]) {
      setOuterState(() {
        final changed = (targetIndex + 15) % itemCount;
        rowHeights[changed] += 22.0;
        revisions[changed]++;
      });
      await pumpUntilComplete(tester,
          controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));
      expect(
        _onScreenDelta(listKey, rowKeys[targetIndex]),
        closeTo(0, 0.5),
        reason:
            'repeated scrollTo($targetIndex) must land flush with the viewport start each time',
      );
    }
  });

  testWidgets(
      'near-end clamp with a dirty corridor: target near the last index still converges without overshoot',
      (tester) async {
    const itemCount = 40;
    const viewportHeight = 500.0;
    const targetIndex = 39;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [5, 10];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(0, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += 25.0;
        revisions[index]++;
      }
    });

    await pumpUntilComplete(tester,
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    // maxScrollExtent is a lazy sliver's ESTIMATE, not exact geometry (see
    // todo.md's "two sources of truth" invariant), so the clamp must be
    // proven by an observable visual property instead of comparing against
    // it: the last row is materialized and its bottom edge does not extend
    // past the viewport's bottom edge -- an alignment: 0 request for the
    // final row of a short list genuinely cannot put the row flush with the
    // viewport TOP without leaving empty space below the content, so the
    // physical bound must have clamped the position upward from the raw
    // formula's request.
    expect(_sliverLayoutOffsetOf(rowKeys[targetIndex]), isNotNull,
        reason: 'the last row must be materialized after the dirty walk');
    final listBox = listKey.currentContext!.findRenderObject()! as RenderBox;
    final rowBox =
        rowKeys[targetIndex]!.currentContext!.findRenderObject()! as RenderBox;
    final rowBottom = rowBox.localToGlobal(Offset(0, rowBox.size.height)).dy;
    final listBottom = listBox.localToGlobal(Offset(0, listBox.size.height)).dy;
    expect(
      rowBottom,
      lessThanOrEqualTo(listBottom + 0.5),
      reason:
          'the last row\'s bottom edge must not extend past the viewport\'s bottom edge -- the physical bound, '
          'not an alignment: 0 overshoot, must govern the clamp',
    );
  });

  testWidgets(
      'unchanged data: a repeat scrollTo to the same already-live target costs no extra corridor walk',
      (tester) async {
    // ISC-99's acceptance criterion requires the clean-corridor path to keep
    // matching ISC-82d's timing contract; this exercises it specifically
    // through the same StatefulBuilder harness style the dirty-corridor
    // tests above use, rather than isc82d's own dedicated stopwatch-based
    // file, to prove the new corridor machinery adds no per-call cost when
    // nothing changed between two calls to the same target.
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 50;
    const initialHeights = [40.0, 50.0, 60.0];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: ListView.builder(
                key: listKey,
                controller: controller,
                itemCount: itemCount,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(
                    key: rowKeyFor(index),
                    height: rowHeights[index],
                    child: Text('Row $index'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));
    await pumpUntilComplete(tester,
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero));

    var pumps = 0;
    final second =
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero);
    var done = false;
    second.then((_) => done = true, onError: (_) => done = true);
    while (!done && pumps < 10) {
      await tester.pump(const Duration(milliseconds: 16));
      pumps++;
    }
    await second;
    expect(pumps, lessThanOrEqualTo(2),
        reason:
            'a repeat scrollTo to the same already-live target must resolve near-synchronously');
  });

  testWidgets(
      'a user drag during a dirty corridor walk cancels scrollTo with userGesture',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 20;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [55, 64, 70, 81];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    final list = ListView.builder(
      controller: controller,
      itemCount: itemCount,
      itemBuilder: (context, index) => controller.watch(
        index: index,
        child: SizedBox(height: rowHeights[index], child: Text('Row $index')),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return IndexedScrollGestureDetector(
                      controller: controller, child: list);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    Object? error;
    var done = false;
    unawaited(
      controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero).then(
        (_) {
          done = true;
        },
        onError: (Object e) {
          done = true;
          error = e;
        },
      ),
    );

    // Let the corridor walk genuinely begin (its first jumpTo + endOfFrame)
    // before the drag interrupts it.
    await tester.pump(const Duration(milliseconds: 16));

    final gesture = await tester.startGesture(const Offset(200, 300));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    await gesture.up();

    for (var i = 0; i < 300 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(done, isTrue,
        reason:
            'scrollTo must not hang after a user drag interrupts the corridor walk');
    expect(error, isA<ScrollCancelledException>());
    expect((error as ScrollCancelledException).reason,
        ScrollCancelReason.userGesture);
  });

  testWidgets(
      'invalidateMeasurements() during a dirty corridor walk cancels with dataInvalidated',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 20;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [55, 64, 70, 81];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    Object? error;
    var done = false;
    unawaited(
      controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero).then(
        (_) {
          done = true;
        },
        onError: (Object e) {
          done = true;
          error = e;
        },
      ),
    );

    await tester.pump(const Duration(milliseconds: 16));
    controller.invalidateMeasurements();

    for (var i = 0; i < 300 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(done, isTrue,
        reason:
            'scrollTo must not hang after invalidateMeasurements() during the corridor walk');
    expect(error, isA<ScrollCancelledException>());
    expect((error as ScrollCancelledException).reason,
        ScrollCancelReason.dataInvalidated);
  });

  testWidgets(
      'near-start clamp with a dirty corridor: alignment 1.0 near index 0 clamps instead of going negative',
      (tester) async {
    const itemCount = 60;
    const viewportHeight = 500.0;
    const targetIndex = 2;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [40, 55];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(55, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += 25.0;
        revisions[index]++;
      }
    });

    await pumpUntilComplete(
        tester,
        controller.scrollTo(targetIndex.toDouble(),
            duration: Duration.zero, alignment: 1.0));

    final position = controller.position;
    expect(
      position.pixels,
      closeTo(position.minScrollExtent, 0.5),
      reason:
          'alignment: 1.0 on a low index must clamp to minScrollExtent instead of the raw formula\'s negative result',
    );
  });

  testWidgets(
      'fractional target index after a dirty corridor walk lands at the exact sub-row offset',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 60.5;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [20, 40];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += 25.0;
        revisions[index]++;
      }
    });

    await pumpUntilComplete(
        tester, controller.scrollTo(targetIndex, duration: Duration.zero));

    final targetItemIndex = targetIndex.truncate();
    final fraction = targetIndex - targetItemIndex;
    final rowBox = rowKeys[targetItemIndex]!.currentContext!.findRenderObject()!
        as RenderBox;
    final listBox = listKey.currentContext!.findRenderObject()! as RenderBox;
    final expectedTop = -(rowBox.size.height * fraction);
    final rowTop = rowBox.localToGlobal(Offset.zero).dy;
    final listTop = listBox.localToGlobal(Offset.zero).dy;
    expect(
      rowTop - listTop,
      closeTo(expectedTop, 0.5),
      reason:
          'a fractional target after a dirty corridor walk must land the sub-row offset exactly',
    );
  });

  testWidgets(
      'a second scrollTo during a dirty corridor walk supersedes the first, which cancels with superseded',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const firstTarget = 20;
    const secondTarget = 60;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [55, 64, 70, 81];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    GlobalKey rowKeyFor(int index) => rowKeys.putIfAbsent(index, GlobalKey.new);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    key: listKey,
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                        key: rowKeyFor(index),
                        height: rowHeights[index],
                        child: Text('Row $index'),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    Object? firstError;
    var firstDone = false;
    unawaited(
      controller.scrollTo(firstTarget.toDouble(), duration: Duration.zero).then(
        (_) {
          firstDone = true;
        },
        onError: (Object e) {
          firstDone = true;
          firstError = e;
        },
      ),
    );

    // Let the first walk's corridor recovery genuinely begin (its first
    // jumpTo + endOfFrame check-in) before it is superseded.
    await tester.pump(const Duration(milliseconds: 16));
    expect(firstDone, isFalse,
        reason:
            'the first walk must still be in flight when the second call supersedes it');

    Object? secondError;
    var secondDone = false;
    unawaited(
      controller
          .scrollTo(secondTarget.toDouble(), duration: Duration.zero)
          .then(
        (_) {
          secondDone = true;
        },
        onError: (Object e) {
          secondDone = true;
          secondError = e;
        },
      ),
    );

    for (var i = 0; i < 300 && !(firstDone && secondDone); i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(firstDone, isTrue);
    expect(secondDone, isTrue);
    expect(firstError, isA<ScrollCancelledException>());
    expect((firstError as ScrollCancelledException).reason,
        ScrollCancelReason.superseded);
    expect(secondError, isNull,
        reason:
            'the second, more recent call must reach its own target uncontested');
    expect(
      _onScreenDelta(listKey, rowKeys[secondTarget]),
      closeTo(0, 0.5),
      reason:
          'the superseding call must still complete its own dirty-corridor walk and land flush with the viewport start',
    );
  });

  testWidgets(
      'detach during a dirty corridor walk cancels with detached instead of hanging',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 20;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [55, 64, 70, 81];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                          height: rowHeights[index], child: Text('Row $index')),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    Object? error;
    var done = false;
    unawaited(
      controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero).then(
        (_) {
          done = true;
        },
        onError: (Object e) {
          done = true;
          error = e;
        },
      ),
    );

    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(done, isFalse,
        reason:
            'the dirty corridor walk must still be in flight three frames in, or the detach below tests nothing');

    // Unmount the Scrollable so the framework performs the one real detach,
    // matching scroll_to_concurrency_test.dart's pattern (a manual detach()
    // races the framework's own detach-on-unmount and throws a different,
    // harness-specific assertion).
    await tester.pumpWidget(const SizedBox.shrink());

    for (var i = 0; i < 300 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(done, isTrue,
        reason: 'scrollTo must not hang after detach during the corridor walk');
    expect(error, isA<ScrollCancelledException>());
    expect((error as ScrollCancelledException).reason,
        ScrollCancelReason.detached);
  });

  testWidgets(
      'dispose during a dirty corridor walk cancels with disposed instead of continuing to drive the position',
      (tester) async {
    const itemCount = 100;
    const viewportHeight = 500.0;
    const targetIndex = 20;
    const initialHeights = [40.0, 50.0, 60.0];
    const changedIndices = [55, 64, 70, 81];

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    // No addTearDown(controller.dispose) here -- the test disposes it itself
    // mid-walk, and a second dispose() call would be redundant at best.

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: viewportHeight,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuterState = setState;
                  return ListView.builder(
                    controller: controller,
                    itemCount: itemCount,
                    itemBuilder: (context, index) => controller.watch(
                      index: index,
                      child: SizedBox(
                          height: rowHeights[index], child: Text('Row $index')),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await pumpUntilComplete(
        tester, controller.scrollTo(90, duration: Duration.zero));

    setOuterState(() {
      for (final index in changedIndices) {
        rowHeights[index] += index.isEven ? 35.0 : -25.0;
        revisions[index]++;
      }
    });

    Object? error;
    var done = false;
    unawaited(
      controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero).then(
        (_) {
          done = true;
        },
        onError: (Object e) {
          done = true;
          error = e;
        },
      ),
    );

    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(done, isFalse,
        reason:
            'the dirty corridor walk must still be in flight three frames in, or the dispose below tests nothing');

    controller.dispose();

    for (var i = 0; i < 300 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(done, isTrue,
        reason:
            'scrollTo must not hang after dispose during the corridor walk');
    expect(error, isA<ScrollCancelledException>());
    expect((error as ScrollCancelledException).reason,
        ScrollCancelReason.disposed);

    // Unmount before the test ends so the disposed controller is not left
    // attached to a live Scrollable.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // The three tests above (supersede/detach/dispose) all use a corridor
  // where every mismatch sits ABOVE the target (90 -> 20, changes at
  // 55/64/70/81), so sawBelowTargetMismatch is always false and
  // _reflowFromContentStart never runs -- they only exercise
  // _alignGeometryWithCache's own endOfFrame boundaries. This scenario is
  // the one isc96_contiguous_viewport_walk_probe_test.dart's own
  // 'reflows from row 0' test uses (90 -> 70, growing rows 15 and 60, both
  // BELOW the target): that combination is what forces
  // _reflowFromContentStart to run, so the three tests below repeat it and
  // interrupt the operation only after observing row 0's own live
  // layoutOffset reach its sliver-local zero -- the same
  // "sawContentStart" signal that file's own mechanism test uses to prove
  // the reflow phase, not just the corridor walk, is genuinely in flight.
  Future<Widget> buildReflowScenario(
    WidgetTester tester, {
    required IndexedScrollController controller,
    required List<double> rowHeights,
    required List<int> revisions,
    required Map<int, GlobalKey> rowKeys,
    required GlobalKey listKey,
    required void Function(StateSetter) captureSetState,
  }) async {
    const itemCount = 100;
    const viewportHeight = 500.0;

    final widget = MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            height: viewportHeight,
            child: StatefulBuilder(
              builder: (context, setState) {
                captureSetState(setState);
                return ListView.builder(
                  key: listKey,
                  controller: controller,
                  itemCount: itemCount,
                  itemBuilder: (context, index) => controller.watch(
                    index: index,
                    child: SizedBox(
                      key: rowKeys.putIfAbsent(index, GlobalKey.new),
                      height: rowHeights[index],
                      child: Text('Row $index'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
    return widget;
  }

  testWidgets(
      'supersede during an in-flight prefix reflow (below-target mismatch) cancels the first with superseded',
      (tester) async {
    const itemCount = 100;
    const startIndex = 90;
    const targetIndex = 70;
    const secondTarget = 40;
    const initialHeights = [40.0, 50.0, 60.0];
    const firstChangedIndex = 15;
    const secondChangedIndex = 60;

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    await buildReflowScenario(
      tester,
      controller: controller,
      rowHeights: rowHeights,
      revisions: revisions,
      rowKeys: rowKeys,
      listKey: listKey,
      captureSetState: (setState) => setOuterState = setState,
    );

    await pumpUntilComplete(tester,
        controller.scrollTo(startIndex.toDouble(), duration: Duration.zero));

    setOuterState(() {
      rowHeights[firstChangedIndex] += 60.0;
      revisions[firstChangedIndex]++;
      rowHeights[secondChangedIndex] += 60.0;
      revisions[secondChangedIndex]++;
    });

    Object? firstError;
    var firstDone = false;
    final first =
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero);
    first.then(
      (_) {
        firstDone = true;
      },
      onError: (Object e) {
        firstDone = true;
        firstError = e;
      },
    );

    var sawContentStart = false;
    for (var i = 0; i < 300 && !sawContentStart; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final row0Offset = _sliverLayoutOffsetOf(rowKeys[0]);
      if (row0Offset != null && row0Offset.abs() <= 0.5) sawContentStart = true;
    }
    expect(sawContentStart, isTrue,
        reason:
            'the reflow must reach row 0 before the interruption below tests the reflow phase');
    expect(firstDone, isFalse,
        reason:
            'the first scrollTo must still be in flight when the second call supersedes it');

    Object? secondError;
    var secondDone = false;
    final second =
        controller.scrollTo(secondTarget.toDouble(), duration: Duration.zero);
    second.then(
      (_) {
        secondDone = true;
      },
      onError: (Object e) {
        secondDone = true;
        secondError = e;
      },
    );

    for (var i = 0; i < 300 && !(firstDone && secondDone); i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(firstDone, isTrue);
    expect(secondDone, isTrue);
    expect(firstError, isA<ScrollCancelledException>());
    expect((firstError as ScrollCancelledException).reason,
        ScrollCancelReason.superseded);
    expect(secondError, isNull,
        reason:
            'the second, more recent call must reach its own target uncontested');
    expect(
      _onScreenDelta(listKey, rowKeys[secondTarget]),
      closeTo(0, 0.5),
      reason:
          'the superseding call must complete its own scrollTo and land flush with the viewport start',
    );
  });

  testWidgets(
      'detach during an in-flight prefix reflow (below-target mismatch) cancels with detached',
      (tester) async {
    const itemCount = 100;
    const startIndex = 90;
    const targetIndex = 70;
    const initialHeights = [40.0, 50.0, 60.0];
    const firstChangedIndex = 15;
    const secondChangedIndex = 60;

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    addTearDown(controller.dispose);

    await buildReflowScenario(
      tester,
      controller: controller,
      rowHeights: rowHeights,
      revisions: revisions,
      rowKeys: rowKeys,
      listKey: listKey,
      captureSetState: (setState) => setOuterState = setState,
    );

    await pumpUntilComplete(tester,
        controller.scrollTo(startIndex.toDouble(), duration: Duration.zero));

    setOuterState(() {
      rowHeights[firstChangedIndex] += 60.0;
      revisions[firstChangedIndex]++;
      rowHeights[secondChangedIndex] += 60.0;
      revisions[secondChangedIndex]++;
    });

    Object? error;
    var done = false;
    final operation =
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero);
    operation.then(
      (_) {
        done = true;
      },
      onError: (Object e) {
        done = true;
        error = e;
      },
    );

    var sawContentStart = false;
    for (var i = 0; i < 300 && !sawContentStart; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final row0Offset = _sliverLayoutOffsetOf(rowKeys[0]);
      if (row0Offset != null && row0Offset.abs() <= 0.5) sawContentStart = true;
    }
    expect(sawContentStart, isTrue,
        reason:
            'the reflow must reach row 0 before the detach below tests the reflow phase');
    expect(done, isFalse,
        reason:
            'the reflow must still be in flight when the detach below interrupts it');

    // Unmount so the framework performs the one real detach, matching
    // scroll_to_concurrency_test.dart's pattern.
    await tester.pumpWidget(const SizedBox.shrink());

    for (var i = 0; i < 300 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(done, isTrue,
        reason: 'scrollTo must not hang after detach during the prefix reflow');
    expect(error, isA<ScrollCancelledException>());
    expect((error as ScrollCancelledException).reason,
        ScrollCancelReason.detached);
  });

  testWidgets(
      'dispose during an in-flight prefix reflow (below-target mismatch) cancels with disposed',
      (tester) async {
    const itemCount = 100;
    const startIndex = 90;
    const targetIndex = 70;
    const initialHeights = [40.0, 50.0, 60.0];
    const firstChangedIndex = 15;
    const secondChangedIndex = 60;

    final rowHeights = List<double>.generate(
        itemCount, (index) => initialHeights[index % initialHeights.length]);
    final revisions = List<int>.filled(itemCount, 0);
    final rowKeys = <int, GlobalKey>{};
    final listKey = GlobalKey();
    final controller = IndexedScrollController(
      scrollDuration: Duration.zero,
      itemCount: () => itemCount,
      contentFingerprint: (index) => revisions[index],
    );
    late StateSetter setOuterState;
    // No addTearDown(controller.dispose) -- this test disposes it itself
    // mid-reflow.

    await buildReflowScenario(
      tester,
      controller: controller,
      rowHeights: rowHeights,
      revisions: revisions,
      rowKeys: rowKeys,
      listKey: listKey,
      captureSetState: (setState) => setOuterState = setState,
    );

    await pumpUntilComplete(tester,
        controller.scrollTo(startIndex.toDouble(), duration: Duration.zero));

    setOuterState(() {
      rowHeights[firstChangedIndex] += 60.0;
      revisions[firstChangedIndex]++;
      rowHeights[secondChangedIndex] += 60.0;
      revisions[secondChangedIndex]++;
    });

    Object? error;
    var done = false;
    final operation =
        controller.scrollTo(targetIndex.toDouble(), duration: Duration.zero);
    operation.then(
      (_) {
        done = true;
      },
      onError: (Object e) {
        done = true;
        error = e;
      },
    );

    var sawContentStart = false;
    for (var i = 0; i < 300 && !sawContentStart; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final row0Offset = _sliverLayoutOffsetOf(rowKeys[0]);
      if (row0Offset != null && row0Offset.abs() <= 0.5) sawContentStart = true;
    }
    expect(sawContentStart, isTrue,
        reason:
            'the reflow must reach row 0 before the dispose below tests the reflow phase');
    expect(done, isFalse,
        reason:
            'the reflow must still be in flight when dispose below interrupts it');

    controller.dispose();

    for (var i = 0; i < 300 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(done, isTrue,
        reason:
            'scrollTo must not hang after dispose during the prefix reflow');
    expect(error, isA<ScrollCancelledException>());
    expect((error as ScrollCancelledException).reason,
        ScrollCancelReason.disposed);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

double? _sliverLayoutOffsetOf(GlobalKey? key) {
  final renderObject = key?.currentContext?.findRenderObject();
  if (renderObject == null || !renderObject.attached) return null;
  for (RenderObject? node = renderObject; node != null; node = node.parent) {
    final parentData = node.parentData;
    if (parentData is SliverMultiBoxAdaptorParentData) {
      return parentData.layoutOffset;
    }
  }
  return null;
}

double? _onScreenDelta(GlobalKey listKey, GlobalKey? rowKey) {
  final list = listKey.currentContext?.findRenderObject();
  final row = rowKey?.currentContext?.findRenderObject();
  if (list is! RenderBox || row is! RenderBox || !row.attached) return null;
  return row.localToGlobal(Offset.zero).dy - list.localToGlobal(Offset.zero).dy;
}
