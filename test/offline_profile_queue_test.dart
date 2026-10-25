import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/profile_appearance_store.dart';
import 'package:pulsepath/data/user_profile_repository.dart';
import 'package:pulsepath/data/user_scope.dart';
import 'package:pulsepath/models/user_profile.dart';
import 'package:pulsepath/services/profile_presentation_service.dart';
import 'package:pulsepath/services/profile_sync_service.dart';
import 'package:pulsepath/services/network_recovery_sync.dart';

class AppearanceTransport implements ProfilePresentationTransport {
  final sent = <Map<String, dynamic>>[];
  Completer<void>? blocked;
  bool offline = false;
  @override
  Future<Map<String, dynamic>> fetch(
    String userId, {
    bool refreshEarned = false,
  }) async => throw StateError('offline');
  @override
  Future<String> uploadCover(String path) async => 'owner/cover.jpg';
  @override
  Future<void> save(Map<String, dynamic> style, String? titleId) async {
    sent.add(style);
    if (offline) throw StateError('offline');
    await blocked?.future;
  }
}

class BasicTransport extends ProfileSyncService {
  final sent = <String>[];
  final clears = <bool>[];
  Completer<void>? blocked;
  bool offline = false;
  @override
  Future<bool> upsertProfile(
    UserProfile profile, {
    bool clearAvatar = false,
  }) async {
    sent.add(profile.username);
    clears.add(clearAvatar);
    await blocked?.future;
    return !offline;
  }

  @override
  Future<String> uploadAvatar(String path) async {
    if (offline) throw StateError('offline');
    return 'https://example.invalid/avatar.jpg';
  }
}

Future<void> settleQueue() =>
    Future<void>.delayed(const Duration(milliseconds: 15));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'offline-owner';
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProfilePresentationService.resetCachesForTesting();
  });
  ProfileAppearanceStore store() =>
      ProfileAppearanceStore(owner, currentUser: () => owner);
  Map<String, dynamic> snapshot(String bio) => {
    'style': {'bio': bio, 'accent': 'forest'},
    'rewards': [],
  };

  test('legacy appearance loads locally before any server request', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      UserScope.keyFor('progress_cache_v1_presentation', owner),
      jsonEncode(snapshot('Мой профиль')),
    );
    final transport = AppearanceTransport();
    final service = ProfilePresentationService(
      store: store(),
      currentUser: () => owner,
      transport: transport,
    );
    final cached = await service.loadCached(owner);
    expect(cached!.bio, 'Мой профиль');
    expect(cached.accent, 'forest');
    expect(ProfilePresentationService.peek(owner), same(cached));
    expect(transport.sent, isEmpty);
  });

  test(
    'offline appearance survives restart and retries automatically',
    () async {
      final transport = AppearanceTransport()..offline = true;
      final service = ProfilePresentationService(
        store: store(),
        currentUser: () => owner,
        transport: transport,
      );
      await service.save(
        const ProfilePresentation(accent: 'violet', bio: 'Сохранено'),
        null,
      );
      await settleQueue();
      expect((await store().read())!['pending'], true);
      ProfilePresentationService.resetCachesForTesting();
      final restored = ProfilePresentationService(
        store: store(),
        currentUser: () => owner,
        transport: transport,
      );
      expect((await restored.loadCached(owner))!.bio, 'Сохранено');
      transport.offline = false;
      expect(await restored.syncPending(), true);
      expect((await store().read())!['pending'], false);
      expect(transport.sent.last['accent'], 'violet');
    },
  );

  test(
    'in-flight acknowledgement cannot discard a newer appearance edit',
    () async {
      final transport = AppearanceTransport()..blocked = Completer<void>();
      final service = ProfilePresentationService(
        store: store(),
        currentUser: () => owner,
        transport: transport,
      );
      await service.save(const ProfilePresentation(bio: 'Первый'), null);
      await settleQueue();
      expect(transport.sent.length, 1);
      await service.save(const ProfilePresentation(bio: 'Последний'), null);
      transport.blocked!.complete();
      expect(await service.syncPending(), true);
      expect(transport.sent.map((s) => s['bio']), ['Первый', 'Последний']);
      expect((await store().read())!['pending'], false);
    },
  );

  test(
    'stale remote reads cannot overwrite acknowledged local revisions',
    () async {
      final local = store();
      await local.stage(snapshot('Новый'));
      expect(await local.acknowledge(1), true);
      expect(await local.acceptRemote(snapshot('Старый'), 0), false);
      expect((await local.read())!['style']['bio'], 'Новый');
    },
  );

  test(
    'crop changes retain an already uploaded cover from a stale editor',
    () async {
      final local = store();
      await local.stage({
        ...snapshot('a'),
        'localPhoto': '/photo.jpg',
      }, newPhoto: '/photo.jpg');
      expect(await local.recordUpload('/photo.jpg', 'owner/cover.jpg'), true);
      await local.stage({...snapshot('b'), 'localPhoto': '/photo.jpg'});
      final saved = (await local.read())!;
      expect(saved['style']['cover_photo_path'], 'owner/cover.jpg');
      expect(saved['photoNeedsUpload'], false);
      expect(await local.acknowledge(1), false);
      expect(saved['pending'], true);
    },
  );

  test(
    'account switch prevents reading or acknowledging another queue',
    () async {
      String? current = owner;
      final local = ProfileAppearanceStore(owner, currentUser: () => current);
      await local.stage(snapshot('Приватно'));
      current = 'another';
      expect(await local.read(), isNull);
      expect(await local.acknowledge(1), false);
      current = owner;
      expect((await local.read())!['pending'], true);
    },
  );

  test('basic profile saves locally while cloud is blocked and sends latest revision', () async {
    final transport = BasicTransport()..blocked = Completer<void>();
    final repo = UserProfileRepository(
      syncService: transport,
      currentUser: () => owner,
    );
    await repo.load();
    await repo.updateProfile(username: 'Первый');
    await settleQueue();
    await repo.updateProfile(username: 'Последний');
    final restarted = UserProfileRepository(
      syncService: transport,
      currentUser: () => owner,
    );
    await restarted.load();
    expect(restarted.profile.username, 'Последний');
    expect(restarted.hasPendingSync, true);
    transport.blocked!.complete();
    expect(await repo.retryPendingSync(), true);
    expect(transport.sent, ['Первый', 'Последний']);
    await restarted.load();
    expect(restarted.hasPendingSync, false);
  });

  test(
    'a new offline avatar supersedes an earlier removal after restart',
    () async {
      final transport = BasicTransport()..offline = true;
      final repo = UserProfileRepository(
        syncService: transport,
        currentUser: () => owner,
      );
      await repo.load();
      await repo.setPhotoPath(null);
      await settleQueue();
      await repo.setPhotoPath('/documents/avatar.jpg');
      await settleQueue();
      final restored = UserProfileRepository(
        syncService: transport,
        currentUser: () => owner,
      );
      await restored.load();
      expect(restored.profile.photoPath, '/documents/avatar.jpg');
      expect(restored.hasPendingSync, true);
      transport.offline = false;
      expect(await restored.retryPendingSync(), true);
      expect(restored.profile.avatarUrl, 'https://example.invalid/avatar.jpg');
      expect(transport.clears.last, false);
    },
  );

  testWidgets(
    'reconnection triggers retries, pauses in background, resumes safely',
    (tester) async {
      final changes = StreamController<bool>.broadcast();
      final calls = <bool>[];
      final recovery = NetworkRecoverySync(
        onSync: calls.add,
        changes: changes.stream,
        retryInterval: const Duration(seconds: 5),
      );
      recovery.start();
      changes.add(false);
      await tester.pump(const Duration(seconds: 6));
      expect(calls, isEmpty);
      changes.add(true);
      await tester.pump();
      changes.add(true);
      await tester.pump();
      expect(calls, [true]);
      recovery.setForeground(false);
      await tester.pump(const Duration(seconds: 10));
      expect(calls, [true]);
      recovery.setForeground(true);
      await tester.pump(const Duration(seconds: 5));
      expect(calls, [true, true, false]);
      recovery.dispose();
      await changes.close();
    },
  );
}
