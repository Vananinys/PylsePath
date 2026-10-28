import 'package:flutter/material.dart';

import '../models/ride_media.dart';
import '../services/ride_media_service.dart';
import 'chat_photo.dart';
import 'chat_video_player.dart';

class SharedRideMediaViewer extends StatefulWidget {
  const SharedRideMediaViewer({super.key, required this.media});
  final SharedRideMedia media;
  @override
  State<SharedRideMediaViewer> createState() => _SharedRideMediaViewerState();
}

class _SharedRideMediaViewerState extends State<SharedRideMediaViewer> {
  late Future<String> _url = RideMediaService.signedUrl(widget.media.reference);
  Future<void> _retry() async {
    setState(() => _url = RideMediaService.signedUrl(widget.media.reference));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _url,
    builder: (context, snapshot) {
      if (snapshot.hasData && widget.media.kind == RideMediaKind.video) {
        return ChatVideoPlayer(
          source: snapshot.data!,
          autoPlay: true,
          onRefresh: () => RideMediaService.signedUrl(widget.media.reference),
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.media.caption.isEmpty
                ? 'Фото на треке'
                : widget.media.caption,
          ),
        ),
        body: SafeArea(
          child: snapshot.hasData
              ? Center(
                  child: InteractiveViewer(
                    child: ChatPhoto(
                      source: snapshot.data!,
                      onRetry: _retry,
                      fullScreen: true,
                    ),
                  ),
                )
              : snapshot.hasError
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Материал недоступен или нет сети'),
                      TextButton(
                        onPressed: _retry,
                        child: const Text('Повторить'),
                      ),
                    ],
                  ),
                )
              : const Center(child: CircularProgressIndicator()),
        ),
      );
    },
  );
}
