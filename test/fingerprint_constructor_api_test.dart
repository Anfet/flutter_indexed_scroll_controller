import 'package:flutter_test/flutter_test.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

void main() {
  group('ISC-44: itemCount/contentFingerprint constructor contract', () {
    test('omitting both keeps the manual invalidateMeasurements() mode', () {
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
      );
      expect(controller.itemCount, isNull);
      expect(controller.contentFingerprint, isNull);
      controller.dispose();
    });

    test('providing both is accepted', () {
      final items = <String>['a', 'b', 'c'];
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => items.length,
        contentFingerprint: (index) => items[index],
      );
      expect(controller.itemCount!(), 3);
      expect(controller.contentFingerprint!(1), 'b');
      controller.dispose();
    });

    test('providing only itemCount throws ArgumentError, including in release-equivalent checks', () {
      expect(
        () => IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
          itemCount: () => 3,
        ),
        throwsArgumentError,
      );
    });

    test('providing only contentFingerprint throws ArgumentError, including in release-equivalent checks', () {
      expect(
        () => IndexedScrollController(
          scrollDuration: const Duration(milliseconds: 100),
          contentFingerprint: (index) => index,
        ),
        throwsArgumentError,
      );
    });

    test('contentFingerprint is never called by the controller for an out-of-range index', () {
      final items = <String>['a', 'b', 'c'];
      var calledWith = <int>[];
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => items.length,
        contentFingerprint: (index) {
          calledWith.add(index);
          return items[index];
        },
      );

      // Construction alone, with no watch() call and no scrollTo(), must
      // never invoke contentFingerprint -- it is watch() (ISC-45) that calls
      // it, at build time for the index it is given, and scrollTo() (ISC-46)
      // that will call it again while checking a prefix. Neither runs here.
      expect(calledWith, isEmpty);
      controller.dispose();
    });

    test('contentFingerprint may return null as an ordinary value', () {
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => 1,
        contentFingerprint: (index) => null,
      );
      expect(controller.contentFingerprint!(0), isNull);
      controller.dispose();
    });

    test('contentFingerprint may return a Record fingerprint', () {
      final controller = IndexedScrollController(
        scrollDuration: const Duration(milliseconds: 100),
        itemCount: () => 1,
        contentFingerprint: (index) => (id: index, title: 'row $index'),
      );
      expect(controller.contentFingerprint!(0), (id: 0, title: 'row 0'));
      controller.dispose();
    });
  });
}
