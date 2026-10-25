import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';

/// A physical left swipe reveals Reply; it never dismisses the message.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });
  final Widget child;
  final VoidCallback onReply;
  final bool enabled;
  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  static const _threshold = 56.0;
  double _offset = 0;
  bool _armed = false;
  late final _return = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  double _start = 0;
  @override
  void initState() {
    super.initState();
    _return.addListener(
      () => setState(
        () => _offset =
            _start * (1 - Curves.easeOutCubic.transform(_return.value)),
      ),
    );
  }

  void _reset() {
    _start = _offset;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _offset = 0);
    } else {
      _return.forward(from: 0);
    }
    _armed = false;
  }

  @override
  void dispose() {
    _return.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    customSemanticsActions: widget.enabled
        ? {const CustomSemanticsAction(label: 'Ответить'): widget.onReply}
        : null,
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: widget.enabled
          ? (_) {
              _return.stop();
              _armed = false;
            }
          : null,
      onHorizontalDragUpdate: widget.enabled
          ? (details) {
              setState(
                () => _offset = (_offset - details.delta.dx).clamp(0.0, 80.0),
              );
              final armed = _offset >= _threshold;
              if (armed && !_armed) HapticFeedback.selectionClick();
              _armed = armed;
            }
          : null,
      onHorizontalDragCancel: widget.enabled ? _reset : null,
      onHorizontalDragEnd: widget.enabled
          ? (details) {
              final commit =
                  _offset >= _threshold ||
                  (_offset > 12 && (details.primaryVelocity ?? 0) < -650);
              _reset();
              if (commit) widget.onReply();
            }
          : null,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          if (_offset > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Opacity(
                opacity: (_offset / _threshold).clamp(0, 1),
                child: Transform.scale(
                  scale: .7 + .3 * (_offset / _threshold).clamp(0, 1),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer,
                    child: Icon(
                      Icons.reply,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(offset: Offset(-_offset, 0), child: widget.child),
        ],
      ),
    ),
  );
}
