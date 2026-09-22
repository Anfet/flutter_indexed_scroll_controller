import 'package:flutter/material.dart';
import 'package:indexed_scroll_controller/indexed_scroll_controller.dart';

/// Shows the controller's current offset, appending an inline warning span
/// once the scroll position sits at its physical `minScrollExtent`/
/// `maxScrollExtent`.
///
/// scrollTo() clamps its target offset to those bounds, so a target near the
/// start or end of the list can visibly fall short of where `alignment`
/// would otherwise place it -- the inline warning flags that condition
/// instead of leaving it looking like a bug in the reported offset. Kept as
/// a single line of text (not a separate chip) so its presence never changes
/// the space the list below it gets.
class OffsetStatusText extends StatelessWidget {
  final IndexedScrollController controller;

  const OffsetStatusText({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, child) {
        if (!controller.hasClients) {
          return const Text('Current offset: -');
        }

        final position = controller.position;
        String? boundaryLabel;
        if (position.hasContentDimensions) {
          final atStart = position.pixels <= position.minScrollExtent;
          final atEnd = position.pixels >= position.maxScrollExtent;
          if (atStart && atEnd) {
            boundaryLabel = ' (at list bounds — start & end)';
          } else if (atStart) {
            boundaryLabel = ' (at list start)';
          } else if (atEnd) {
            boundaryLabel = ' (at list end)';
          }
        }

        final baseStyle = DefaultTextStyle.of(context).style;
        return Text.rich(
          TextSpan(
            style: baseStyle,
            children: [
              TextSpan(
                  text:
                      'Current offset: ${controller.offset.toStringAsFixed(1)} px'),
              if (boundaryLabel != null)
                TextSpan(
                  text: boundaryLabel,
                  style: const TextStyle(
                      color: Color(0xFF8A6D00), fontWeight: FontWeight.bold),
                ),
            ],
          ),
        );
      },
    );
  }
}
