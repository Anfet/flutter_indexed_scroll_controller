import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_lorem/flutter_lorem.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';
import 'package:sprintf/sprintf.dart';

class ListScreen extends StatefulWidget {
  const ListScreen({super.key});

  @override
  State<ListScreen> createState() => _ScreenDState();
}

class _ScreenDState extends State<ListScreen> {
  final randomizer = Random();

  final IndexedScrollController scrollController = IndexedScrollController(scrollDuration: const Duration(milliseconds: 300));
  late List<String> items;
  double scrollToIndex = 0.0;
  String? lastError;

  @override
  void initState() {
    items = List.generate(50, (index) => lorem(paragraphs: 1, words: 5 + randomizer.nextInt(5)));
    scrollToIndex = 2 + randomizer.nextInt(items.length - 2).toDouble(); // * 1.0 + randomizer.nextDouble();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scroll example'),
        forceMaterialTransparency: true,
      ),
      body: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListenableBuilder(
            listenable: scrollController,
            builder: (context, child) {
              if (!scrollController.hasClients) {
                return const SizedBox.shrink();
              }

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('offset -> ${scrollController.offset.toStringAsFixed(1)}'),
                    Text('maxScrollExtent -> ${scrollController.position.maxScrollExtent.toStringAsFixed(1)}'),
                    if (lastError != null)
                      Text(
                        lastError!,
                        style: const TextStyle(color: Color(0xFFCC0000), fontWeight: FontWeight.bold),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Expanded(
            child: NotificationListener<ScrollStartNotification>(
              // A user drag never implicitly interrupts an in-flight
              // scrollTo() — see the package Dartdoc. Calling
              // cancelScroll() here is what gives the user's gesture
              // priority over a scroll that is still animating. But
              // scrollTo()'s own internal animateTo() calls also emit
              // ScrollStartNotification, so cancelling unconditionally
              // would make a programmatic scroll cancel itself. Only real
              // user drags carry dragDetails, so that's the guard.
              onNotification: (notification) {
                if (notification.dragDetails != null) {
                  scrollController.cancelScroll();
                }
                return false;
              },
              child: ListView.builder(
                controller: scrollController,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  return scrollController.watch(
                    index: index,
                    child: Container(
                      color: Color(randomizer.nextInt(0x00ffffff)).withAlpha(30),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Text('$index --> ${items[index]}'),
                    ),
                  );
                },
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.white,
            child: Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: ElevatedButton(
                    child: Text('Scroll to ${sprintf('%2.2f', [scrollToIndex])}'),
                    onPressed: () async {
                      try {
                        await scrollController.scrollTo(
                          scrollToIndex,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.linear,
                          alignment: 0.5,
                        );
                        setState(() {
                          lastError = null;
                          scrollToIndex = 2 + randomizer.nextInt(items.length - 2).toDouble();
                        });
                      } on ScrollCancelledException catch (e) {
                        setState(() {
                          lastError = 'Scroll cancelled: ${e.reason}';
                        });
                      } catch (e) {
                        setState(() {
                          lastError = 'Error: $e';
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    child: const Text('top'),
                    onPressed: () => scrollController.scrollTo(0),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    child: const Text('invalidate'),
                    onPressed: () {
                      scrollController.invalidateMeasurements();
                      setState(() {
                        lastError = 'Measurements invalidated';
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    child: const Text('bottom'),
                    onPressed: () => scrollController.animateTo(
                      scrollController.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeIn,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
