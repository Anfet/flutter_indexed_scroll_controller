import 'package:flutter/material.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

class FingerprintScreen extends StatefulWidget {
  const FingerprintScreen({super.key});

  @override
  State<FingerprintScreen> createState() => _FingerprintScreenState();
}

class _FingerprintScreenState extends State<FingerprintScreen> {
  static const _scenarioTargetIndex = 90;
  static const _scenarioDuration = Duration(milliseconds: 100);
  static const _dataChangeDelay = Duration(milliseconds: 150);
  static const _offscreenChangedIndex = 5;

  late final List<_ExampleItem> _items;
  late final IndexedScrollController _scrollController;
  String _status = 'Ready. Run a scenario from the controls below.';
  bool _isScenarioRunning = false;

  @override
  void initState() {
    super.initState();
    _items = List.generate(
      100,
      (index) => _ExampleItem(
        index: index,
        height: 80.0 + (index % 4) * 30.0,
      ),
    );
    _scrollController = IndexedScrollController(
      scrollDuration: _scenarioDuration,
      itemCount: () => _items.length,
      contentFingerprint: (index) => _items[index].revision,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _runIsc47Scenario() async {
    setState(() {
      _isScenarioRunning = true;
      _status = 'Scrolling to row $_scenarioTargetIndex. Row 0 will change after ${_dataChangeDelay.inMilliseconds} ms.';
    });

    final scroll = _scrollController.scrollTo(
      _scenarioTargetIndex.toDouble(),
      duration: _scenarioDuration,
      curve: Curves.linear,
    );

    await Future<void>.delayed(_dataChangeDelay);
    if (!mounted) {
      try {
        await scroll;
      } catch (_) {
        // Disposing the screen cancels an in-flight scroll; consume that
        // expected result so it does not become an unhandled async error.
      }
      return;
    }

    setState(() {
      final item = _items.first;
      _items[0] = item.copyWith(
        height: item.height == 80.0 ? 240.0 : 80.0,
        revision: item.revision + 1,
      );
      _status = 'Row 0 changed while scrollTo($_scenarioTargetIndex) is still running. Waiting for the result…';
    });

    try {
      await scroll;
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Unexpected success: this operation should have been cancelled '
            'after the data change.';
      });
    } on ScrollCancelledException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = error.reason == ScrollCancelReason.dataInvalidated
            ? 'Success: scroll cancelled with ${error.reason} after the data change.'
            : 'Scroll cancelled with ${error.reason}; expected ${ScrollCancelReason.dataInvalidated}.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Unexpected error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isScenarioRunning = false;
        });
      }
    }
  }

  Future<void> _runOffscreenRecoveryScenario() async {
    setState(() {
      _isScenarioRunning = true;
      _status = 'Row $_offscreenChangedIndex is currently off-screen. '
          'Growing it now, with no invalidateMeasurements() call…';
    });

    // No invalidateMeasurements() call: the constructor above passed
    // itemCount/contentFingerprint, so scrollTo() below detects the changed
    // row itself and requests recovery only for that row's cached
    // measurement, without resetting the rest of the cache. SliverList may
    // still build/lay out other rows near the jump on its own.
    final item = _items[_offscreenChangedIndex];
    setState(() {
      _items[_offscreenChangedIndex] = item.copyWith(
        height: item.height == 80.0 ? 240.0 : 80.0,
        revision: item.revision + 1,
      );
    });

    try {
      await _scrollController.scrollTo(
        _scenarioTargetIndex.toDouble(),
        duration: _scenarioDuration,
        curve: Curves.linear,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Success: scrollTo($_scenarioTargetIndex) used row '
            '$_offscreenChangedIndex\'s new size automatically.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Unexpected error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isScenarioRunning = false;
        });
      }
    }
  }

  void _resetScenario() {
    setState(() {
      _items[0] = const _ExampleItem(index: 0, height: 80.0);
      _items[_offscreenChangedIndex] = const _ExampleItem(index: _offscreenChangedIndex, height: 80.0);
      _status = 'Reset. Rows 0 and $_offscreenChangedIndex have their '
          'original height and fingerprint.';
    });
    _scrollController.jumpTo(0.0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Automatic fingerprint-based invalidation')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ScenarioStatus(status: _status),
          _ScrollOffsetStatus(controller: _scrollController),
          Expanded(
            child: IndexedScrollGestureDetector(
              controller: _scrollController,
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return _scrollController.watch(
                    index: index,
                    child: SizedBox(
                      height: item.height,
                      child: ColoredBox(
                        color: index.isEven ? const Color(0xFFE8F0FE) : const Color(0xFFF4F4F4),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('Row ${item.index}: ${item.height.toStringAsFixed(0)} px, revision ${item.revision}'),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _isScenarioRunning ? null : _runIsc47Scenario,
                        child: const Text('Cancel scroll on data change'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _isScenarioRunning ? null : _runOffscreenRecoveryScenario,
                        child: const Text('Grow off-screen row, no reset'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _isScenarioRunning ? null : _resetScenario,
                  child: const Text('Reset'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScenarioStatus extends StatelessWidget {
  final String status;

  const _ScenarioStatus({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFFF8E1),
      padding: const EdgeInsets.all(16),
      child: Text(status),
    );
  }
}

class _ScrollOffsetStatus extends StatelessWidget {
  final IndexedScrollController controller;

  const _ScrollOffsetStatus({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) {
        if (!controller.hasClients) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('Current offset: ${controller.offset.toStringAsFixed(1)}'),
        );
      },
    );
  }
}

class _ExampleItem {
  final int index;
  final double height;
  final int revision;

  const _ExampleItem({
    required this.index,
    required this.height,
    this.revision = 0,
  });

  _ExampleItem copyWith({double? height, int? revision}) {
    return _ExampleItem(
      index: index,
      height: height ?? this.height,
      revision: revision ?? this.revision,
    );
  }
}
