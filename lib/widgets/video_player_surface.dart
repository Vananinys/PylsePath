import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/video_metadata.dart';

/// Controls and video share one controller across embedded/fullscreen views.
class VideoPlayerSurface extends StatefulWidget {
  const VideoPlayerSurface({
    super.key,
    required this.controller,
    required this.onFullscreen,
    required this.onRetry,
    this.fullscreen = false,
  });
  final VideoPlayerController controller;
  final VoidCallback onFullscreen, onRetry;
  final bool fullscreen;
  @override
  State<VideoPlayerSurface> createState() => _VideoPlayerSurfaceState();
}

class _VideoPlayerSurfaceState extends State<VideoPlayerSurface> {
  bool _controls = true,
      _scrubbing = false,
      _wasPlaying = false,
      _cover = false;
  double _position = 0;
  Timer? _hide;
  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _show() {
    _hide?.cancel();
    if (mounted) setState(() => _controls = true);
    if (widget.controller.value.isPlaying) {
      _hide = Timer(const Duration(seconds: 3), () {
        if (mounted && !_scrubbing) setState(() => _controls = false);
      });
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) _show();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Не удалось выполнить действие с видео'),
          ),
        );
      }
    }
  }

  Future<void> _play() => _perform(() async {
    final c = widget.controller;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
      await c.play();
    }
  });
  Future<void> _skip(int seconds) => _perform(() async {
    final c = widget.controller;
    final position = (c.value.position.inMilliseconds + seconds * 1000).clamp(
      0,
      c.value.duration.inMilliseconds,
    );
    await c.seekTo(Duration(milliseconds: position));
  });
  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<VideoPlayerValue>(
    valueListenable: widget.controller,
    builder: (context, value, _) {
      if (value.hasError) {
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Воспроизведение прервалось',
                    style: TextStyle(color: Colors.white),
                  ),
                  TextButton(
                    onPressed: widget.onRetry,
                    child: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      final duration = value.duration.inMilliseconds.toDouble().clamp(
        1.0,
        double.infinity,
      );
      final position =
          (_scrubbing ? _position : value.position.inMilliseconds.toDouble())
              .clamp(0.0, duration);
      final buffered = value.buffered
          .fold<double>(
            0,
            (best, range) => range.end.inMilliseconds > best
                ? range.end.inMilliseconds.toDouble()
                : best,
          )
          .clamp(0.0, duration);
      final visible = _controls || !value.isPlaying || _scrubbing;
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: _cover
                  ? SizedBox.expand(
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: value.size.width,
                          height: value.size.height,
                          child: VideoPlayer(widget.controller),
                        ),
                      ),
                    )
                  : AspectRatio(
                      aspectRatio: value.aspectRatio > 0
                          ? value.aspectRatio
                          : 16 / 9,
                      child: VideoPlayer(widget.controller),
                    ),
            ),
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, limits) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _controls = !_controls),
                  onDoubleTapDown: (details) => _skip(
                    details.localPosition.dx < limits.maxWidth / 2 ? -10 : 10,
                  ),
                  onDoubleTap: () {},
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            if (value.isBuffering)
              const Center(
                child: IgnorePointer(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            if (!value.isPlaying && !value.isBuffering)
              Center(
                child: IconButton(
                  key: const ValueKey('video-center-play'),
                  tooltip: 'Смотреть',
                  iconSize: 64,
                  color: Colors.white,
                  onPressed: _play,
                  icon: const Icon(Icons.play_circle_fill),
                ),
              ),
            if (visible)
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: _cover
                          ? 'Показать видео целиком'
                          : 'Заполнить экран',
                      color: Colors.white,
                      onPressed: () => setState(() => _cover = !_cover),
                      icon: Icon(_cover ? Icons.fit_screen : Icons.crop_free),
                    ),
                    PopupMenuButton<double>(
                      tooltip: 'Скорость воспроизведения',
                      initialValue: value.playbackSpeed,
                      icon: const Icon(Icons.speed, color: Colors.white),
                      onSelected: (speed) => _perform(
                        () => widget.controller.setPlaybackSpeed(speed),
                      ),
                      itemBuilder: (_) => [
                        for (final speed in [.5, 1.0, 1.5, 2.0])
                          PopupMenuItem(value: speed, child: Text('$speed×')),
                      ],
                    ),
                  ],
                ),
              ),
            if (visible)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${videoTime(Duration(milliseconds: position.round()))} / ${videoTime(value.duration)}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (value.isBuffering)
                                const Text(
                                  'Загрузка…',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                            ),
                            child: Slider(
                              semanticFormatterCallback: (v) =>
                                  videoTime(Duration(milliseconds: v.round())),
                              value: position,
                              max: duration,
                              secondaryTrackValue: buffered,
                              activeColor: Colors.white,
                              inactiveColor: Colors.white24,
                              secondaryActiveColor: Colors.white54,
                              onChangeStart: (_) {
                                _hide?.cancel();
                                _wasPlaying = value.isPlaying;
                                _perform(() => widget.controller.pause());
                                setState(() {
                                  _position = value.position.inMilliseconds
                                      .toDouble();
                                  _scrubbing = true;
                                });
                              },
                              onChanged: (v) => setState(() => _position = v),
                              onChangeEnd: (v) => _perform(() async {
                                try {
                                  await widget.controller.seekTo(
                                    Duration(milliseconds: v.round()),
                                  );
                                  if (_wasPlaying &&
                                      WidgetsBinding.instance.lifecycleState ==
                                          AppLifecycleState.resumed) {
                                    await widget.controller.play();
                                  }
                                } finally {
                                  if (mounted) {
                                    setState(() => _scrubbing = false);
                                  }
                                }
                              }),
                            ),
                          ),
                          LayoutBuilder(
                            builder: (context, limits) => Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                IconButton(
                                  tooltip: value.isPlaying
                                      ? 'Пауза'
                                      : 'Воспроизвести',
                                  color: Colors.white,
                                  onPressed: _play,
                                  icon: Icon(
                                    value.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Назад на 10 секунд',
                                  color: Colors.white,
                                  onPressed: () => _skip(-10),
                                  icon: const Icon(Icons.replay_10),
                                ),
                                IconButton(
                                  tooltip: 'Вперёд на 10 секунд',
                                  color: Colors.white,
                                  onPressed: () => _skip(10),
                                  icon: const Icon(Icons.forward_10),
                                ),
                                IconButton(
                                  tooltip: value.volume == 0
                                      ? 'Включить звук'
                                      : 'Выключить звук',
                                  color: Colors.white,
                                  onPressed: () => _perform(
                                    () => widget.controller.setVolume(
                                      value.volume == 0 ? 1 : 0,
                                    ),
                                  ),
                                  icon: Icon(
                                    value.volume == 0
                                        ? Icons.volume_off
                                        : Icons.volume_up,
                                  ),
                                ),
                                IconButton(
                                  tooltip: widget.fullscreen
                                      ? 'Выйти из полного экрана'
                                      : 'На весь экран',
                                  color: Colors.white,
                                  onPressed: widget.onFullscreen,
                                  icon: Icon(
                                    widget.fullscreen
                                        ? Icons.fullscreen_exit
                                        : Icons.fullscreen,
                                  ),
                                ),
                              ],
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
