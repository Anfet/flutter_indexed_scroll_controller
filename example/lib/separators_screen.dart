import 'dart:math';

import 'package:flutter/material.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'offset_status_text.dart';

/// Demonstrates `ListView.separated` with [IndexedScrollController.separator]
/// and the two [ScrollAlignmentTarget]s: `row` (the default, item + its
/// trailing separator) vs `item` (the item alone, separator excluded from
/// what `alignment` measures against).
class SeparatorsScreen extends StatefulWidget {
  const SeparatorsScreen({super.key, Random? random}) : _random = random;

  final Random? _random;

  @override
  State<SeparatorsScreen> createState() => _SeparatorsScreenState();
}

class _SeparatorsScreenState extends State<SeparatorsScreen> {
  static const int _itemCount = 40;
  static const double _itemExtent = 72.0;
  static const double _separatorExtent = 24.0;
  static const Duration _scrollDuration = Duration(seconds: 1);

  late final _random = widget._random ?? Random();
  late final _scrollController =
      IndexedScrollController(scrollDuration: _scrollDuration);
  ScrollAlignmentTarget _alignmentTarget = ScrollAlignmentTarget.row;
  String _scrollStatus = '';

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _scrollToRandomIndex() async {
    final index = _random.nextInt(_itemCount);
    setState(() {
      _scrollStatus = 'Scrolling to index $index '
          '(alignmentTarget: ${_alignmentTarget.name})…';
    });

    try {
      await _scrollController.scrollTo(
        index.toDouble(),
        duration: _scrollDuration,
        alignmentTarget: _alignmentTarget,
      );
      if (mounted) {
        setState(() {
          _scrollStatus = 'Success: scrolled to index $index '
              '(alignmentTarget: ${_alignmentTarget.name})';
        });
      }
    } on ScrollCancelledException catch (e) {
      if (mounted) {
        setState(() => _scrollStatus = 'Scroll cancelled: ${e.reason}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _scrollStatus = 'Error: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text('ListView.separated')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'alignment: 1 (bottom). Compare where the target item lands '
                  'relative to the viewport bottom for each alignmentTarget.',
                ),
                const SizedBox(height: 8),
                SegmentedButton<ScrollAlignmentTarget>(
                  segments: const [
                    ButtonSegment(
                      value: ScrollAlignmentTarget.row,
                      label: Text('row (item + separator)'),
                    ),
                    ButtonSegment(
                      value: ScrollAlignmentTarget.item,
                      label: Text('item (separator excluded)'),
                    ),
                  ],
                  selected: <ScrollAlignmentTarget>{_alignmentTarget},
                  onSelectionChanged: (newSelection) {
                    setState(() => _alignmentTarget = newSelection.first);
                  },
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _scrollToRandomIndex,
                    child: const Text('Scroll to Random Index (1s)'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OffsetStatusText(controller: _scrollController),
          ),
          if (_scrollStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: _scrollStatus.startsWith('Error')
                      ? const Color(0xFFFFEBEE)
                      : const Color(0xFFFFF8E1),
                  border: Border.all(
                    color: _scrollStatus.startsWith('Error')
                        ? const Color(0xFFEF5350)
                        : const Color(0xFFFBC02D),
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                padding: const EdgeInsets.all(12),
                child: Text(_scrollStatus),
              ),
            ),
          const SizedBox(height: 16),
          Expanded(
            child: IndexedScrollGestureDetector(
              controller: _scrollController,
              child: ListView.separated(
                controller: _scrollController,
                itemCount: _itemCount,
                // Every separator that follows a watch()-ed item must be
                // wrapped with separator(index: i), not left as a plain
                // widget -- otherwise _checkNoOrphanSeparators() throws a
                // StateError instead of silently landing at the wrong offset.
                separatorBuilder: (context, index) =>
                    _scrollController.separator(
                  index: index,
                  child: Container(
                    height: _separatorExtent,
                    alignment: Alignment.center,
                    child: const Divider(),
                  ),
                ),
                itemBuilder: (context, index) => _scrollController.watch(
                  index: index,
                  child: Container(
                    height: _itemExtent,
                    color: index.isEven
                        ? const Color(0xFFBBDEFB)
                        : const Color(0xFFFFE0B2),
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text('Item $index'),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
