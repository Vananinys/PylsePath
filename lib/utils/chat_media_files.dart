import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import 'chat_media_files_io.dart'
    if (dart.library.html) 'chat_media_files_web.dart'
    as impl;

Future<String> retainChatMedia(
  XFile file,
  String owner,
  String id,
  String extension, {
  Uint8List? editedBytes,
}) =>
    impl.retainChatMedia(file, owner, id, extension, editedBytes: editedBytes);

VideoPlayerController chatVideoController(String source) =>
    source.startsWith('https://') || source.startsWith('http://')
    ? VideoPlayerController.networkUrl(Uri.parse(source))
    : impl.localVideoController(source);

Future<void> removeRetainedChatMedia(
  String owner,
  String id,
  List<String> paths, {
  required bool Function() isCurrent,
}) => impl.removeRetainedChatMedia(owner, id, paths, isCurrent: isCurrent);
