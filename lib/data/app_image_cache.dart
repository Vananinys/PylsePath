import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../config.dart';
import 'app_image_cache_platform.dart';

/// Only the expiring authorization token is ignored. Host, path and all
/// transformation/version parameters remain part of the account-scoped key.
String imageCacheIdentity(String source) {
  if (source.startsWith('chat:')) {
    return '${AppConfig.supabaseUrl}/storage/v1/object/sign/chat_media/${source.substring(5)}';
  }
  final uri = Uri.tryParse(source);
  if (uri == null || !uri.path.startsWith('/storage/v1/object/sign/')) {
    return source;
  }
  final params = Map<String, List<String>>.from(uri.queryParametersAll)
    ..remove('token');
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    queryParameters: params.isEmpty ? null : params,
    fragment: uri.fragment.isEmpty ? null : uri.fragment,
  ).toString();
}

String imageCacheKey(String source, String? owner) => sha256
    .convert(utf8.encode(jsonEncode([owner, imageCacheIdentity(source)])))
    .toString();

bool immutableImage(String source) =>
    source.startsWith('chat:') ||
    (Uri.tryParse(source)?.path.startsWith('/storage/v1/object/sign/') ??
        false);

class AppImageCache extends CacheManager {
  AppImageCache({Config? configuration, this.maxBytes = 256 * 1024 * 1024})
    : super(configuration ?? imageCacheConfig());
  static final AppImageCache instance = AppImageCache();
  final int maxBytes;
  Future<void> _cleanup = Future.value();

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    if (immutableImage(url)) {
      final cached = await getFileFromCache(key ?? url);
      if (cached != null) {
        yield cached;
        return;
      }
    }
    // An unresolved private reference can read disk, but cannot be downloaded
    // without a fresh signed URL from the existing authorized service.
    if (url.startsWith('chat:')) throw StateError('Photo is not cached yet');
    await for (final response in super.getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    )) {
      yield response;
      if (response is FileInfo) {
        _cleanup = _cleanup
            .then((_) => _trim(key ?? url))
            .catchError((Object _) {});
      }
    }
  }

  @override
  Future<void> dispose() async {
    await _cleanup;
    await super.dispose();
  }

  Future<void> _trim(String activeKey) async {
    await config.repo.open();
    final entries = await config.repo.getAllObjects();
    entries.sort(
      (a, b) =>
          (a.touched ?? DateTime(1970)).compareTo(b.touched ?? DateTime(1970)),
    );
    final lengths = <String, int>{};
    for (final entry in entries) {
      if (entry.length != null) {
        lengths[entry.key] = entry.length!;
      } else {
        final file = await config.fileSystem.createFile(entry.relativePath);
        lengths[entry.key] = await file.exists() ? await file.length() : 0;
      }
    }
    var size = lengths.values.fold<int>(0, (a, b) => a + b);
    for (final entry in entries) {
      if (size <= maxBytes) break;
      if (entry.key == activeKey) continue;
      await removeFile(entry.key);
      size -= lengths[entry.key] ?? 0;
    }
  }
}
