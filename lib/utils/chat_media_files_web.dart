import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

Future<String> retainChatMedia(
  XFile file,
  String owner,
  String id,
  String extension, {
  Uint8List? editedBytes,
}) async => editedBytes == null
    ? file.path
    : XFile.fromData(editedBytes, mimeType: 'image/png', name: '$id.png').path;

VideoPlayerController localVideoController(String source) =>
    VideoPlayerController.networkUrl(Uri.parse(source));

Future<void> removeRetainedChatMedia(
  String owner,
  String id,
  List<String> paths, {
  required bool Function() isCurrent,
}) async {
  // Browser blob URLs are session-local, not files in application support.
}
