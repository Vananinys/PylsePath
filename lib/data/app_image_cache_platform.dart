import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'app_image_cache_platform_stub.dart'
    if (dart.library.io) 'app_image_cache_platform_io.dart'
    as platform;

Config imageCacheConfig() => platform.imageCacheConfig();
