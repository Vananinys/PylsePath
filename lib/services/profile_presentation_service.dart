import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../models/profile_cover_crop.dart';
import 'achievements_service.dart';
import 'achievement_journey.dart';
import '../models/owner_award.dart';
import '../data/account_progress_cache.dart';
import '../data/profile_appearance_store.dart';
import '../data/user_scope.dart';
import 'profile_sync_service.dart';

class ProfileReward {
  ProfileReward(Map<String, dynamic> row)
    : id = row['id'] as String,
      key = row['award_key'] as String,
      kind = row['kind'] as String,
      label = row['label'] as String,
      icon = row['icon'] as String,
      equipped = row['equipped'] == true,
      earned = row['source'] == 'earned',
      grantedAt = row['granted_at'] as String?;
  final String id, key, kind, label, icon;
  final bool equipped, earned;
  final String? grantedAt;
  Map<String, dynamic> toJson() => {
    'id': id,
    'award_key': key,
    'kind': kind,
    'label': label,
    'icon': icon,
    'equipped': equipped,
    'source': earned ? 'earned' : 'owner',
    'granted_at': grantedAt,
  };
}

class ProfilePresentation {
  const ProfilePresentation({
    this.accent = 'ember',
    this.cover = 'contour',
    this.frame = 'ring',
    this.bio = '',
    this.showAwards = true,
    this.featured = const [],
    this.rewards = const [],
    this.rankTitle,
    this.coverPhotoPath,
    this.coverPhotoUrl,
    this.coverCrop = const ProfileCoverCrop(),
    this.localCoverPhotoPath,
    this.isPending = false,
    this.hasTitleSelection = false,
  });
  static const colors = <String, Color>{
    'ember': Color(0xFFE85D28),
    'ocean': Color(0xFF167EAA),
    'forest': Color(0xFF238064),
    'violet': Color(0xFF7954B8),
    'rose': Color(0xFFC94F7C),
    'slate': Color(0xFF465A70),
  };
  static const colorNames = [
    'Закат',
    'Океан',
    'Лес',
    'Сирень',
    'Роза',
    'Графит',
  ];
  static const covers = <String, String>{
    'contour': 'Рельеф',
    'summit': 'Вершины',
    'road': 'Дорога',
    'waves': 'Волны',
    'dots': 'Ритм',
    'plain': 'Градиент',
  };
  final String accent, cover, frame, bio;
  final bool showAwards;
  final List<String> featured;
  final List<ProfileReward> rewards;

  /// Explicitly selected earned journey rank, stored as `rank:<xp>`.
  final String? rankTitle;
  final String? coverPhotoPath, coverPhotoUrl;
  final ProfileCoverCrop coverCrop;
  final String? localCoverPhotoPath;
  final bool isPending;
  final bool hasTitleSelection;
  JourneyRank? get selectedRank => JourneyRank.all
      .where((rank) => 'rank:${rank.xp}' == rankTitle)
      .firstOrNull;
  ProfilePresentation withCoverPhotoPath(String? path) => ProfilePresentation(
    accent: accent,
    cover: cover,
    frame: frame,
    bio: bio,
    showAwards: showAwards,
    featured: featured,
    rewards: rewards,
    rankTitle: rankTitle,
    coverPhotoPath: path,
    coverPhotoUrl: path == coverPhotoPath ? coverPhotoUrl : null,
    coverCrop: coverCrop,
    localCoverPhotoPath: localCoverPhotoPath,
    isPending: isPending,
    hasTitleSelection: hasTitleSelection,
  );
  Color get color => colors[accent] ?? colors['ember']!;
  ProfileReward? get title =>
      rewards.where((r) => r.kind == 'title' && r.equipped).firstOrNull;
  List<ProfileReward> get showcase => !showAwards
      ? []
      : [
          for (final id in featured)
            ...rewards.where((r) => r.id == id && r.kind == 'achievement'),
        ];
}

abstract class ProfilePresentationTransport {
  Future<Map<String, dynamic>> fetch(
    String userId, {
    bool refreshEarned = false,
  });
  Future<String> uploadCover(String path);
  Future<void> save(Map<String, dynamic> style, String? titleId);
}

class SupabaseProfilePresentationTransport
    implements ProfilePresentationTransport {
  SupabaseClient get _client => Supabase.instance.client;
  @override
  Future<Map<String, dynamic>> fetch(
    String userId, {
    bool refreshEarned = false,
  }) async {
    if (refreshEarned && _client.auth.currentUser?.id == userId) {
      try {
        await _client
            .rpc('refresh_profile_achievements')
            .timeout(const Duration(seconds: 6));
      } catch (_) {}
    }
    final results = await Future.wait<dynamic>([
      _client
          .from('profile_styles')
          .select()
          .eq('user_id', userId)
          .maybeSingle(),
      _client
          .from('profile_rewards')
          .select()
          .eq('user_id', userId)
          .order('granted_at', ascending: false),
    ]).timeout(const Duration(seconds: 8));
    return {'style': results[0] ?? <String, dynamic>{}, 'rewards': results[1]};
  }

  @override
  Future<String> uploadCover(String path) =>
      ProfileSyncService().uploadProfileCover(path);
  @override
  Future<void> save(Map<String, dynamic> style, String? titleId) async {
    final rank = titleId?.startsWith('rank:') == true ? titleId : null;
    await _client.rpc(
      'save_profile_style_v4',
      params: {
        'p_accent': style['accent'],
        'p_cover': style['cover'],
        'p_frame': style['frame'],
        'p_bio': style['bio'],
        'p_show_awards': style['show_awards'],
        'p_featured': style['featured_awards'],
        'p_title': rank == null ? titleId : null,
        'p_rank_title': rank,
        'p_cover_photo_path': style['cover_photo_path'],
        'p_cover_crop': style['cover_crop'],
      },
    );
  }
}

class ProfilePresentationService {
  ProfilePresentationService({
    ProfilePresentationTransport? transport,
    ProfileAppearanceStore? store,
    String? Function()? currentUser,
  }) : _transport = transport ?? SupabaseProfilePresentationTransport(),
       _testStore = store,
       _currentUser = currentUser ?? UserScope.currentUserId;
  final ProfilePresentationTransport _transport;
  final ProfileAppearanceStore? _testStore;
  final String? Function() _currentUser;
  static final _stores = <String, ProfileAppearanceStore>{};
  static final _memory = <String, ValueNotifier<ProfilePresentation?>>{};
  static final _syncs = <String, Future<bool>>{};
  ProfileAppearanceStore _store(String owner) =>
      _testStore ??
      _stores.putIfAbsent(owner, () => ProfileAppearanceStore(owner));
  static ProfilePresentation? peek(String owner) => _memory[owner]?.value;
  static ValueListenable<ProfilePresentation?> watch(String owner) =>
      _memory.putIfAbsent(owner, () => ValueNotifier(null));
  void _publish(String owner, Map<String, dynamic> envelope) {
    if (_currentUser() == owner)
      _memory.putIfAbsent(owner, () => ValueNotifier(null)).value = _decode(
        envelope,
      );
  }

  @visibleForTesting
  static void resetCachesForTesting() {
    _stores.clear();
    _memory.clear();
    _syncs.clear();
  }

  ProfilePresentation _decode(Map<String, dynamic> envelope) {
    final row = Map<String, dynamic>.from(envelope['style'] as Map? ?? {});
    final path = row['cover_photo_path'] as String?;
    String? url;
    if (path != null) {
      try {
        url = Supabase.instance.client.storage
            .from(AppConfig.avatarsBucket)
            .getPublicUrl(path);
      } catch (_) {}
    }
    return ProfilePresentation(
      accent: row['accent'] as String? ?? 'ember',
      cover: row['cover'] as String? ?? 'contour',
      frame: row['frame'] as String? ?? 'ring',
      bio: row['bio'] as String? ?? '',
      showAwards: row['show_awards'] != false,
      featured: List<String>.from(row['featured_awards'] as List? ?? []),
      rewards: (envelope['rewards'] as List? ?? [])
          .map((r) => ProfileReward(Map<String, dynamic>.from(r as Map)))
          .toList(),
      rankTitle: row['rank_title'] as String?,
      coverPhotoPath: path,
      coverPhotoUrl: url,
      coverCrop: ProfileCoverCrop.fromJson(row['cover_crop']),
      localCoverPhotoPath: envelope['localPhoto'] as String?,
      isPending: envelope['pending'] == true,
      hasTitleSelection: true,
    );
  }

  Future<ProfilePresentation?> loadCached(String userId) async {
    if (_currentUser() != userId) return null;
    final memory = peek(userId);
    if (memory != null) return memory;
    final saved = await _store(userId).read();
    if (saved == null || _currentUser() != userId) return null;
    _publish(userId, saved);
    return peek(userId);
  }

  Future<ProfilePresentation> load(
    String userId, {
    bool refreshEarned = false,
  }) async {
    final viewer = _currentUser();
    final own = viewer == userId;
    final store = own ? _store(userId) : null;
    final cached = own ? await loadCached(userId) : null;
    final before = await store?.read();
    if (before?['pending'] == true) {
      unawaited(syncPending(userId));
      return cached ?? _decode(before!);
    }
    final publicCache = AccountProgressCache(
      'public_presentation_$userId',
      viewer,
    );
    try {
      final remote = await _transport.fetch(
        userId,
        refreshEarned: refreshEarned,
      );
      if (_currentUser() != viewer) throw StateError('Account changed');
      if (store != null) {
        await store.acceptRemote(remote, before?['revision'] as int? ?? 0);
        final latest = await store.read();
        if (latest != null) _publish(userId, latest);
        final rewards = peek(userId)?.rewards ?? [];
        AchievementsService.setEarnedCatalog(
          userId,
          rewards.where((r) => r.earned).map((r) => r.key),
          receipts: (remote['rewards'] as List? ?? [])
              .where((r) => r['source'] == 'earned')
              .map((r) => OwnerAward.fromJson(Map<String, dynamic>.from(r)))
              .toList(),
        );
        return peek(userId) ?? _decode(remote);
      }
      await publicCache.write(remote);
      return _decode(remote);
    } catch (_) {
      if (_currentUser() != viewer) rethrow;
      if (own && peek(userId) != null) return peek(userId)!;
      final saved = await publicCache.read();
      if (saved is Map) return _decode(Map<String, dynamic>.from(saved));
      rethrow;
    }
  }

  /// A successful local write is the save. Network work never delays the editor.
  Future<void> save(
    ProfilePresentation style,
    String? titleId, {
    String? newCoverPhoto,
  }) async {
    final owner = _currentUser();
    if (owner == null) throw StateError('Войдите в аккаунт');
    final rows = style.rewards
        .map(
          (r) => {
            ...r.toJson(),
            if (r.kind == 'title') 'equipped': r.id == titleId,
          },
        )
        .toList();
    final snapshot = {
      'style': {
        'accent': style.accent,
        'cover': style.cover,
        'frame': style.frame,
        'bio': style.bio,
        'show_awards': style.showAwards,
        'featured_awards': style.featured,
        'rank_title': titleId?.startsWith('rank:') == true ? titleId : null,
        'cover_photo_path': style.coverPhotoPath,
        'cover_crop': style.coverCrop.toJson(),
      },
      'rewards': rows,
      'titleId': titleId,
      'localPhoto': newCoverPhoto ?? style.localCoverPhotoPath,
    };
    final saved = await _store(owner).stage(snapshot, newPhoto: newCoverPhoto);
    if (_currentUser() != owner) throw StateError('Account changed');
    _publish(owner, saved);
    unawaited(syncPending(owner));
  }

  Future<bool> syncPending([String? userId]) {
    final owner = userId ?? _currentUser();
    if (owner == null || owner != _currentUser()) return Future.value(false);
    return _syncs[owner] ??= _flush(owner).whenComplete(() {
      _syncs.remove(owner);
    });
  }

  Future<bool> _flush(String owner) async {
    final store = _store(owner);
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (_currentUser() != owner) return false;
        var saved = await store.read();
        if (saved == null || saved['pending'] != true) return true;
        if (saved['photoNeedsUpload'] == true) {
          final local = saved['localPhoto'] as String;
          final uploaded = await _transport.uploadCover(local);
          if (_currentUser() != owner) return false;
          if (!await store.recordUpload(local, uploaded)) continue;
          saved = await store.read();
        }
        if (saved == null || _currentUser() != owner) return false;
        final revision = saved['revision'] as int;
        await _transport.save(
          Map<String, dynamic>.from(saved['style'] as Map),
          saved['titleId'] as String?,
        );
        if (_currentUser() != owner) return false;
        final ack = await store.acknowledge(revision);
        final latest = await store.read();
        if (latest != null) _publish(owner, latest);
        if (ack) return true;
      }
    } catch (error) {
      debugPrint('[Appearance] saved locally; sync deferred: $error');
    }
    return false;
  }
}
