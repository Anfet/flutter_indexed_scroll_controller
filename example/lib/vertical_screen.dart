import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_lorem/flutter_lorem.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

import 'offset_status_text.dart';

/// How each row's on-axis extent is determined.
enum _RowHeightMode {
  /// A formula of the physical index (`60 + (index % 7) * 25`) -- fixed for
  /// the app's whole lifetime, never reshuffled.
  synthetic,

  /// Random lorem text whose wrapped height varies with its word count --
  /// reshuffled by picking new random text (and so a new height).
  lorem,

  /// One of three exact pixel heights (20/40/60), with no padding/border
  /// added on top -- reshuffled by picking a different exact height from the
  /// same set, so the reported offset can be checked against round numbers
  /// by hand instead of a TextPainter estimate.
  fixed,
}

class VerticalScreen extends StatefulWidget {
  final Random? _random;

  /// Overrides the source of "Scroll to Random Index"'s target and reshuffle
  /// picks. Defaults to an unseeded [Random] (genuinely random, as the app
  /// shows it); tests pass a seeded instance so the picked index and
  /// reshuffled rows are reproducible.
  const VerticalScreen({super.key, Random? random}) : _random = random;

  @override
  State<VerticalScreen> createState() => _VerticalScreenState();
}

class _VerticalScreenState extends State<VerticalScreen> {
  late IndexedScrollController _scrollController;
  late final _random = widget._random ?? Random();
  late List<_LoremRow> _loremRows;
  late List<_FixedHeightRow> _fixedRows;
  double _selectedAlignment = 0.0;
  String _scrollStatus = '';
  bool _isReverse = false;
  bool _hasPadding = false;
  _RowHeightMode _rowHeightMode = _RowHeightMode.synthetic;

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
    _loremRows = List.generate(_VerticalScreenConfig.itemCount, (index) => _LoremRow.random(_random));
    _fixedRows = List.generate(_VerticalScreenConfig.itemCount, (index) => _FixedHeightRow.random(_random, _VerticalScreenConfig.fixedHeights));
    _scrollController = _buildController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text('Vertical Scrolling with Alignment Control')),
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
                child: SegmentedButton<_RowHeightMode>(
                  segments: const [
                    ButtonSegment(value: _RowHeightMode.synthetic, label: Text('Synthetic')),
                    ButtonSegment(value: _RowHeightMode.lorem, label: Text('Lorem text')),
                    ButtonSegment(value: _RowHeightMode.fixed, label: Text('Fixed 20/40/60')),
                  ],
                  selected: <_RowHeightMode>{_rowHeightMode},
                  onSelectionChanged: _onRowHeightModeChanged,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: 0.0, label: Text('Top (0.0)')),
                    ButtonSegment(value: 0.5, label: Text('Center (0.5)')),
                    ButtonSegment(value: 1.0, label: Text('Bottom (1.0)')),
                  ],
                  selected: <double>{_selectedAlignment},
                  onSelectionChanged: _onAlignmentChanged,
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
                  onChanged: _onReverseChanged,
                  title: const Text('Reverse'),
                  dense: true,
                ),
              ),
              Expanded(
                child: CheckboxListTile(
                  value: _hasPadding,
                  onChanged: _onPaddingChanged,
                  title: const Text('Padding'),
                  dense: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _scrollToRandomIndex,
              child: Text(
                _rowHeightMode == _RowHeightMode.synthetic
                    ? 'Scroll to Random Index (1s)'
                    : 'Reshuffle ${_VerticalScreenConfig.reshuffleCount} Rows & Scroll to Random Index (1s)',
              ),
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
        controller: _scrollController,
        reverse: _isReverse,
        padding: _hasPadding ? const EdgeInsets.only(top: 40) : EdgeInsets.zero,
        itemCount: _VerticalScreenConfig.itemCount,
        itemBuilder: (context, index) => _buildRow(index),
      ),
    );
  }

  Widget _buildRow(int index) {
    // Fixed mode's row must be EXACTLY _fixedRows[index].height, with
    // nothing on top of it -- no padding, no border -- so the offset it
    // produces can be checked against round numbers by hand.
    if (_rowHeightMode == _RowHeightMode.fixed) {
      final fixedRow = _fixedRows[index];
      final sized = SizedBox(
        height: fixedRow.height,
        child: ColoredBox(
          color: index.isEven ? const Color(0xFFBBDEFB) : const Color(0xFFFFE0B2),
          child: Center(
            child: Text('Row $index (rev ${fixedRow.revision}): ${fixedRow.height.toStringAsFixed(0)}px'),
          ),
        ),
      );
      return _scrollController.watch(index: index, child: sized);
    }

    final content = _rowHeightMode == _RowHeightMode.lorem
        ? Text('Row $index (rev ${_loremRows[index].revision}): ${_loremRows[index].text}')
        : Text('Row $index (${_calculateItemHeight(index).toStringAsFixed(0)}px)');
    // Saturated, clearly alternating colors with a visible divider -- pale
    // near-white shades made adjacent rows' edges hard to tell apart on a
    // short viewport.
    final row = Container(
      decoration: BoxDecoration(
        color: index.isEven ? const Color(0xFFBBDEFB) : const Color(0xFFFFE0B2),
        border: const Border(bottom: BorderSide(color: Color(0xFF9E9E9E), width: 1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: content,
      ),
    );
    return _scrollController.watch(index: index, child: row);
  }

  void _onRowHeightModeChanged(Set<_RowHeightMode> newSelection) {
    setState(() {
      _rowHeightMode = newSelection.first;
      _recreateController();
    });
  }

  void _onAlignmentChanged(Set<double> newSelection) {
    setState(() {
      _selectedAlignment = newSelection.first;
    });
  }

  void _onReverseChanged(bool? value) {
    setState(() {
      _isReverse = value ?? false;
      _recreateController();
    });
  }

  void _onPaddingChanged(bool? value) {
    setState(() {
      _hasPadding = value ?? false;
      _recreateController();
    });
  }

  /// Jumps to a uniformly random row, at a duration capped to
  /// [_VerticalScreenConfig.maxScrollDuration] regardless of distance -- it always requests the
  /// cap directly instead of deriving a shorter duration for a target that
  /// happens to land nearby.
  ///
  /// In lorem mode, it first reshuffles [_VerticalScreenConfig.reshuffleCount] rows -- some of
  /// which may sit anywhere between the current position and the jump
  /// target, including rows never yet measured -- so the jump lands on a
  /// list whose heights have genuinely changed since the last layout,
  /// rather than one whose heights were fixed for the app's whole lifetime.
  Future<void> _scrollToRandomIndex() async {
    final index = _random.nextInt(_VerticalScreenConfig.itemCount);
    final reshuffled = _rowHeightMode == _RowHeightMode.synthetic ? const <int>{} : _reshuffleRandomRows();
    final reshufflePrefix = reshuffled.isEmpty ? '' : 'Reshuffled rows ${(reshuffled.toList()..sort()).join(', ')}. ';
    setState(() {
      _scrollStatus = '$reshufflePrefix'
          'Scrolling to random index $index (${_VerticalScreenConfig.maxScrollDuration.inMilliseconds} ms)…';
    });

    try {
      await _scrollController.scrollTo(
        index.toDouble(),
        duration: _VerticalScreenConfig.maxScrollDuration,
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
    _scrollController = _buildController();
    // No invalidateMeasurements() call here: this controller is brand new
    // and has never registered a row (_liveOwners is empty), so there is
    // nothing yet to force through a fresh layout. Every row registers its
    // size and leading padding from scratch the first time this controller
    // attaches and lays out, which the changing _listGeneration key (used
    // below) guarantees happens rather than reusing stale RenderObjects.
    _listGeneration++;
  }

  /// Rewrites [_VerticalScreenConfig.reshuffleCount] distinct random rows with a fresh height
  /// (lorem: new random text; fixed: a different exact height) and bumps
  /// their revision, without resetting the controller's whole measurement
  /// cache -- scrollTo() below is expected to pick up each changed row's new
  /// size on its own via contentFingerprint, the same recovery path
  /// exercised in the fingerprint-invalidation demo.
  Set<int> _reshuffleRandomRows() {
    final touched = <int>{};
    while (touched.length < _VerticalScreenConfig.reshuffleCount) {
      touched.add(_random.nextInt(_VerticalScreenConfig.itemCount));
    }
    setState(() {
      for (final index in touched) {
        switch (_rowHeightMode) {
          case _RowHeightMode.synthetic:
            break;
          case _RowHeightMode.lorem:
            _loremRows[index] = _loremRows[index].reshuffled(_random);
          case _RowHeightMode.fixed:
            _fixedRows[index] = _fixedRows[index].reshuffled(_random, _VerticalScreenConfig.fixedHeights);
        }
      }
    });
    return touched;
  }

  // Only lorem/fixed modes need itemCount/contentFingerprint: their row
  // heights change at runtime via _reshuffleRandomRows(), so scrollTo() must
  // be able to detect a stale cached measurement and re-measure that row.
  // The synthetic-height mode never changes a row's height after it is
  // built, so it has nothing for a fingerprint to invalidate.
  IndexedScrollController _buildController() {
    switch (_rowHeightMode) {
      case _RowHeightMode.synthetic:
        return IndexedScrollController(scrollDuration: _VerticalScreenConfig.maxScrollDuration);
      case _RowHeightMode.lorem:
        return IndexedScrollController(
          scrollDuration: _VerticalScreenConfig.maxScrollDuration,
          itemCount: () => _VerticalScreenConfig.itemCount,
          contentFingerprint: (index) => _loremRows[index].revision,
        );
      case _RowHeightMode.fixed:
        return IndexedScrollController(
          scrollDuration: _VerticalScreenConfig.maxScrollDuration,
          itemCount: () => _VerticalScreenConfig.itemCount,
          contentFingerprint: (index) => _fixedRows[index].revision,
        );
    }
  }

  double _calculateItemHeight(int index) {
    return 60.0 + (index % 7) * 25.0;
  }
}

class _VerticalScreenConfig {
  // A real scroll gesture covers a short hop almost instantly and a long
  // one noticeably slower, up to a point -- capping at 1 second keeps a
  // jump across the whole list from feeling sluggish while still reading as
  // a deliberate scroll rather than a teleport.
  static const Duration maxScrollDuration = Duration(seconds: 1);

  // How many rows _reshuffleRandomRows() rewrites before a random-index
  // jump -- several, not one, so the jump has a realistic chance of landing
  // on or passing through a row whose height just changed underneath it.
  static const int reshuffleCount = 5;

  // The exact heights _FixedHeightRow cycles through in fixed mode, and what
  // _reshuffleRandomRows() picks a NEW one from (excluding the row's current
  // value, so a reshuffle always changes something observable).
  static const List<double> fixedHeights = [20.0, 40.0, 60.0];

  static const int itemCount = 100;
}

/// A row's lorem-generated text plus a revision counter, mirroring
/// `fingerprint_screen.dart`'s `_ExampleItem`: the revision is what
/// [IndexedScrollController.contentFingerprint] reads to notice a row has
/// changed and needs re-measuring, since the text itself is not compared.
class _LoremRow {
  final String text;
  final int revision;

  const _LoremRow({required this.text, this.revision = 0});

  factory _LoremRow.random(Random random) {
    return _LoremRow(text: lorem(paragraphs: 1, words: 5 + random.nextInt(60)));
  }

  _LoremRow reshuffled(Random random) {
    return _LoremRow(text: lorem(paragraphs: 1, words: 5 + random.nextInt(60)), revision: revision + 1);
  }
}

/// A row's exact pixel height (one of [_VerticalScreenConfig.fixedHeights])
/// plus a revision counter, mirroring [_LoremRow]: unlike lorem text, whose
/// wrapped height must be estimated, this height is the exact number
/// scrollTo()'s offset should sum -- meant for checking the reported offset
/// against round numbers by hand.
class _FixedHeightRow {
  final double height;
  final int revision;

  const _FixedHeightRow({required this.height, this.revision = 0});

  factory _FixedHeightRow.random(Random random, List<double> choices) {
    return _FixedHeightRow(height: choices[random.nextInt(choices.length)]);
  }

  /// Picks a height DIFFERENT from the current one, so a reshuffle always
  /// changes something observable rather than occasionally re-rolling the
  /// same value and looking like a no-op.
  _FixedHeightRow reshuffled(Random random, List<double> choices) {
    final others = choices.where((h) => h != height).toList();
    final next = others[random.nextInt(others.length)];
    return _FixedHeightRow(height: next, revision: revision + 1);
  }
}
