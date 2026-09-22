import 'package:example/fingerprint_screen.dart';
import 'package:example/horizontal_screen.dart';
import 'package:example/main.dart';
import 'package:example/vertical_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders home screen with fingerprint example entry', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    expect(find.text('Indexed Scroll Controller Examples'), findsOneWidget);
    expect(find.text('Fingerprint Invalidation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the fingerprint-invalidation example with both scenarios', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    await tester.tap(find.text('Fingerprint Invalidation'));
    await tester.pumpAndSettle();

    expect(find.text('Automatic fingerprint-based invalidation'), findsOneWidget);
    expect(find.text('Row 0: 80 px, revision 0'), findsOneWidget);
    expect(find.text('Cancel scroll on data change'), findsOneWidget);
    expect(find.text('Grow off-screen row, no reset'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct fingerprint screen rendering', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FingerprintScreen(),
      ),
    );

    expect(find.text('Automatic fingerprint-based invalidation'), findsOneWidget);
    expect(find.text('Row 0: 80 px, revision 0'), findsOneWidget);
    expect(find.text('Cancel scroll on data change'), findsOneWidget);
    expect(find.text('Grow off-screen row, no reset'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders home screen with vertical example entry', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    expect(find.text('Indexed Scroll Controller Examples'), findsOneWidget);
    expect(find.text('Vertical'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders vertical screen and can perform indexed scroll', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    await tester.tap(find.text('Vertical'));
    await tester.pumpAndSettle();

    expect(find.text('Vertical Scrolling with Alignment Control'), findsOneWidget);
    expect(find.text('Index to scroll to:'), findsOneWidget);
    expect(find.text('Alignment:'), findsOneWidget);
    expect(find.text('Scroll to Index'), findsOneWidget);
    expect(find.text('Row 0 (60px)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical screen alignment buttons are selectable', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VerticalScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Top (0.0)'), findsOneWidget);
    expect(find.text('Center (0.5)'), findsOneWidget);
    expect(find.text('Bottom (1.0)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical screen scrollTo updates offset on successful scroll', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VerticalScreen(),
      ),
    );

    await tester.pumpAndSettle();

    final textFieldFinder = find.byType(TextField);
    await tester.enterText(textFieldFinder, '20');
    await tester.tap(find.text('Scroll to Index'));

    for (int i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final offsetTexts = find.byType(Text).evaluate().map((w) => (w.widget as Text).data ?? '').where((t) => t.startsWith('Current offset:')).toList();

    expect(offsetTexts, isNotEmpty, reason: 'Should have offset display');
    expect(offsetTexts.first, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical screen alignment change affects scroll position', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VerticalScreen(),
      ),
    );

    await tester.pumpAndSettle();

    const targetIndex = 50;

    await tester.enterText(find.byType(TextField), '$targetIndex');

    await tester.tap(find.text('Top (0.0)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scroll to Index'));
    for (int i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final offsetAlignment0 = _extractOffset();

    await tester.enterText(find.byType(TextField), '$targetIndex');

    await tester.tap(find.text('Bottom (1.0)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scroll to Index'));
    for (int i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final offsetAlignment1 = _extractOffset();

    expect(offsetAlignment0, isNotNull);
    expect(offsetAlignment1, isNotNull);
    expect(offsetAlignment0 != offsetAlignment1, true, reason: 'Different alignments should produce different offsets for same index');
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical screen padding toggle changes the scroll offset for the same index', (tester) async {
    // ISC-72 review: confirms the padding CheckboxListTile actually takes
    // effect on the NEXT scrollTo, not merely that the switch flips visually.
    // This is the scenario _recreateController()'s invalidateMeasurements()
    // call is specifically for: a brand-new IndexedScrollController has an
    // empty _liveOwners, so that call is a no-op by itself, and the real
    // guarantee is that every row re-registers its size (and leading
    // padding) from scratch under the new controller on its next layout.
    await tester.pumpWidget(
      const MaterialApp(
        home: VerticalScreen(),
      ),
    );
    await tester.pumpAndSettle();

    // A small, already-on-screen target index keeps scrollTo() on its
    // already-measured fast path (no multi-frame _runAnimateTo search
    // needed), so this test's assertion is not sensitive to how many
    // frames the pump loop below happens to cover.
    const targetIndex = 3;

    await tester.enterText(find.byType(TextField), '$targetIndex');
    await tester.tap(find.text('Scroll to Index'));
    for (int i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final offsetWithoutPadding = _extractOffset();

    await tester.tap(find.text('Padding'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '$targetIndex');
    await tester.tap(find.text('Scroll to Index'));
    for (int i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final offsetWithPadding = _extractOffset();

    expect(offsetWithoutPadding, isNotNull);
    expect(offsetWithPadding, isNotNull);
    expect(
      offsetWithPadding! - offsetWithoutPadding!,
      closeTo(40.0, 1.0),
      reason: 'Enabling the 40px leading padding must shift scrollTo($targetIndex)\'s '
          'offset by exactly 40px -- if the toggle were a no-op (e.g. because '
          'invalidateMeasurements() ran on a controller with no rows registered '
          'yet), both offsets would be identical instead.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical screen reverse toggle actually reverses the visual order', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: VerticalScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Row 0 (60px)'), findsOneWidget);
    final topLeftBefore = tester.getTopLeft(find.text('Row 0 (60px)'));

    await tester.tap(find.text('Reverse'));
    await tester.pumpAndSettle();

    expect(
      find.text('Row 0 (60px)'),
      findsOneWidget,
      reason: 'Row 0 must still be registered as watch(index: 0) under '
          'reverse: true (SliverList does not invert indices).',
    );
    final topLeftAfter = tester.getTopLeft(find.text('Row 0 (60px)'));

    expect(
      topLeftAfter.dy,
      greaterThan(topLeftBefore.dy),
      reason: 'reverse: true must move row 0 away from the top of the '
          'viewport (toward the bottom) -- otherwise the toggle has no '
          'visible effect and the demonstration is misleading.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders home screen with horizontal example entry', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    expect(find.text('Indexed Scroll Controller Examples'), findsOneWidget);
    expect(find.text('Horizontal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders horizontal screen and can perform indexed scroll', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    await tester.tap(find.text('Horizontal'));
    await tester.pumpAndSettle();

    expect(find.text('Horizontal Scrolling with Alignment Control'), findsOneWidget);
    expect(find.text('Index to scroll to:'), findsOneWidget);
    expect(find.text('Alignment:'), findsOneWidget);
    expect(find.text('Scroll to Index'), findsOneWidget);
    expect(find.text('Left (0.0)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal screen alignment buttons are selectable', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HorizontalScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Left (0.0)'), findsOneWidget);
    expect(find.text('Center (0.5)'), findsOneWidget);
    expect(find.text('Right (1.0)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal screen scrollTo updates offset on successful scroll', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HorizontalScreen(),
      ),
    );

    await tester.pumpAndSettle();

    final textFieldFinder = find.byType(TextField);
    await tester.enterText(textFieldFinder, '20');
    await tester.tap(find.text('Scroll to Index'));

    for (int i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final offsetTexts = find.byType(Text).evaluate().map((w) => (w.widget as Text).data ?? '').where((t) => t.startsWith('Current offset:')).toList();

    expect(offsetTexts, isNotEmpty, reason: 'Should have offset display');
    expect(offsetTexts.first, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal screen alignment change affects scroll position', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HorizontalScreen(),
      ),
    );

    await tester.pumpAndSettle();

    const targetIndex = 50;

    await tester.enterText(find.byType(TextField), '$targetIndex');

    await tester.tap(find.text('Left (0.0)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scroll to Index'));
    for (int i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final offsetAlignment0 = _extractOffset();

    await tester.enterText(find.byType(TextField), '$targetIndex');

    await tester.tap(find.text('Right (1.0)'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scroll to Index'));
    for (int i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final offsetAlignment1 = _extractOffset();

    expect(offsetAlignment0, isNotNull);
    expect(offsetAlignment1, isNotNull);
    expect(offsetAlignment0 != offsetAlignment1, true, reason: 'Different alignments should produce different offsets for same index');
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal screen padding toggle changes the scroll offset for the same index', (tester) async {
    // Mirrors the vertical screen's padding-toggle test.
    await tester.pumpWidget(
      const MaterialApp(
        home: HorizontalScreen(),
      ),
    );
    await tester.pumpAndSettle();

    const targetIndex = 3;

    await tester.enterText(find.byType(TextField), '$targetIndex');
    await tester.tap(find.text('Scroll to Index'));
    for (int i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final offsetWithoutPadding = _extractOffset();

    await tester.tap(find.text('Padding'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '$targetIndex');
    await tester.tap(find.text('Scroll to Index'));
    for (int i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final offsetWithPadding = _extractOffset();

    expect(offsetWithoutPadding, isNotNull);
    expect(offsetWithPadding, isNotNull);
    expect(
      offsetWithPadding! - offsetWithoutPadding!,
      closeTo(40.0, 1.0),
      reason: 'Enabling the 40px leading padding must shift scrollTo($targetIndex)\'s '
          'offset by exactly 40px.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('horizontal screen reverse toggle actually reverses the visual order', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HorizontalScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Card 0\n(80px)'), findsOneWidget);
    final topLeftBefore = tester.getTopLeft(find.text('Card 0\n(80px)'));

    await tester.tap(find.text('Reverse'));
    await tester.pumpAndSettle();

    expect(
      find.text('Card 0\n(80px)'),
      findsOneWidget,
      reason: 'Card 0 must still be registered as watch(index: 0) under '
          'reverse: true (SliverList does not invert indices).',
    );
    final topLeftAfter = tester.getTopLeft(find.text('Card 0\n(80px)'));

    expect(
      topLeftAfter.dx,
      greaterThan(topLeftBefore.dx),
      reason: 'reverse: true must move card 0 away from the left of the '
          'viewport (toward the right) -- otherwise the toggle has no '
          'visible effect and the demonstration is misleading.',
    );
    expect(tester.takeException(), isNull);
  });
}

double? _extractOffset() {
  final finder = find.byType(Text);
  final texts = finder.evaluate().map((w) => (w.widget as Text).data ?? '').toList();
  final offsetText = texts.firstWhere((t) => t.startsWith('Current offset:'), orElse: () => '');
  if (offsetText.isEmpty) return null;
  final match = RegExp(r'Current offset: ([\d.]+)').firstMatch(offsetText);
  if (match == null) return null;
  return double.tryParse(match.group(1) ?? '');
}
