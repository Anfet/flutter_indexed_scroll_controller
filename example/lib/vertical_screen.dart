import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_lorem/flutter_lorem.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

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
  /// Overrides the source of "Scroll to Random Index"'s target and reshuffle
  /// picks. Defaults to an unseeded [Random] (genuinely random, as the app
  /// shows it); tests pass a seeded instance so the picked index and
  /// reshuffled rows are reproducible.
  const VerticalScreen({super.key, Random? random}) : _random = random;

  final Random? _random;

  @override
  State<VerticalScreen> createState() => _VerticalScreenState();
}

class _VerticalScreenState extends State<VerticalScreen> {
  static const int _itemCount = 100;

  // A real scroll gesture covers a short hop almost instantly and a long
  // one noticeably slower, up to a point -- capping at 1 second keeps a
  // jump across the whole list from feeling sluggish while still reading as
  // a deliberate scroll rather than a teleport.
  static const Duration _maxScrollDuration = Duration(seconds: 1);

  // How many rows _reshuffleRandomRows() rewrites before a random-index
  // jump -- several, not one, so the jump has a realistic chance of landing
  // on or passing through a row whose height just changed underneath it.
  static const int _reshuffleCount = 5;

  // The exact heights _FixedHeightRow cycles through in fixed mode, and what
  // _reshuffleRandomRows() picks a NEW one from (excluding the row's current
  // value, so a reshuffle always changes something observable).
  static const List<double> _fixedHeights = [20.0, 40.0, 60.0];

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
    _loremRows =
        List.generate(_itemCount, (index) => _LoremRow.random(_random));
    _fixedRows = List.generate(
        _itemCount, (index) => _FixedHeightRow.random(_random, _fixedHeights));
    _scrollController = _buildController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  double _calculateItemHeight(int index) {
    return 60.0 + (index % 7) * 25.0;
  }

  // Only lorem/fixed modes need itemCount/contentFingerprint: their row
  // heights change at runtime via _reshuffleRandomRows(), so scrollTo() must
  // be able to detect a stale cached measurement and re-measure that row.
  // The synthetic-height mode never changes a row's height after it is
  // built, so it has nothing for a fingerprint to invalidate.
  IndexedScrollController _buildController() {
    switch (_rowHeightMode) {
      case _RowHeightMode.synthetic:
        return IndexedScrollController(scrollDuration: _maxScrollDuration);
      case _RowHeightMode.lorem:
        return IndexedScrollController(
          scrollDuration: _maxScrollDuration,
          itemCount: () => _itemCount,
          contentFingerprint: (index) => _loremRows[index].revision,
        );
      case _RowHeightMode.fixed:
        return IndexedScrollController(
          scrollDuration: _maxScrollDuration,
          itemCount: () => _itemCount,
          contentFingerprint: (index) => _fixedRows[index].revision,
        );
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

  /// Rewrites [_reshuffleCount] distinct random rows with a fresh height
  /// (lorem: new random text; fixed: a different exact height) and bumps
  /// their revision, without resetting the controller's whole measurement
  /// cache -- scrollTo() below is expected to pick up each changed row's new
  /// size on its own via contentFingerprint, the same recovery path
  /// exercised in the fingerprint-invalidation demo.
  Set<int> _reshuffleRandomRows() {
    final touched = <int>{};
    while (touched.length < _reshuffleCount) {
      touched.add(_random.nextInt(_itemCount));
    }
    setState(() {
      for (final index in touched) {
        switch (_rowHeightMode) {
          case _RowHeightMode.synthetic:
            break;
          case _RowHeightMode.lorem:
            _loremRows[index] = _loremRows[index].reshuffled(_random);
          case _RowHeightMode.fixed:
            _fixedRows[index] =
                _fixedRows[index].reshuffled(_random, _fixedHeights);
        }
      }
    });
    return touched;
  }

  /// Jumps to a uniformly random row, at a duration capped to
  /// [_maxScrollDuration] regardless of distance -- it always requests the
  /// cap directly instead of deriving a shorter duration for a target that
  /// happens to land nearby.
  ///
  /// In lorem mode, it first reshuffles [_reshuffleCount] rows -- some of
  /// which may sit anywhere between the current position and the jump
  /// target, including rows never yet measured -- so the jump lands on a
  /// list whose heights have genuinely changed since the last layout,
  /// rather than one whose heights were fixed for the app's whole lifetime.
  Future<void> _scrollToRandomIndex() async {
    final index = _random.nextInt(_itemCount);
    final reshuffled = _rowHeightMode == _RowHeightMode.synthetic
        ? const <int>{}
        : _reshuffleRandomRows();
    final reshufflePrefix = reshuffled.isEmpty
        ? ''
        : 'Reshuffled rows ${(reshuffled.toList()..sort()).join(', ')}. ';
    setState(() {
      _scrollStatus = '$reshufflePrefix'
          'Scrolling to random index $index (${_maxScrollDuration.inMilliseconds} ms)…';
    });

    try {
      await _scrollController.scrollTo(
        index.toDouble(),
        duration: _maxScrollDuration,
        alignment: _selectedAlignment,
      );

      if (mounted) {
        setState(() {
          _scrollStatus =
              'Success: Scrolled to random index $index (alignment: $_selectedAlignment)';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
          title: const Text('Vertical Scrolling with Alignment Control')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<_RowHeightMode>(
                        segments: const [
                          ButtonSegment(
                              value: _RowHeightMode.synthetic,
                              label: Text('Synthetic')),
                          ButtonSegment(
                              value: _RowHeightMode.lorem,
                              label: Text('Lorem text')),
                          ButtonSegment(
                              value: _RowHeightMode.fixed,
                              label: Text('Fixed 20/40/60')),
                        ],
                        selected: <_RowHeightMode>{_rowHeightMode},
                        onSelectionChanged: (Set<_RowHeightMode> newSelection) {
                          setState(() {
                            _rowHeightMode = newSelection.first;
                            _recreateController();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SegmentedButton<double>(
                        segments: const [
                          ButtonSegment(value: 0.0, label: Text('Top (0.0)')),
                          ButtonSegment(
                              value: 0.5, label: Text('Center (0.5)')),
                          ButtonSegment(
                              value: 1.0, label: Text('Bottom (1.0)')),
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
                const Text('Options:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
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
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _scrollToRandomIndex,
                    child: Text(
                      _rowHeightMode == _RowHeightMode.synthetic
                          ? 'Scroll to Random Index (1s)'
                          : 'Reshuffle $_reshuffleCount Rows & Scroll to Random Index (1s)',
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListenableBuilder(
              listenable: _scrollController,
              builder: (context, child) {
                if (!_scrollController.hasClients) {
                  return const Text('Current offset: -');
                }
                return Text(
                    'Current offset: ${_scrollController.offset.toStringAsFixed(1)} px');
              },
            ),
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
              child: ListView.builder(
                key: ValueKey(_listGeneration),
                controller: _scrollController,
                reverse: _isReverse,
                padding: _hasPadding
                    ? const EdgeInsets.only(top: 40)
                    : EdgeInsets.zero,
                itemCount: _itemCount,
                itemBuilder: (context, index) {
                  // Fixed mode's row must be EXACTLY _fixedRows[index].height,
                  // with nothing on top of it -- no padding, no border --
                  // so the offset it produces can be checked against round
                  // numbers by hand.
                  if (_rowHeightMode == _RowHeightMode.fixed) {
                    final fixedRow = _fixedRows[index];
                    final sized = SizedBox(
                      height: fixedRow.height,
                      child: ColoredBox(
                        color: index.isEven
                            ? const Color(0xFFBBDEFB)
                            : const Color(0xFFFFE0B2),
                        child: Center(
                          child: Text(
                              'Row $index (rev ${fixedRow.revision}): ${fixedRow.height.toStringAsFixed(0)}px'),
                        ),
                      ),
                    );
                    return _scrollController.watch(index: index, child: sized);
                  }

                  final content = _rowHeightMode == _RowHeightMode.lorem
                      ? Text(
                          'Row $index (rev ${_loremRows[index].revision}): ${_loremRows[index].text}')
                      : Text(
                          'Row $index (${_calculateItemHeight(index).toStringAsFixed(0)}px)');
                  // Saturated, clearly alternating colors with a visible
                  // divider -- pale near-white shades made adjacent rows'
                  // edges hard to tell apart on a short viewport.
                  final row = Container(
                    decoration: BoxDecoration(
                      color: index.isEven
                          ? const Color(0xFFBBDEFB)
                          : const Color(0xFFFFE0B2),
                      border: const Border(
                          bottom:
                              BorderSide(color: Color(0xFF9E9E9E), width: 1)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: content,
                    ),
                  );
                  return _scrollController.watch(index: index, child: row);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
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
    return _LoremRow(
        text: lorem(paragraphs: 1, words: 5 + random.nextInt(60)),
        revision: revision + 1);
  }
}

/// A row's exact pixel height (one of [_VerticalScreenState._fixedHeights])
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
