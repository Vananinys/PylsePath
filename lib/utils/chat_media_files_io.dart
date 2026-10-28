import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

Future<String> retainChatMedia(
  XFile file,
  String owner,
  String id,
  String extension, {
  Uint8List? editedBytes,
}) async {
  if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(owner) ||
      !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id) ||
      !RegExp(r'^\.[a-z0-9]+$').hasMatch(extension)) {
    throw const FormatException('Некорректное имя вложения');
  }
  final root = await getApplicationSupportDirectory();
  final folder = await Directory('${root.path}/chat_pending/$owner')
      .create(recursive: true);
  final target = File('${folder.path}/$id$extension');
  if (editedBytes != null) {
    await target.writeAsBytes(editedBytes, flush: true);
  } else {
    await file.saveTo(target.path);
  }
  return target.path;
}

VideoPlayerController localVideoController(String source) =>
    VideoPlayerController.file(File(source));

Future<void> removeRetainedChatMedia(
  String owner,
  String id,
  List<String> paths, {
  required bool Function() isCurrent,
}) async {
  if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(owner) ||
      !RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(id)) {
    return;
  }
  final support = await getApplicationSupportDirectory();
  final root = await support.resolveSymbolicLinks();
  final folder = Directory('${support.path}/chat_pending/$owner');
  if (!await folder.exists()) return;
  String normalized(String p) =>
      Platform.isWindows ? p.replaceAll('\\', '/').toLowerCase() : p;
  final safeFolder = normalized('$root/chat_pending/$owner');
  if (normalized(await folder.resolveSymbolicLinks()) != safeFolder) return;
  final candidates = paths.toSet();
  await for (final entry in folder.list(followLinks: false)) {
    if (entry is File) candidates.add(entry.path);
  }
  for (final path in candidates) {
    if (!isCurrent()) return;
    final file = File(path);
    final name = file.uri.pathSegments.last;
    if (!RegExp('^(poster-)?${RegExp.escape(id)}\\.[a-z0-9]+\$')
        .hasMatch(name)) {
      continue;
    }
    if (!await file.exists()) continue;
    final resolved = normalized(await file.resolveSymbolicLinks());
    if (resolved != '$safeFolder/${normalized(name)}' || !isCurrent()) continue;
    await file.delete();
  }
}
