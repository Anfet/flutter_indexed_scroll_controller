import 'dart:math';

import 'package:flutter/material.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'offset_status_text.dart';

class HorizontalScreen extends StatefulWidget {
  /// Overrides the source of "Scroll to Random Index"'s target. Defaults to
  /// an unseeded [Random] (genuinely random, as the app shows it); tests
  /// pass a seeded instance so the picked index is reproducible.
  const HorizontalScreen({super.key, Random? random}) : _random = random;

  final Random? _random;

  @override
  State<HorizontalScreen> createState() => _HorizontalScreenState();
}

class _HorizontalScreenState extends State<HorizontalScreen> {
  static const int _itemCount = 100;

  // A real scroll gesture covers a short hop almost instantly and a long
  // one noticeably slower, up to a point -- capping at 1 second keeps a
  // jump across the whole list from feeling sluggish while still reading as
  // a deliberate scroll rather than a teleport.
  static const Duration _maxScrollDuration = Duration(seconds: 1);

  late IndexedScrollController _scrollController;
  late final _random = widget._random ?? Random();
  double _selectedAlignment = 0.0;
  String _scrollStatus = '';
  bool _isReverse = false;
  bool _hasPadding = false;

  // Bumped by _recreateController() and used as the ListView's Key. Without
  // a changing Key, ListView.builder's `reverse`/`padding` params merely
  // update the SAME underlying Scrollable/RenderObject tree via
  // didUpdateWidget rather than rebuilding it from scratch -- observed to
  // leave position.pixels/PageStorage carrying over stale state from the old
  // configuration instead of starting the new list at offset 0.
  int _listGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController = IndexedScrollController(
      scrollDuration: _maxScrollDuration,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Horizontal Scrolling with Alignment Control')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildControls(),
          _buildOffsetStatus(),
          if (_scrollStatus.isNotEmpty) _buildScrollStatusBanner(),
          const SizedBox(height: 16),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 0.0, label: Text('Left (0.0)')),
                    ButtonSegment(value: 0.5, label: Text('Center (0.5)')),
                    ButtonSegment(value: 1.0, label: Text('Right (1.0)')),
                  ],
                  selected: <double>{_selectedAlignment},
                  onSelectionChanged: (Set<double> newSelection) {
                    setState(() {
                      _selectedAlignment = newSelection.first;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('Options:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  value: _isReverse,
                  onChanged: (value) {
                    setState(() {
                      _isReverse = value ?? false;
                      _recreateController();
                    });
                  },
                  title: const Text('Reverse'),
                  dense: true,
                ),
              ),
              Expanded(
                child: CheckboxListTile(
                  value: _hasPadding,
                  onChanged: (value) {
                    setState(() {
                      _hasPadding = value ?? false;
                      _recreateController();
                    });
                  },
                  title: const Text('Padding'),
                  dense: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _scrollToRandomIndex,
              child: const Text('Scroll to Random Index (1s)'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOffsetStatus() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: OffsetStatusText(controller: _scrollController),
    );
  }

  Widget _buildScrollStatusBanner() {
    final isError = _scrollStatus.startsWith('Error');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: isError ? const Color(0xFFFFEBEE) : const Color(0xFFFFF8E1),
          border: Border.all(
            color: isError ? const Color(0xFFEF5350) : const Color(0xFFFBC02D),
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.all(12),
        child: Text(_scrollStatus),
      ),
    );
  }

  Widget _buildList() {
    return IndexedScrollGestureDetector(
      controller: _scrollController,
      child: ListView.builder(
        key: ValueKey(_listGeneration),
        scrollDirection: Axis.horizontal,
        reverse: _isReverse,
        padding: _hasPadding ? const EdgeInsets.only(left: 40) : EdgeInsets.zero,
        controller: _scrollController,
        itemCount: _itemCount,
        itemBuilder: (context, index) => _buildCard(index),
      ),
    );
  }

  Widget _buildCard(int index) {
    final width = _calculateItemWidth(index);
    return _scrollController.watch(
      index: index,
      child: SizedBox(
        width: width,
        child: ColoredBox(
          color: index.isEven ? const Color(0xFFE8F0FE) : const Color(0xFFF4F4F4),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text('Card $index\n(${width.toStringAsFixed(0)}px)', textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }

  /// Jumps to a uniformly random item, at a duration capped to
  /// [_maxScrollDuration] regardless of distance -- it always requests the
  /// cap directly instead of deriving a shorter duration for a target that
  /// happens to land nearby.
  Future<void> _scrollToRandomIndex() async {
    final index = _random.nextInt(_itemCount);
    setState(() {
      _scrollStatus = 'Scrolling to random index $index (${_maxScrollDuration.inMilliseconds} ms)…';
    });

    try {
      await _scrollController.scrollTo(
        index.toDouble(),
        duration: _maxScrollDuration,
        alignment: _selectedAlignment,
      );

      if (mounted) {
        setState(() {
          _scrollStatus = 'Success: Scrolled to random index $index (alignment: $_selectedAlignment)';
        });
      }
    } on ScrollCancelledException catch (e) {
      if (mounted) {
        setState(() {
          _scrollStatus = 'Scroll cancelled: ${e.reason}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scrollStatus = 'Error: $e';
        });
      }
    }
  }

  void _recreateController() {
    _scrollController.dispose();
    _scrollController = IndexedScrollController(
      scrollDuration: _maxScrollDuration,
    );
    // No invalidateMeasurements() call here: this controller is brand new
    // and has never registered a row (_liveOwners is empty), so there is
    // nothing yet to force through a fresh layout. Every row registers its
    // size and leading padding from scratch the first time this controller
    // attaches and lays out, which the changing _listGeneration key (used
    // below) guarantees happens rather than reusing stale RenderObjects.
    _listGeneration++;
  }

  double _calculateItemWidth(int index) {
    return 80.0 + (index % 6) * 35.0;
  }
}
