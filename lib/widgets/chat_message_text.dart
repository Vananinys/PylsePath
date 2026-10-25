import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ChatMessageText extends StatefulWidget {
  const ChatMessageText({super.key, required this.text, required this.color});
  final String text;
  final Color color;
  @override
  State<ChatMessageText> createState() => _ChatMessageTextState();
}

class _ChatMessageTextState extends State<ChatMessageText> {
  final _recognizers = <TapGestureRecognizer>[];
  List<InlineSpan> _spans = [];
  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(ChatMessageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.color != widget.color) {
      _prepare();
    }
  }

  void _prepare() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    _spans = [];
    var end = 0;
    for (final match in RegExp(r'https?://[^\s<>]+').allMatches(widget.text)) {
      _spans.add(TextSpan(text: widget.text.substring(end, match.start)));
      final raw = match.group(0)!;
      final url = raw.replaceFirst(RegExp(r'[.,!?;:)\]]+$'), '');
      final recognizer = TapGestureRecognizer()
        ..onTap = () async {
          try {
            if (!await launchUrl(
              Uri.parse(url),
              mode: LaunchMode.externalApplication,
            )) {
              throw StateError('Cannot open');
            }
          } catch (_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Не удалось открыть ссылку. Её можно скопировать из сообщения.',
                  ),
                ),
              );
            }
          }
        };
      _recognizers.add(recognizer);
      _spans.add(
        TextSpan(
          text: url,
          recognizer: recognizer,
          style: const TextStyle(
            decoration: TextDecoration.underline,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
      _spans.add(TextSpan(text: raw.substring(url.length)));
      end = match.end;
    }
    _spans.add(TextSpan(text: widget.text.substring(end)));
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(children: _spans),
    style: TextStyle(fontSize: 15, color: widget.color),
  );
}
