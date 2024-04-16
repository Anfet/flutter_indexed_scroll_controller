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

  @override
  void initState() {
    items = List.generate(1000, (index) => lorem(paragraphs: 1, words: 5 + randomizer.nextInt(25)));
    scrollToIndex = randomizer.nextInt(items.length) * 1.0 + randomizer.nextDouble();
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
                    Text('offset -> ${scrollController.offset}'),
                    Text('maxScrollExtent -> ${scrollController.position.maxScrollExtent}'),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Expanded(
            child: NotificationListener<UserScrollNotification>(
              onNotification: (notification) {
                scrollController.cancelScroll();
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
                      scrollController.scrollTo(
                        scrollToIndex,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.linear,
                      );

                      setState(() {
                        scrollToIndex = randomizer.nextInt(items.length) * 1.0 + randomizer.nextDouble();
                      });
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
