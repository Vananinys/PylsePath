import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../utils/file_reader.dart';

/// Local previews and remote images share a real retry/loading state.
class ChatPhoto extends StatefulWidget {
  const ChatPhoto({
    super.key,
    required this.source,
    required this.onRetry,
    this.fullScreen = false,
  });
  final String source;
  final Future<void> Function() onRetry;
  final bool fullScreen;
  @override
  State<ChatPhoto> createState() => _ChatPhotoState();
}

class _ChatPhotoState extends State<ChatPhoto> {
  Future<Uint8List>? _bytes;
  int _revision = 0;
  bool _retrying = false;
  bool get _remote =>
      widget.source.startsWith('https://') ||
      widget.source.startsWith('http://');
  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  @override
  void didUpdateWidget(ChatPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _loadLocal();
  }

  void _loadLocal() {
    _bytes = !_remote && !widget.source.startsWith('chat:')
        ? readBytesFromPath(widget.source)
        : null;
  }

  Widget _error() => SizedBox(
    height: 120,
    child: Center(
      child: TextButton.icon(
        onPressed: _retrying
            ? null
            : () async {
                setState(() => _retrying = true);
                try {
                  await widget.onRetry();
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
    if (_remote) {
      return Image.network(
        widget.source,
        key: ValueKey('${widget.source}_$_revision'),
        width: width,
        fit: fit,
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              ),
        errorBuilder: (_, error, stack) => _error(),
      );
    }
    if (_bytes == null) return _error();
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (_, snapshot) => snapshot.hasData
          ? Image.memory(
              snapshot.data!,
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
