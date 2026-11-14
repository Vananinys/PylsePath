import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/app_image_cache.dart';
import '../data/user_scope.dart';

ImageProvider appImageProvider(String source) => CachedNetworkImageProvider(
  source,
  cacheManager: AppImageCache.instance,
  cacheKey: imageCacheKey(source, UserScope.currentUserId()),
);

Widget appNetworkImage(
  String source, {
  Key? key,
  double? width,
  double? height,
  BoxFit? fit,
  int? cacheWidth,
  ImageLoadingBuilder? loadingBuilder,
  ImageErrorWidgetBuilder? errorBuilder,
}) => Image(
  key: key,
  image: ResizeImage.resizeIfNeeded(cacheWidth, null, appImageProvider(source)),
  width: width,
  height: height,
  fit: fit,
  loadingBuilder: loadingBuilder,
  errorBuilder: errorBuilder,
);

Future<void> evictAppImage(String source) async {
  await appImageProvider(source).evict();
  await AppImageCache.instance.removeFile(
    imageCacheKey(source, UserScope.currentUserId()),
  );
}
