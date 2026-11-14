import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:pulsepath/config.dart';
import 'package:pulsepath/data/app_image_cache.dart';
import 'package:pulsepath/data/app_image_cache_platform_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('signed URL tokens share a key, accounts and versions do not', () {
    const base =
        'https://example.test/storage/v1/object/sign/chat_media/a/photo.jpg';
    expect(
      imageCacheKey('$base?token=old', 'a'),
      imageCacheKey('$base?token=new', 'a'),
    );
    expect(
      imageCacheKey('$base?token=old', 'a'),
      isNot(imageCacheKey('$base?token=old', 'b')),
    );
    expect(
      imageCacheKey('$base?token=old&width=100', 'a'),
      isNot(imageCacheKey('$base?token=new&width=200', 'a')),
    );
    expect(
      imageCacheKey('https://example.test/avatar.jpg?v=1', 'a'),
      isNot(imageCacheKey('https://example.test/avatar.jpg?v=2', 'a')),
    );
    expect(
      imageCacheKey('chat:a/photo.jpg', 'a'),
      imageCacheKey(
        '${AppConfig.supabaseUrl}/storage/v1/object/sign/chat_media/a/photo.jpg?token=old',
        'a',
      ),
    );
  });

  test('disk survives manager restart and token expiry with no second HTTP request', () async {
    final root = await Directory.systemTemp.createTemp(
      'pulsepath-image-cache-',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    var online = true;
    server.listen((request) async {
      requests++;
      request.response.statusCode = online ? 200 : 503;
      request.response.headers.set('cache-control', 'max-age=0');
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    });
    AppImageCache open({int maxBytes = 256 * 1024 * 1024}) => AppImageCache(
      maxBytes: maxBytes,
      configuration: Config(
        'qa',
        repo: JsonCacheInfoRepository(path: '${root.path}/index.json'),
        fileSystem: PersistentImageFileSystem(
          supportPath: () async => root.path,
        ),
        stalePeriod: const Duration(days: 180),
        maxNrOfCacheObjects: 600,
      ),
    );
    final url =
        'http://127.0.0.1:${server.port}/storage/v1/object/sign/chat_media/a/photo.png';
    var cache = open();
    final first =
        (await cache
                .getFileStream(
                  '$url?token=old',
                  key: imageCacheKey('$url?token=old', 'a'),
                )
                .toList())
            .whereType<FileInfo>()
            .single;
    expect(await first.file.readAsBytes(), [1, 2, 3, 4]);
    expect(first.file.path, contains('image_cache_v1'));
    expect(requests, 1);
    await cache.dispose();
    online = false;
    cache = open();
    final second =
        (await cache
                .getFileStream(
                  '$url?token=new',
                  key: imageCacheKey('$url?token=new', 'a'),
                )
                .toList())
            .whereType<FileInfo>()
            .single;
    expect(await second.file.readAsBytes(), [1, 2, 3, 4]);
    expect(requests, 1);
    // A different account cannot read the first account's disk entry.
    expect(
      await cache.getFileFromCache(imageCacheKey('$url?token=new', 'b')),
      isNull,
    );
    // Cache miss offline is an error, not an invalid persisted file.
    await expectLater(
      cache
          .getFileStream(
            '$url?token=new',
            key: imageCacheKey('$url?token=new', 'b'),
          )
          .toList(),
      throwsA(isA<HttpExceptionWithStatus>()),
    );
    expect(
      await cache.getFileFromCache(imageCacheKey('$url?token=new', 'b')),
      isNull,
    );
    await cache.dispose();
    await server.close(force: true);
  });

  test(
    'cached private chat reference opens offline, cache remains bounded',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'pulsepath-image-budget-',
      );
      final cache = AppImageCache(
        maxBytes: 4,
        configuration: Config(
          'budget',
          repo: JsonCacheInfoRepository(path: '${root.path}/index.json'),
          fileSystem: PersistentImageFileSystem(
            supportPath: () async => root.path,
          ),
        ),
      );
      const source = 'chat:a/photo.jpg';
      final key = imageCacheKey(source, 'a');
      await cache.putFile(
        'https://unused.invalid/a',
        Uint8List.fromList([1, 2, 3, 4]),
        key: key,
        maxAge: Duration.zero,
      );
      final entry =
          (await cache.getFileStream(source, key: key).toList()).single
              as FileInfo;
      expect(await entry.file.readAsBytes(), [1, 2, 3, 4]);
      await expectLater(
        cache
            .getFileStream(
              'chat:a/missing.jpg',
              key: imageCacheKey('chat:a/missing.jpg', 'a'),
            )
            .toList(),
        throwsStateError,
      );
      await cache.putFile(
        'https://unused.invalid/b',
        Uint8List.fromList([5, 6, 7, 8]),
        key: 'another',
      );
      await cache
          .getFileStream('https://unused.invalid/b', key: 'another')
          .toList();
      await cache.dispose();
      final repo = JsonCacheInfoRepository(path: '${root.path}/index.json');
      await repo.open();
      expect(await repo.get(key), isNull);
      expect(await repo.get('another'), isNotNull);
      await repo.close();
    },
  );
}
