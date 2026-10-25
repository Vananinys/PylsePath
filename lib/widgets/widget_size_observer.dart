import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class WidgetSizeObserver extends SingleChildRenderObjectWidget {
  const WidgetSizeObserver({
    super.key,
    required this.onSize,
    required super.child,
  });
  final ValueChanged<Size> onSize;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SizeObserver(onSize);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) => (renderObject as _SizeObserver).onSize = onSize;
}

class _SizeObserver extends RenderProxyBox {
  _SizeObserver(this.onSize);
  ValueChanged<Size> onSize;
  Size? _previous;
  @override
  void performLayout() {
    super.performLayout();
    if (size == _previous) return;
    _previous = size;
    final observed = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onSize(observed);
    });
  }
}
