import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'widget_size_observer.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config/app_variant.dart';
import '../data/user_scope.dart';

/// Transfers the existing map element to a temporary task route. No second map,
/// tile provider, location subscription or recording controller is created.
class PrimaryMapNavigation extends ChangeNotifier {
  static final instance = PrimaryMapNavigation._();
  PrimaryMapNavigation._();
  _PrimaryMapPortalState? _host;
  _MapTask? _task;
  MapController resolve(MapController fallback) => AppVariant.modernInterface
      ? _host?.widget.controller ?? fallback
      : fallback;
  bool get active => _task != null;
  void refresh() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }

  bool tap(TapPosition position, LatLng point) {
    final task = _task;
    if (task == null) return false;
    if (task.owner != UserScope.currentUserId()) return true;
    task.config().options.onTap?.call(position, point);
    refresh();
    return true;
  }

  bool longPress(TapPosition position, LatLng point) {
    if (_task == null) return false;
    if (_task!.owner == UserScope.currentUserId()) {
      _task!.config().options.onLongPress?.call(position, point);
    }
    return true;
  }

  void camera(MapCamera camera, bool gesture) {
    final task = _task;
    if (task != null && task.owner == UserScope.currentUserId()) {
      task.config().options.onPositionChanged?.call(camera, gesture);
    }
  }

  Future<void> open(
    BuildContext context, {
    required String title,
    required FlutterMap Function() config,
    WidgetBuilder? controls,
    WidgetBuilder? footer,
    bool keepCamera = false,
  }) async {
    final host = _host;
    if (host == null || !host.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Основная карта пока недоступна. Вернитесь на карту и повторите.',
          ),
        ),
      );
      return;
    }
    final task = _MapTask(
      title,
      config,
      controls,
      footer,
      UserScope.currentUserId(),
    );
    task.keepCamera = keepCamera;
    FocusManager.instance.primaryFocus?.unfocus();
    task.previous = _task;
    if (_task != null) task.previousCamera = host.widget.controller.camera;
    _task = task;
    host.widget.onOpen();
    refresh();
    try {
      await Navigator.of(context, rootNavigator: true).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, __, ___) =>
              InheritedTheme.captureAll(context, _PrimaryMapTask(task: task)),
        ),
      );
    } finally {
      if (identical(_task, task)) {
        _task = task.previous?.owner == UserScope.currentUserId()
            ? task.previous
            : null;
        _restoreCamera(task);
        refresh();
      }
    }
  }

  void _restoreCamera(_MapTask task) {
    final camera = task.previousCamera;
    if (_task != null && _host != null && camera != null) {
      _host!.widget.controller.moveAndRotate(
        camera.center,
        camera.zoom,
        camera.rotation,
      );
    }
  }
}

class _MapTask {
  _MapTask(this.title, this.config, this.controls, this.footer, this.owner);
  final String title;
  final String? owner;
  final FlutterMap Function() config;
  final WidgetBuilder? controls;
  final WidgetBuilder? footer;
  _MapTask? previous;
  MapCamera? previousCamera;
  bool keepCamera = false;
}

class PrimaryMapPortal extends StatefulWidget {
  const PrimaryMapPortal({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.child,
    this.locate,
    this.onLayers,
  });
  final MapController controller;
  final VoidCallback onOpen;
  final Widget child;
  final LatLng? Function()? locate;
  final VoidCallback? onLayers;
  @override
  State<PrimaryMapPortal> createState() => _PrimaryMapPortalState();
}

class _PrimaryMapPortalState extends State<PrimaryMapPortal> {
  final _element = GlobalKey(debugLabel: 'single-primary-map');
  final _navigation = PrimaryMapNavigation.instance;
  Widget surface() => SizedBox.expand(
    child: KeyedSubtree(key: _element, child: widget.child),
  );
  @override
  void initState() {
    super.initState();
    _navigation._host = this;
    _navigation.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant PrimaryMapPortal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_navigation.active) _navigation.refresh();
  }

  @override
  void dispose() {
    _navigation.removeListener(_changed);
    if (identical(_navigation._host, this)) {
      _navigation._host = null;
      _navigation._task = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _navigation.active ? const SizedBox.expand() : surface();
}

class _PrimaryMapTask extends StatefulWidget {
  const _PrimaryMapTask({required this.task});
  final _MapTask task;
  @override
  State<_PrimaryMapTask> createState() => _PrimaryMapTaskState();
}

class _PrimaryMapTaskState extends State<_PrimaryMapTask> {
  final _navigation = PrimaryMapNavigation.instance;
  double _headerHeight = 96;
  bool _panelExpanded = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_navigation._task, widget.task)) return;
      final config = widget.task.config();
      final map = _navigation._host!.widget.controller;
      try {
        final fit = config.options.initialCameraFit;
        if (!widget.task.keepCamera && fit != null) {
          map.fitCamera(fit);
        } else if (!widget.task.keepCamera) {
          map.move(config.options.initialCenter, config.options.initialZoom);
        }
        config.options.onMapReady?.call();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Не удалось изменить масштаб. Карту можно переместить вручную.',
              ),
            ),
          );
        }
      }
    });
  }

  void _close() {
    final previous = widget.task.previous;
    _navigation._task = previous?.owner == UserScope.currentUserId()
        ? previous
        : null;
    _navigation._restoreCamera(widget.task);
    _navigation.refresh();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _navigation,
    builder: (context, _) {
      final task = widget.task;
      final valid =
          identical(_navigation._task, task) &&
          task.owner == UserScope.currentUserId();
      return Scaffold(
        body: Stack(
          children: [
            if (valid && _navigation._host != null)
              _navigation._host!.surface(),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: WidgetSizeObserver(
                  onSize: (size) {
                    if (mounted && (size.height - _headerHeight).abs() > 1) {
                      setState(() => _headerHeight = size.height);
                    }
                  },
                  child: Material(
                    borderRadius: BorderRadius.circular(18),
                    elevation: 3,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: _close,
                            tooltip: 'Вернуться',
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                          Expanded(
                            child: Text(
                              task.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          TextButton(
                            onPressed: _close,
                            child: Text(
                              task.title.contains('маршрут')
                                  ? 'Закрыть'
                                  : 'Готово',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (valid)
              Positioned(
                right: 12,
                top: MediaQuery.paddingOf(context).top + _headerHeight + 32,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_navigation._host?.widget.locate != null)
                      IconButton.filledTonal(
                        tooltip: 'Моё местоположение',
                        icon: const Icon(Icons.my_location),
                        onPressed: () {
                          final point = _navigation._host?.widget.locate
                              ?.call();
                          if (point == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Ожидается GPS-позиция. Можно выбрать место вручную.',
                                ),
                              ),
                            );
                          } else {
                            _navigation._host!.widget.controller.move(
                              point,
                              _navigation._host!.widget.controller.camera.zoom,
                            );
                          }
                        },
                      ),
                    if (_navigation._host?.widget.onLayers != null)
                      IconButton.filledTonal(
                        tooltip: 'Слой карты',
                        onPressed: _navigation._host!.widget.onLayers,
                        icon: const Icon(Icons.layers_outlined),
                      ),
                    IconButton.filledTonal(
                      tooltip: 'Приблизить',
                      icon: const Icon(Icons.add),
                      onPressed: () {
                        final map = _navigation._host!.widget.controller;
                        map.move(map.camera.center, map.camera.zoom + 1);
                      },
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Отдалить',
                      icon: const Icon(Icons.remove),
                      onPressed: () {
                        final map = _navigation._host!.widget.controller;
                        map.move(map.camera.center, map.camera.zoom - 1);
                      },
                    ),
                  ],
                ),
              ),
            if (valid)
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: Material(
                    elevation: 4,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            MediaQuery.sizeOf(context).height *
                            (task.footer != null && _panelExpanded ? .72 : .42),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (task.footer != null)
                            SizedBox(
                              height: 36,
                              child: Center(
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  tooltip: _panelExpanded
                                      ? 'Свернуть панель'
                                      : 'Развернуть панель',
                                  onPressed: () => setState(
                                    () => _panelExpanded = !_panelExpanded,
                                  ),
                                  icon: Icon(
                                    _panelExpanded
                                        ? Icons.keyboard_arrow_down
                                        : Icons.keyboard_arrow_up,
                                  ),
                                ),
                              ),
                            ),
                          Flexible(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child:
                                  task.controls?.call(context) ??
                                  Text(
                                    task.config().options.onTap == null
                                        ? 'Перемещайте и масштабируйте карту. Нажмите «Готово», чтобы вернуться.'
                                        : 'Нажмите на карте, чтобы выбрать точку. Затем нажмите «Готово» и продолжите настройку.',
                                  ),
                            ),
                          ),
                          if (task.footer != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: SizedBox(
                                width: double.infinity,
                                child: task.footer!(context),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// Reuses layer configurations from old screens without mounting their map.
/// Their forms and actions remain alive while the primary map is on top.
class MainMapGateway extends StatefulWidget {
  const MainMapGateway({
    super.key,
    required this.map,
    required this.title,
    this.autoOpen = false,
    this.controls,
    this.footer,
    this.keepCamera = false,
    this.onClosed,
  });
  final FlutterMap map;
  final String title;
  final bool autoOpen;
  final WidgetBuilder? controls;
  final WidgetBuilder? footer;
  final bool keepCamera;
  final VoidCallback? onClosed;
  @override
  State<MainMapGateway> createState() => _MainMapGatewayState();
}

class _MainMapGatewayState extends State<MainMapGateway> {
  bool _opening = false;
  @override
  void initState() {
    super.initState();
    if (AppVariant.modernInterface && widget.autoOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open();
      });
    }
  }

  @override
  void didUpdateWidget(covariant MainMapGateway oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_opening) PrimaryMapNavigation.instance.refresh();
  }

  Future<void> _open() async {
    if (_opening || PrimaryMapNavigation.instance._host == null) return;
    setState(() => _opening = true);
    try {
      await PrimaryMapNavigation.instance.open(
        context,
        title: widget.title,
        config: () => widget.map,
        controls: widget.controls,
        footer: widget.footer,
        keepCamera: widget.keepCamera,
      );
    } finally {
      if (mounted) {
        setState(() => _opening = false);
        widget.onClosed?.call();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppVariant.modernInterface) return widget.map;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxHeight < 190
            ? Center(
                child: TextButton.icon(
                  onPressed: _opening ? null : _open,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('На основной карте'),
                ),
              )
            : Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.map_outlined,
                        size: 36,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(widget.title, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _opening ? null : _open,
                        icon: const Icon(Icons.open_in_full),
                        label: const Text('На основной карте'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class PrimaryMapTaskLayers extends StatelessWidget {
  const PrimaryMapTaskLayers({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PrimaryMapNavigation.instance,
    builder: (context, _) {
      final task = PrimaryMapNavigation.instance._task;
      if (task == null || task.owner != UserScope.currentUserId()) {
        return const SizedBox.shrink();
      }
      return Stack(
        children: [
          for (final layer in task.config().children)
            if (layer is! TileLayer &&
                layer is! ColoredBox &&
                layer is! RichAttributionWidget &&
                !(layer is ColorFiltered && layer.child is TileLayer))
              layer,
        ],
      );
    },
  );
}

class PrimaryMapBaseLayers extends StatelessWidget {
  const PrimaryMapBaseLayers({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PrimaryMapNavigation.instance,
    builder: (context, _) => IgnorePointer(
      ignoring: PrimaryMapNavigation.instance.active,
      child: child,
    ),
  );
}
