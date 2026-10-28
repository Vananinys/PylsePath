import 'package:image_picker/image_picker.dart' show XFile;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/ride_media_repository.dart';
import '../models/saved_route.dart';
import '../models/shared_route.dart';
import '../models/ride_media.dart';
import '../models/chat_media_draft.dart';
import '../utils/file_reader.dart';
import '../utils/ride_media_export.dart';
import 'video_preview_service.dart';

class RideMediaService {
  static Future<SharedRoute> prepareShare(
    SavedRoute route, {
    required Set<String> selectedIds,
    bool includeTrack = true,
    double hideRadiusMeters = 0,
    String kind = 'ride',
  }) async {
    final client = Supabase.instance.client;
    final owner = client.auth.currentUser?.id;
    if (owner == null) throw StateError('Войдите в аккаунт');
    void check() {
      if (client.auth.currentUser?.id != owner) {
        throw StateError('Аккаунт изменился');
      }
    }

    final repo = RideMediaRepository(route.localId);
    final items = selectedIds.isEmpty ? <RideMedia>[] : await repo.load();
    check();
    final lookup = <String, RideMedia>{};
    final proposed = <SharedRideMedia>[];
    for (final item in items.where((m) => selectedIds.contains(m.id))) {
      lookup[item.id] = item;
      proposed.add(
        SharedRideMedia(
          id: item.id,
          pointIndex: item.pointIndex,
          kind: item.kind,
          reference:
              'ride:$owner/${item.id}${item.kind == RideMediaKind.video ? '.mp4' : '.png'}',
          caption: item.caption,
        ),
      );
    }
    final snapshot = SharedRoute.fromSavedRoute(
      route,
      kind: kind,
      includeTrack: includeTrack,
      hideRadiusMeters: hideRadiusMeters,
      media: proposed,
    );
    // Only the materials whose anchors survived the visibility filter are uploaded.
    var total = 0;
    final enriched = <SharedRideMedia>[];
    for (final media in snapshot.media) {
      check();
      final video = media.kind == RideMediaKind.video;
      final path = lookup[media.id]!.localPath;
      final originalSize = await XFile(path).length();
      check();
      if (originalSize <= 0 ||
          originalSize >
              (video ? ChatMediaDraft.videoLimit : ChatMediaDraft.photoLimit)) {
        throw StateError('Файл слишком большой или пуст');
      }
      final bytes = video
          ? await readBytesFromPath(await exportRideVideo(path))
          : await exportRidePhoto(await readBytesFromPath(path));
      check();
      if (bytes.isEmpty ||
          bytes.length >
              (video ? ChatMediaDraft.videoLimit : ChatMediaDraft.photoLimit)) {
        throw StateError('Размер файла изменился. Выберите материал заново.');
      }
      total += bytes.length;
      if (total > ChatMediaDraft.batchLimit) {
        throw StateError('Выберите материалы общим размером до 100 МБ');
      }
      final extension = media.reference.split('.').last;
      final mime = video
          ? (extension == 'mov'
                ? 'video/quicktime'
                : extension == 'webm'
                ? 'video/webm'
                : 'video/mp4')
          : extension == 'png'
          ? 'image/png'
          : extension == 'webp'
          ? 'image/webp'
          : 'image/jpeg';
      try {
        await client.storage
            .from('ride_media')
            .uploadBinary(
              media.reference.substring(5),
              bytes,
              fileOptions: FileOptions(contentType: mime, upsert: false),
            )
            .timeout(const Duration(minutes: 3));
      } on StorageException catch (error) {
        if (error.statusCode != '409') rethrow;
      }
      String? poster;
      if (video) {
        final preview = await VideoPreviewService.inspect(path);
        check();
        if (preview.poster != null) {
          final png = await exportRidePhoto(preview.poster!);
          check();
          final reference = 'ride:$owner/${media.id}-preview.png';
          try {
            await client.storage
                .from('ride_media')
                .uploadBinary(
                  reference.substring(5),
                  png,
                  fileOptions: const FileOptions(
                    contentType: 'image/png',
                    upsert: false,
                  ),
                )
                .timeout(const Duration(seconds: 30));
            poster = reference;
          } on StorageException catch (error) {
            if (error.statusCode == '409') {
              poster = reference;
            } else {
              rethrow;
            }
          }
        }
      }
      enriched.add(
        SharedRideMedia(
          id: media.id,
          pointIndex: media.pointIndex,
          kind: media.kind,
          reference: media.reference,
          caption: media.caption,
          posterReference: poster,
        ),
      );
    }
    check();
    return SharedRoute(
      title: snapshot.title,
      kind: snapshot.kind,
      distanceKm: snapshot.distanceKm,
      durationSeconds: snapshot.durationSeconds,
      points: snapshot.points,
      activity: snapshot.activity,
      segmentStarts: snapshot.segmentStarts,
      media: enriched,
    );
  }

  static Future<String> signedUrl(String reference) async {
    if (!reference.startsWith('ride:')) {
      throw const FormatException('Недопустимое вложение');
    }
    return Supabase.instance.client.storage
        .from('ride_media')
        .createSignedUrl(reference.substring(5), 900)
        .timeout(const Duration(seconds: 15));
  }
}
