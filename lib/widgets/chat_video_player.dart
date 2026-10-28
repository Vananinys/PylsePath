import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../utils/chat_media_files.dart';
import 'video_player_surface.dart';

class ChatVideoPlayer extends StatefulWidget {
  const ChatVideoPlayer({
    super.key,
    required this.source,
    this.onRefresh,
    this.embedded = false,
    this.autoPlay = false,
  });
  final String source;
  final Future<String?> Function()? onRefresh;
  final bool embedded, autoPlay;
  @override
  State<ChatVideoPlayer> createState() => _ChatVideoPlayerState();
}

class _ChatVideoPlayerState extends State<ChatVideoPlayer>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller, _initializing;
  bool _loading = true, _expanded = false, _hasPlayed = false;
  String? _error;
  int _request = 0;
  double _lastVolume = 1, _lastSpeed = 1;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller?.pause();
  }

  @override
  void didUpdateWidget(ChatVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _hasPlayed = false;
      _load();
    }
  }

  Future<void> _load({bool refresh = false}) async {
    final request = ++_request;
    final previous = _controller;
    final volume = refresh ? _lastVolume : 1.0;
    final speed = refresh ? _lastSpeed : 1.0;
    final position = refresh
        ? previous?.value.position ?? Duration.zero
        : Duration.zero;
    final resume = refresh
        ? (previous == null
              ? widget.autoPlay
              : previous.value.isPlaying ||
                    (previous.value.hasError && _hasPlayed))
        : widget.autoPlay;
    setState(() {
      _loading = true;
      _error = null;
      _controller = null;
    });
    previous?.removeListener(_changed);
    previous?.dispose().catchError((Object _) {});
    final oldPending = _initializing;
    _initializing = null;
    oldPending?.dispose().catchError((Object _) {});
    VideoPlayerController? candidate;
    try {
      final source = refresh || widget.source.startsWith('chat:')
          ? await widget.onRefresh?.call() ?? widget.source
          : widget.source;
      if (!mounted || request != _request) return;
      if (source.startsWith('chat:')) throw StateError('No signed URL');
      candidate = chatVideoController(source);
      _initializing = candidate;
      await candidate.initialize().timeout(const Duration(seconds: 30));
      if (!mounted || request != _request) {
        candidate.dispose().catchError((Object _) {});
        return;
      }
      _initializing = null;
      await candidate.setVolume(volume);
      await candidate.setPlaybackSpeed(speed);
      if (position > Duration.zero) {
        await candidate.seekTo(
          position > candidate.value.duration
              ? candidate.value.duration
              : position,
        );
      }
      if (!mounted || request != _request) {
        candidate.dispose().catchError((Object _) {});
        return;
      }
      _controller = candidate;
      candidate.addListener(_changed);
      setState(() => _loading = false);
      if (resume &&
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused &&
          WidgetsBinding.instance.lifecycleState !=
              AppLifecycleState.inactive &&
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden) {
        await candidate.play();
      }
    } catch (_) {
      candidate?.dispose().catchError((Object _) {});
      if (mounted && request == _request) {
        _initializing = null;
        setState(() {
          _loading = false;
          _error = 'Не удалось открыть видео. Проверьте сеть или формат файла.';
        });
      }
    }
  }

  void _changed() {
    final value = _controller?.value;
    if (value != null && value.isInitialized && !value.hasError) {
      _lastVolume = value.volume;
      _lastSpeed = value.playbackSpeed;
    }
    if (_controller?.value.isPlaying == true) _hasPlayed = true;
    if (mounted) setState(() {});
  }

  Future<void> _fullscreen() async {
    final controller = _controller;
    if (controller == null || _expanded) return;
    setState(() => _expanded = true);
    bool? retry;
    try {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
            .catchError((Object _) {}),
      );
      if (!mounted) return;
      retry = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (full) => Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: VideoPlayerSurface(
                      controller: controller,
                      fullscreen: true,
                      onFullscreen: () => Navigator.pop(full, false),
                      onRetry: () => Navigator.pop(full, true),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IconButton(
                      tooltip: 'Назад к просмотру',
                      onPressed: () => Navigator.pop(full, false),
                      color: Colors.white,
                      icon: const Icon(Icons.arrow_back),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } finally {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
            .catchError((Object _) {}),
      );
      if (mounted) setState(() => _expanded = false);
    }
    if (retry == true && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (mounted) await _load(refresh: true);
    }
  }

  @override
  void dispose() {
    _request++;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_changed);
    _controller?.dispose().catchError((Object _) {});
    _initializing?.dispose().catchError((Object _) {});
    super.dispose();
  }

  Widget _content() {
    final controller = _controller;
    if (_loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    if (_error != null || controller == null || controller.value.hasError) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error ?? 'Воспроизведение прервалось',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                TextButton(
                  onPressed: () => _load(refresh: true),
                  child: const Text('Повторить'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_expanded) {
      return const ColoredBox(color: Colors.black, child: SizedBox.expand());
    }
    return VideoPlayerSurface(
      controller: controller,
      onFullscreen: _fullscreen,
      onRetry: () => _load(refresh: true),
    );
  }

  @override
  Widget build(BuildContext context) => widget.embedded
      ? _content()
      : Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: const Text('Видео'),
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: SafeArea(child: _content()),
        );
}
