import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/file_reader.dart';
import '../data/app_image_cache.dart';
import '../data/user_scope.dart';
import '../config.dart';
import '../services/chat_service.dart';
import 'app_network_image.dart';

/// Local previews and remote images share a real retry/loading state.
class ChatPhoto extends StatefulWidget {
  const ChatPhoto({
    super.key,
    required this.source,
    required this.onRetry,
    this.fullScreen = false,
    this.decodeWidth,
    this.compact = false,
  });
  final String source;
  final Future<void> Function() onRetry;
  final bool fullScreen;
  final int? decodeWidth;
  final bool compact;
  @override
  State<ChatPhoto> createState() => _ChatPhotoState();
}

class _ChatPhotoState extends State<ChatPhoto> with WidgetsBindingObserver {
  Future<Uint8List>? _bytes;
  Future<String>? _network;
  Timer? _retryTimer;
  int _attempts = 0;
  int _generation = 0;
  late final String? _owner = UserScope.currentUserId();
  int _revision = 0;
  bool _retrying = false;
  bool get _remote =>
      widget.source.startsWith('https://') ||
      widget.source.startsWith('http://') ||
      widget.source.startsWith('chat:');
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLocal();
  }

  @override
  void didUpdateWidget(ChatPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _attempts = 0;
      _loadLocal();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _remote) {
      _attempts = 0;
      setState(_loadLocal);
    }
  }

  Future<String> _resolve({bool force = false}) async {
    final source = widget.source;
    if (UserScope.currentUserId() != _owner)
      throw StateError('Account changed');
    final key = imageCacheKey(source, _owner);
    final cached = await AppImageCache.instance.getFileFromCache(key);
    if (UserScope.currentUserId() != _owner)
      throw StateError('Account changed');
    if (cached != null && immutableImage(source)) return source;
    var reference = source;
    final uri = Uri.tryParse(source);
    const marker = '/storage/v1/object/sign/chat_media/';
    if (uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.origin == Uri.parse(AppConfig.supabaseUrl).origin &&
        uri.path.startsWith(marker)) {
      reference =
          'chat:${Uri.decodeComponent(uri.path.substring(marker.length))}';
    }
    final resolved = await ChatService().resolveMedia(reference, force: force);
    if (UserScope.currentUserId() != _owner || resolved == null)
      throw StateError('Photo unavailable');
    return resolved;
  }

  void _scheduleRetry({bool evict = false}) {
    if (_attempts >= 3 || _retryTimer != null || !_remote) return;
    final generation = _generation;
    _retryTimer = Timer(Duration(seconds: 1 << _attempts++), () async {
      _retryTimer = null;
      if (!mounted ||
          generation != _generation ||
          UserScope.currentUserId() != _owner)
        return;
      if (evict) await evictAppImage(widget.source);
      if (!mounted ||
          generation != _generation ||
          UserScope.currentUserId() != _owner)
        return;
      setState(() {
        _revision++;
        _network = _resolve(force: true);
      });
    });
  }

  void _loadLocal() {
    _generation++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _network = _remote ? _resolve() : null;
    _bytes = !_remote && !widget.source.startsWith('chat:')
        ? readBytesFromPath(widget.source)
        : null;
  }

  Widget _error() => widget.compact
      ? const Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: Colors.white,
            size: 24,
          ),
        )
      : SizedBox(
          height: 120,
          child: Center(
            child: TextButton.icon(
              onPressed: _retrying
                  ? null
                  : () async {
                      setState(() => _retrying = true);
                      try {
                        if (!_remote) await widget.onRetry();
                        _attempts = 0;
                      } catch (_) {
                        /* The button stays available. */
                      }
                      if (mounted) {
                        setState(() {
                          _revision++;
                          _loadLocal();
                          _retrying = false;
                        });
                      }
                    },
              icon: const Icon(Icons.refresh),
              label: Text(_retrying ? 'Загружаем…' : 'Загрузить фото'),
            ),
          ),
        );
  @override
  Widget build(BuildContext context) {
    final width = widget.fullScreen ? null : 220.0;
    final fit = widget.fullScreen ? BoxFit.contain : BoxFit.cover;
    final decodeWidth =
        widget.decodeWidth ??
        (widget.fullScreen
            ? null
            : (220 * MediaQuery.devicePixelRatioOf(context)).round().clamp(
                220,
                880,
              ));
    if (_remote) {
      return FutureBuilder<String>(
        future: _network,
        builder: (_, snapshot) {
          if (snapshot.hasError) {
            _scheduleRetry();
            return _error();
          }
          if (!snapshot.hasData)
            return const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            );
          return appNetworkImage(
            snapshot.data!,
            cacheWidth: decodeWidth,
            key: ValueKey('${widget.source}_$_revision'),
            width: width,
            fit: fit,
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()),
                  ),
            errorBuilder: (_, error, stack) {
              _scheduleRetry(evict: true);
              return _error();
            },
          );
        },
      );
    }
    if (_bytes == null) return _error();
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (_, snapshot) => snapshot.hasData
          ? Image.memory(
              snapshot.data!,
              cacheWidth: decodeWidth,
              width: width,
              fit: fit,
              errorBuilder: (_, error, stack) => _error(),
            )
          : snapshot.hasError
          ? _error()
          : const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            ),
    );
  }
}
