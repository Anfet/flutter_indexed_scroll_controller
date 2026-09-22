import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';
import 'support/scroll_harness.dart';

void main() {
  _errorDeliveryContract();
  group('ISC-03: scrollTo error contract', () {
    testWidgets('scrollTo(-1) throws RangeError', (WidgetTester tester) async {
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 20,
          itemHeightBuilder: (index) => 100.0,
        ),
      );
      final state =
          tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      expect(
        () => state.controller.scrollTo(-1.0),
        throwsA(isA<RangeError>()),
        reason: 'Negative scrollToIndex must be rejected with RangeError',
      );
    });

    testWidgets('scrollTo(double.nan) throws ArgumentError',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 20,
          itemHeightBuilder: (index) => 100.0,
        ),
      );
      final state =
          tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      expect(
        () => state.controller.scrollTo(double.nan),
        throwsA(isA<ArgumentError>()),
        reason: 'NaN scrollToIndex must be rejected with ArgumentError',
      );
    });

    testWidgets('scrollTo(double.infinity) throws ArgumentError',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 20,
          itemHeightBuilder: (index) => 100.0,
        ),
      );
      final state =
          tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      expect(
        () => state.controller.scrollTo(double.infinity),
        throwsA(isA<ArgumentError>()),
        reason: 'Infinite scrollToIndex must be rejected with ArgumentError',
      );
    });

    testWidgets('scrollTo negative duration throws ArgumentError',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 20,
          itemHeightBuilder: (index) => 100.0,
        ),
      );
      final state =
          tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      expect(
        () => state.controller.scrollTo(
          5.0,
          duration: const Duration(milliseconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'Negative duration must be rejected with ArgumentError',
      );
    });

    testWidgets('scrollTo alignment below 0 throws ArgumentError',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 20,
          itemHeightBuilder: (index) => 100.0,
        ),
      );
      final state =
          tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      expect(
        () => state.controller.scrollTo(5.0, alignment: -0.1),
        throwsA(isA<ArgumentError>()),
        reason: 'alignment < 0 must be rejected with ArgumentError',
      );
    });

    testWidgets('scrollTo alignment above 1 throws ArgumentError',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ScrollHarness(
          itemCount: 20,
          itemHeightBuilder: (index) => 100.0,
        ),
      );
      final state =
          tester.state<ScrollHarnessState>(find.byType(ScrollHarness));
      await tester.pumpAndSettle();

      expect(
        () => state.controller.scrollTo(5.0, alignment: 1.1),
        throwsA(isA<ArgumentError>()),
        reason: 'alignment > 1 must be rejected with ArgumentError',
      );
    });

    testWidgets('scrollTo with no attached ScrollPosition throws StateError',
        (WidgetTester tester) async {
      // Controller never attached to any Scrollable: hasClients is false.
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
      );
      addTearDown(controller.dispose);

      expect(controller.hasClients, isFalse);
      expect(
        () => controller.scrollTo(5.0),
        throwsA(isA<StateError>()),
        reason:
            'scrollTo with zero attached positions must be rejected with StateError, '
            'distinguishing "no clients" from "more than one position".',
      );
    });

    testWidgets(
      'parameter validation happens before touching position (RangeError even with no clients)',
      (WidgetTester tester) async {
        // Never attached: if validation order were wrong, this would throw
        // StateError (no clients) instead of RangeError for a negative index.
        // DoD: "Валидировать параметры до обращения к позиции".
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );
        addTearDown(controller.dispose);

        expect(controller.hasClients, isFalse);
        expect(
          () => controller.scrollTo(-1.0),
          throwsA(isA<RangeError>()),
          reason:
              'Parameter validation (RangeError for negative index) must run '
              'before any attachment/position check, per the ISC-03 contract order.',
        );
      },
    );

    testWidgets(
        'non-contiguous watch() indices give StateError naming the missing index',
        (WidgetTester tester) async {
      // Registering logical indices 0,1,2,50,51,52 must surface a StateError with a useful
      // message instead of an unqualified _TypeError from `_sizes[i]!`.
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
      );
      addTearDown(controller.dispose);

      const logicalIndices = [0, 1, 2, 50, 51, 52];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              itemCount: logicalIndices.length,
              itemBuilder: (context, i) {
                final logicalIndex = logicalIndices[i];
                return controller.watch(
                  index: logicalIndex,
                  child: SizedBox(
                    height: 100.0,
                    child: Text('Item $logicalIndex'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Indices 0,1,2 are measured; 3 is the first gap. ISC-31: scrollTo()
      // checks the WHOLE prefix 0..target before trusting _sizes, so a target
      // whose own size happens to be cached (52 was measured directly by the
      // initial pumpAndSettle above) no longer takes a synchronous fast path
      // when the prefix underneath it has a hole -- it falls back to the
      // internal sequential search-from-0 pass (ISC-05/ISC-30), which only
      // discovers and reports the gap asynchronously, after the search
      // stalls at index 3 with 50/51/52 already known above it.
      Object? scrollError;
      bool scrollCompleted = false;
      unawaited(
        controller
            .scrollTo(52.0, duration: const Duration(milliseconds: 100))
            .then(
          (_) => scrollCompleted = true,
          onError: (Object e) {
            scrollError = e;
            scrollCompleted = true;
          },
        ),
      );

      for (int i = 0; i < 300 && !scrollCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        scrollError,
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('3'),
        ),
        reason:
            'Summing the prefix 0..51 hits the first missing index (3), which must '
            'be named in a StateError rather than throwing _TypeError.',
      );
    });
  });
}

void _errorDeliveryContract() {
  group('validation errors are delivered through the returned Future', () {
    Widget buildList(IndexedScrollController controller) {
      return MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: 20,
            itemBuilder: (context, index) => controller.watch(
              index: index,
              child: SizedBox(height: 100.0, child: Text('Item $index')),
            ),
          ),
        ),
      );
    }

    testWidgets(
      'a try/catch around a non-awaited scrollTo does NOT catch them',
      (tester) async {
        final controller =
            IndexedScrollController(scrollDuration: Duration.zero);
        addTearDown(controller.dispose);
        await tester.pumpWidget(buildList(controller));
        await tester.pumpAndSettle();

        // scrollTo is `async`, so even though validation runs before the
        // first await, the error surfaces on the returned Future rather than
        // being thrown out of the call itself. This pins the behavior the
        // "Error contract" Dartdoc describes, so the two cannot drift.
        var caughtSynchronously = false;
        Future<void>? escaped;
        try {
          escaped = controller.scrollTo(-1);
        } catch (_) {
          caughtSynchronously = true;
        }

        expect(
          caughtSynchronously,
          isFalse,
          reason: 'A bare try/catch without await must not be expected to '
              'catch a validation error from an async method.',
        );
        await expectLater(escaped, throwsA(isA<RangeError>()));
      },
    );

    testWidgets('awaiting the call does catch them', (tester) async {
      final controller = IndexedScrollController(scrollDuration: Duration.zero);
      addTearDown(controller.dispose);
      await tester.pumpWidget(buildList(controller));
      await tester.pumpAndSettle();

      var caught = false;
      try {
        await controller.scrollTo(double.nan);
      } on ArgumentError catch (_) {
        caught = true;
      }
      expect(caught, isTrue);
    });

    testWidgets('a rejected call does not move the list', (tester) async {
      final controller = IndexedScrollController(scrollDuration: Duration.zero);
      addTearDown(controller.dispose);
      await tester.pumpWidget(buildList(controller));
      await tester.pumpAndSettle();

      // scrollTo's search awaits real frames, so it can only complete while
      // something is pumping them -- a bare `await` here would deadlock.
      var settled = false;
      final moved = controller.scrollTo(5).then((_) => settled = true);
      for (var i = 0; i < 300 && !settled; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await moved;
      final before = controller.offset;

      await expectLater(
        controller.scrollTo(3, alignment: 2.0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        controller.offset,
        before,
        reason: 'Validation runs before the ScrollPosition is touched, so a '
            'rejected call must leave the position exactly where it was.',
      );
    });
  });
}
