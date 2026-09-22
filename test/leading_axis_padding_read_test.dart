import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group('ISC-61: _RenderIndexedScrollItem reads leading axis padding from RenderSliverEdgeInsetsPadding ancestors', () {
    testWidgets(
      'no SliverPadding ancestor reads as zero',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                itemCount: 20,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(height: 50.0, child: Text('Item $index')),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          controller.leadingAxisPaddingForTesting,
          0.0,
          reason: 'ListView.builder without padding does not insert a '
              'SliverPadding, so no RenderSliverEdgeInsetsPadding ancestor '
              'exists and the read value must be exactly 0.0.',
        );
      },
    );

    testWidgets(
      'a single SliverPadding ancestor (ListView.builder(padding:)) reads its beforePadding',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView.builder(
                controller: controller,
                padding: const EdgeInsets.only(top: 25.0, bottom: 99.0),
                itemCount: 20,
                itemBuilder: (context, index) => controller.watch(
                  index: index,
                  child: SizedBox(height: 50.0, child: Text('Item $index')),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          controller.leadingAxisPaddingForTesting,
          25.0,
          reason: 'ListView.builder(padding: EdgeInsets.only(top: 25, '
              'bottom: 99)) wraps its SliverList in exactly one '
              'SliverPadding. The read leading padding must be the '
              'leading-side value only (top, since this is vertical and not '
              'reversed) -- the trailing padding (bottom: 99) must not be '
              'summed in.',
        );
      },
    );

    testWidgets(
      'two nested SliverPadding ancestors sum their beforePadding',
      (WidgetTester tester) async {
        final controller = IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
        );

        // Two independently-nested SliverPaddings above the SliverList:
        // an outer CustomScrollView-level SliverPadding wrapping a
        // SliverPadding-wrapped SliverList, exercising the "sum every one
        // found along the way" requirement rather than stopping at the
        // first ancestor.
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomScrollView(
                controller: controller,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.only(top: 12.0),
                    sliver: SliverPadding(
                      padding: const EdgeInsets.only(top: 8.0),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => controller.watch(
                            index: index,
                            child: SizedBox(height: 50.0, child: Text('Item $index')),
                          ),
                          childCount: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          controller.leadingAxisPaddingForTesting,
          20.0,
          reason: 'Two nested SliverPadding ancestors (top: 12 and top: 8) '
              'must both be summed into the leading padding (12 + 8 = 20), '
              'not just the first one encountered while walking up the '
              'render tree.',
        );
      },
    );
  });
}
