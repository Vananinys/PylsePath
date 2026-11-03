import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// Test overrides the platform instance provided transitively by path_provider.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/community_draft_store.dart';

class DraftPaths extends PathProviderPlatform {
  DraftPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('another editor restores body, photos, ride and audience for the same account', () async {
    final first = CommunityDraftStore('owner-a');
    final payload = {
      'body': 'Поездка у реки',
      'photos': ['local-a.jpg', 'local-b.png'],
      'ride_id': 'ride-local',
      'audience': 'friends',
    };
    await first.write(payload);
    final restored = await CommunityDraftStore('owner-a').read();
    expect(restored, {'version': 1, ...payload});
    // Persisted draft contains no prior permission to share geometry or media.
    expect(restored!.containsKey('shareGpx'), isFalse);
    expect(restored.containsKey('rideMediaIds'), isFalse);
  });

  test('account B cannot read or clear account A draft', () async {
    final a = CommunityDraftStore('owner-a'),
        b = CommunityDraftStore('owner-b');
    await a.write({'body': 'A', 'audience': 'friends'});
    expect(await b.read(), isNull);
    await b.write({'body': 'B'});
    await b.clear();
    expect(await b.read(), isNull);
    expect((await a.read())!['body'], 'A');
  });

  test('queued saves cannot revive a cleared published draft', () async {
    final store = CommunityDraftStore('owner-a');
    final saves = <Future<void>>[];
    for (var i = 0; i < 25; i++) {
      saves.add(store.write({'body': 'version-$i'}));
    }
    final clear = store.clear();
    await Future.wait([...saves, clear]);
    expect(await CommunityDraftStore('owner-a').read(), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(store.key)!), {
      'version': 1,
      'cleared': true,
    });
    await store.write({'body': 'New post'});
    expect((await store.read())!['body'], 'New post');
  });

  test('invalid JSON is preserved before a fresh draft replaces it', () async {
    final store = CommunityDraftStore('owner-a');
    const raw = '{unreadable-original';
    SharedPreferences.setMockInitialValues({store.key: raw});
    await expectLater(store.read(), throwsFormatException);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(store.key), raw);
    expect(prefs.getString('${store.key}_unreadable_backup'), raw);
    await store.write({'body': 'Recovered editor'});
    expect(prefs.getString('${store.key}_unreadable_backup'), raw);
  });

  test(
    'unknown future format is backed up rather than silently read as empty',
    () async {
      final store = CommunityDraftStore('owner-a');
      final raw = jsonEncode({'version': 99, 'body': 'future draft'});
      SharedPreferences.setMockInitialValues({store.key: raw});
      await expectLater(store.read(), throwsFormatException);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(store.key), raw);
      expect(prefs.getString('${store.key}_unreadable_backup'), raw);
    },
  );

  test(
    'staged photos are independent durable files isolated by account',
    () async {
      final root = Directory(
        'audit/draft-photos-${DateTime.now().microsecondsSinceEpoch}',
      );
      await root.create(recursive: true);
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = DraftPaths(root.absolute.path);
      addTearDown(() => PathProviderPlatform.instance = previous);
      final source = File('${root.path}/picked.png');
      final pixels = [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3];
      await source.writeAsBytes(pixels);
      final a = CommunityDraftStore('owner-a'),
          b = CommunityDraftStore('owner-b');
      final paths = await Future.wait([
        a.stagePhoto(source.path),
        a.stagePhoto(source.path),
        b.stagePhoto(source.path),
      ]);
      expect(paths.toSet(), hasLength(3));
      expect(paths[0], contains('owner-a'));
      expect(paths[2], contains('owner-b'));
      await source.writeAsBytes([0]);
      for (final path in paths) {
        expect(await File(path).readAsBytes(), pixels);
      }
      await a.write({'photos': paths.take(2).toList(), 'body': ''});
      final restored = await CommunityDraftStore('owner-a').read();
      expect(restored!['photos'], paths.take(2).toList());
    },
  );
  test(
    'staging retains HEIC and WebP suffixes and rejects unknown formats',
    () async {
      final root = Directory(
        'audit/draft-formats-${DateTime.now().microsecondsSinceEpoch}',
      );
      await root.create(recursive: true);
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = DraftPaths(root.absolute.path);
      addTearDown(() => PathProviderPlatform.instance = previous);
      final store = CommunityDraftStore('owner-a');
      for (final extension in ['HEIC', 'webp', 'jpeg', 'heif']) {
        final original = File('${root.path}/picked.$extension');
        await original.writeAsBytes([1, 2, 3]);
        final staged = await store.stagePhoto(original.path);
        expect(staged, endsWith('.${extension.toLowerCase()}'));
        expect(await File(staged).readAsBytes(), [1, 2, 3]);
      }
      final unknown = File('${root.path}/picked.bin');
      await unknown.writeAsBytes([1, 2, 3]);
      await expectLater(store.stagePhoto(unknown.path), throwsFormatException);
      expect(await unknown.readAsBytes(), [1, 2, 3]);
    },
  );
  test('video draft survives a new store with topics and namespaced route selection', () async {
    final root = Directory(
      'audit/draft-video-${DateTime.now().microsecondsSinceEpoch}',
    );
    await root.create(recursive: true);
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = DraftPaths(root.absolute.path);
    addTearDown(() => PathProviderPlatform.instance = previous);
    final store = CommunityDraftStore('owner-a');
    for (final suffix in ['MP4', 'mov', 'm4v', 'webm']) {
      final original = File('${root.path}/clip.$suffix');
      await original.writeAsBytes([1, 2, 3, 4]);
      final staged = await store.stageVideo(original.path);
      expect(staged, endsWith('.${suffix.toLowerCase()}'));
      expect(staged, contains('community_drafts/owner-a'));
      await store.write({
        'body': 'Маршрут и видео',
        'video': staged,
        'topics': ['cycling', 'route'],
        'ride_id': 'route:local-plan',
        'audience': 'friends',
        'photos': <String>[],
      });
      await original.writeAsBytes([0]);
      final restored = (await CommunityDraftStore('owner-a').read())!;
      expect(restored['ride_id'], 'route:local-plan');
      expect(restored['topics'], ['cycling', 'route']);
      expect(await File(restored['video'] as String).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      expect(await CommunityDraftStore('owner-b').read(), isNull);
      expect(restored.containsKey('shareGpx'), isFalse);
    }
  });
  test(
    'video staging enforces the 50 MiB boundary and rejects unsupported files',
    () async {
      final root = Directory(
        'audit/draft-video-limit-${DateTime.now().microsecondsSinceEpoch}',
      );
      await root.create(recursive: true);
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = DraftPaths(root.absolute.path);
      addTearDown(() => PathProviderPlatform.instance = previous);
      final store = CommunityDraftStore('owner-a');
      final exact = File('${root.path}/exact.mp4');
      final handle = await exact.open(mode: FileMode.write);
      await handle.setPosition(50 * 1024 * 1024 - 1);
      await handle.writeByte(0);
      await handle.close();
      final staged = await store.stageVideo(exact.path);
      expect(await File(staged).length(), 50 * 1024 * 1024);
      final append = await exact.open(mode: FileMode.append);
      await append.writeByte(0);
      await append.close();
      await expectLater(store.stageVideo(exact.path), throwsFormatException);
      expect(await exact.length(), 50 * 1024 * 1024 + 1);
      final bad = File('${root.path}/clip.avi');
      await bad.writeAsBytes([1]);
      await expectLater(store.stageVideo(bad.path), throwsFormatException);
      expect(await bad.readAsBytes(), [1]);
    },
  );
}
