import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:pulsepath/widgets/chat_video_player.dart';

class FakeVideoPlatform extends VideoPlayerPlatform {
  int created = 0;
  int disposed = 0;
  int plays = 0;
  int pauses = 0;
  int seeks = 0;
  final seekPositions = <Duration>[];
  final volumes = <double>[];
  final speeds = <double>[];
  final sources = <DataSource>[];
  final events = <int, StreamController<VideoEvent>>{};
  bool fail = false;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options.dataSource);
    if (fail) throw StateError('test unsupported video');
    final id = ++created;
    events[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 10),
          size: const Size(640, 360),
        ),
      );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    disposed++;
    await events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    plays++;
  }

  @override
  Future<void> pause(int playerId) async {
    pauses++;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seeks++;
    seekPositions.add(position);
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {
    speeds.add(speed);
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}

void main() {
  late VideoPlayerPlatform original;
  late FakeVideoPlatform fake;
  setUp(() {
    original = VideoPlayerPlatform.instance;
    fake = FakeVideoPlatform();
    VideoPlayerPlatform.instance = fake;
  });
  tearDown(() {
    VideoPlayerPlatform.instance = original;
  });
  testWidgets(
    'Video is paused initially, plays on tap, pauses in background and disposes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ChatVideoPlayer(source: 'https://example.invalid/private.mp4'),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.plays, 0);
      await tester.tap(find.byTooltip('Воспроизвести'));
      await tester.pump();
      expect(fake.plays, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(fake.pauses, greaterThan(0));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(fake.disposed, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    },
  );
  testWidgets('Expired reference refreshes and retry uses a new URL', (
    tester,
  ) async {
    var refreshes = 0;
    fake.fail = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatVideoPlayer(
          source: 'chat:owner/video.mp4',
          onRefresh: () async =>
              'https://example.invalid/video-${++refreshes}.mp4',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Повторить'), findsOneWidget);
    fake.fail = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(refreshes, 2);
    expect(fake.sources.last.uri, 'https://example.invalid/video-2.mp4');
    expect(find.byTooltip('Воспроизвести'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
