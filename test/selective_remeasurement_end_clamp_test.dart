import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// ISC-51: a row after the target can change maxScrollExtent even though its
/// fingerprint is outside the target prefix and is not selectively recovered.
void main() {
  testWidgets('near-end fractional target clamps against rebuilt final extent',
      (tester) async {
    const count = 30;
    final heights = List<double>.filled(count, 100);
    final fingerprints = List<int>.filled(count, 0);
    late StateSetter rebuild;
    final controller = IndexedScrollController(
      scrollDuration: const Duration(milliseconds: 100),
      itemCount: () => count,
      contentFingerprint: (index) => fingerprints[index],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 200,
          child: StatefulBuilder(builder: (context, setState) {
            rebuild = setState;
            return ListView.builder(
              controller: controller,
              itemCount: count,
              itemBuilder: (context, index) => controller.watch(
                index: index,
                child: SizedBox(height: heights[index], child: Text('$index')),
              ),
            );
          }),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final initial = controller.scrollTo(28.5, duration: Duration.zero);
    await tester.pumpAndSettle();
    await initial;
    expect(controller.position.pixels, closeTo(2800, 1));

    // Index 29 lies after the 0..28 target prefix. Its larger extent moves
    // the real maxScrollExtent from 2800 to 3100 without invalidating the
    // measurements used to calculate target 28.5 itself.
    rebuild(() {
      heights[29] = 400;
      fingerprints[29] = 1;
    });
    await tester.pumpAndSettle();

    final recovery = controller.scrollTo(28.5, duration: Duration.zero);
    await tester.pumpAndSettle();
    await recovery;
    expect(
      controller.position.pixels,
      closeTo(2850, 1),
      reason: 'The final clamp must read the rebuilt maxScrollExtent, not the '
          'old 2800px bound from before row 29 grew.',
    );
  });
}
