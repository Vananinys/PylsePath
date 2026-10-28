import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';

enum UpdateChannel { stable, beta }

class AppRelease {
  const AppRelease({
    required this.versionCode,
    required this.versionName,
    required this.apkPath,
    required this.apkUrl,
    required this.apkSha256,
    required this.apkSizeBytes,
    required this.notes,
    this.channel = UpdateChannel.stable,
    this.sourceCommit,
  });

  final int versionCode;
  final String versionName;
  final String apkPath;
  final String? apkUrl;
  final String apkSha256;
  final int apkSizeBytes;
  final String notes;
  final UpdateChannel channel;
  final String? sourceCommit;

  static final _pathPattern = RegExp(
    r'^android/([0-9]+)/pulsepath-([0-9]+)\.apk$',
  );
  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    final code = json['version_code'];
    final name = json['version_name'];
    final path = json['apk_path'];
    final downloadUrl = json['apk_url'];
    final hash = json['apk_sha256'];
    final size = json['apk_size_bytes'];
    final notes = json['notes'];
    final channel = json['channel'] ?? 'stable';
    final commit = json['source_commit'];
    final match = path is String ? _pathPattern.firstMatch(path) : null;
    if ((channel != 'stable' && channel != 'beta') ||
        (commit != null &&
            (commit is! String ||
                !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit))) ||
        code is! int ||
        code <= 0 ||
        name is! String ||
        name.isEmpty ||
        name.length > 40 ||
        match == null ||
        match.group(1) != code.toString() ||
        match.group(2) != code.toString() ||
        (downloadUrl != null &&
            (downloadUrl is! String ||
                !_isGithubReleaseUrl(downloadUrl, code, name))) ||
        hash is! String ||
        !_hashPattern.hasMatch(hash) ||
        size is! int ||
        size <= 0 ||
        size > 500000000 ||
        notes is! String ||
        notes.length > 2000) {
      throw const FormatException('Некорректные данные обновления');
    }
    return AppRelease(
      versionCode: code,
      versionName: name,
      apkPath: path,
      apkUrl: downloadUrl as String?,
      apkSha256: hash,
      apkSizeBytes: size,
      notes: notes,
      channel: channel == 'beta' ? UpdateChannel.beta : UpdateChannel.stable,
      sourceCommit: commit as String?,
    );
  }

  static bool _isGithubReleaseUrl(String value, int code, String name) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    if (uri.pathSegments.length < 2 ||
        uri.pathSegments[0] != 'Vananinys' ||
        uri.pathSegments[1] != 'PylsePath') {
      return false;
    }
    return RegExp(
      r'^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/v' +
          RegExp.escape(name) +
          r'/pulsepath-' +
          code.toString() +
          r'\.apk$',
    ).hasMatch(uri.path);
  }
}

class AppUpdateService {
  AppUpdateService._();

  static const _installer = MethodChannel('pulsepath/app_updates');
  static const releasesPageUrl =
      'https://github.com/Vananinys/PylsePath/releases';

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<bool> openReleasesPage() => launchUrl(
    Uri.parse(releasesPageUrl),
    mode: LaunchMode.externalApplication,
  );

  static Future<int> installedVersionCode() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 0;
  }

  static Future<AppRelease?> availableRelease() async {
    if (!supported) return null;
    final channel = await selectedChannel();
    final releases = await releaseHistory(channel: channel);
    return newestCompatible(releases, await installedVersionCode(), channel);
  }

  static const _channelKey = 'app_update_channel_v1';
  static Future<UpdateChannel> selectedChannel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_channelKey) == 'beta'
        ? UpdateChannel.beta
        : UpdateChannel.stable;
  }

  static Future<void> selectChannel(UpdateChannel channel) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_channelKey, channel.name)) {
      await prefs.reload();
      throw StateError('Не удалось сохранить канал обновлений');
    }
  }

  /// Old clients read app_releases only; beta rows never enter that table.
  static Future<List<AppRelease>> releaseHistory({
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    const columns =
        'version_code,version_name,apk_path,apk_url,apk_sha256,apk_size_bytes,notes,source_commit';
    Future<List<AppRelease>> read(String table, UpdateChannel kind) async {
      final rows = await Supabase.instance.client
          .from(table)
          .select(columns)
          .lte('published_at', DateTime.now().toUtc().toIso8601String())
          .order('version_code', ascending: false)
          .limit(100)
          .timeout(const Duration(seconds: 12));
      return rows
          .map((row) => AppRelease.fromJson({...row, 'channel': kind.name}))
          .toList();
    }

    final stable = await read('app_releases', UpdateChannel.stable);
    final beta = channel == UpdateChannel.beta
        ? await read('app_beta_releases', UpdateChannel.beta)
        : <AppRelease>[];
    return [...stable, ...beta]
      ..sort((a, b) => b.versionCode.compareTo(a.versionCode));
  }

  static AppRelease? newestCompatible(
    List<AppRelease> releases,
    int installed,
    UpdateChannel channel,
  ) {
    final candidates =
        releases
            .where(
              (r) =>
                  r.versionCode > installed &&
                  (channel == UpdateChannel.beta ||
                      r.channel == UpdateChannel.stable),
            )
            .toList()
          ..sort((a, b) => b.versionCode.compareTo(a.versionCode));
    return candidates.firstOrNull;
  }

  static Future<File> download(
    AppRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    if (!supported) {
      throw UnsupportedError('Обновления APK доступны на Android');
    }
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates',
    );
    await directory.create(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}pulsepath-${release.versionCode}.apk',
    );
    if (await target.exists() && await _matches(release, target)) {
      onProgress?.call(1);
      return target;
    }
    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();
    final url =
        release.apkUrl ??
        Supabase.instance.client.storage
            .from('app-releases')
            .getPublicUrl(release.apkPath);
    final uri = Uri.parse(url);
    final projectHost = Uri.parse(AppConfig.supabaseUrl).host;
    if (uri.scheme != 'https' ||
        (release.apkUrl == null && uri.host != projectHost) ||
        (release.apkUrl != null && !_isTrustedGithubHost(uri.host))) {
      throw StateError('Недоверенный адрес обновления');
    }
    final client = http.Client();
    try {
      var downloadUri = uri;
      late http.StreamedResponse response;
      for (var redirects = 0; ; redirects++) {
        final request = http.Request('GET', downloadUri)
          ..followRedirects = false
          ..headers['Accept-Encoding'] = 'identity';
        response = await client
            .send(request)
            .timeout(const Duration(seconds: 20));
        final location = response.headers['location'];
        if (response.statusCode < 300 || response.statusCode >= 400) break;
        if (release.apkUrl == null || redirects >= 4 || location == null) {
          await response.stream.drain<void>();
          throw StateError('APK redirect is invalid or too long');
        }
        final nextUri = downloadUri.resolve(location);
        await response.stream.drain<void>();
        if (nextUri.scheme != 'https' ||
            nextUri.userInfo.isNotEmpty ||
            nextUri.hasPort ||
            !_isTrustedGithubHost(nextUri.host)) {
          throw StateError('APK redirect host is not trusted');
        }
        downloadUri = nextUri;
      }
      if (response.statusCode != 200 ||
          (response.contentLength != null &&
              response.contentLength != release.apkSizeBytes)) {
        throw StateError('APK не найден или его размер изменился');
      }
      final sink = partial.openWrite();
      var received = 0;
      var lastProgress = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          final List<int> bytes = chunk;
          received += bytes.length;
          if (received > release.apkSizeBytes) {
            throw StateError('Размер APK больше заявленного');
          }
          sink.add(bytes);
          if (received - lastProgress >= 262144) {
            lastProgress = received;
            onProgress?.call(received / release.apkSizeBytes);
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (received != release.apkSizeBytes ||
          !await _matches(release, partial)) {
        throw StateError('Контрольная сумма APK не совпала');
      }
      if (await target.exists()) await target.delete();
      final ready = await partial.rename(target.path);
      onProgress?.call(1);
      return ready;
    } finally {
      client.close();
      if (await partial.exists()) await partial.delete();
    }
  }

  static Future<bool> _matches(AppRelease release, File file) async {
    if (await file.length() != release.apkSizeBytes) return false;
    final hash = await sha256.bind(file.openRead()).first;
    return hash.toString() == release.apkSha256;
  }

  static bool _isTrustedGithubHost(String host) =>
      host == 'github.com' ||
      host == 'release-assets.githubusercontent.com' ||
      host == 'objects.githubusercontent.com';

  /// Returns false when Android first needs the user to allow installs from
  /// this app. The user can tap Install again after granting that permission.
  static Future<bool> launchInstaller(File apk) async {
    if (!supported) return false;
    final result = await _installer.invokeMethod<String>('installApk', {
      'path': apk.path,
    });
    return result == 'started';
  }
}
