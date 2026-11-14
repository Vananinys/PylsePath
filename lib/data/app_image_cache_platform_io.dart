import 'package:file/file.dart' as fs;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

// Application support survives restarts and OS temporary-cache cleanup.
class PersistentImageFileSystem implements FileSystem {
  PersistentImageFileSystem({Future<String> Function()? supportPath})
    : _supportPath =
          supportPath ??
          (() async => (await getApplicationSupportDirectory()).path);
  final Future<String> Function() _supportPath;
  late final Future<fs.Directory> directory = _directory();
  Future<fs.Directory> _directory() async {
    final support = await _supportPath();
    return const LocalFileSystem()
        .directory('$support/image_cache_v1')
        .create(recursive: true);
  }

  @override
  Future<fs.File> createFile(String name) async {
    final folder = await directory;
    await folder.create(recursive: true);
    return folder.childFile(name);
  }
}

Config imageCacheConfig() => Config(
  'pulsepath_images_v1',
  stalePeriod: const Duration(days: 180),
  maxNrOfCacheObjects: 600,
  fileSystem: PersistentImageFileSystem(),
);
