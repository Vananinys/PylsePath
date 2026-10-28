import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pulsepath/data/saved_places_repository.dart';
import 'package:pulsepath/models/saved_place.dart';
import 'package:pulsepath/screens/saved_places_screen.dart';
import 'package:pulsepath/widgets/map_home_actions.dart';

SavedPlace point(String name, {String? id}) => SavedPlace(
  id: id,
  name: name,
  latitude: 55,
  longitude: 83,
  kind: SavedPlaceKind.home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? owner;
  SavedPlacesRepository repo() =>
      SavedPlacesRepository(owner: owner, currentUser: () => owner);
  setUp(() {
    owner = 'a';
    SharedPreferences.setMockInitialValues({});
    SavedPlacesRepository.resetQueuesForTesting();
  });

  test('points survive repository recreation, editing keeps identity, list is immutable', () async {
    final home = point('  Дом  ');
    await repo().save(home);
    expect((await repo().load()).single.name, 'Дом');
    await repo().save(
      SavedPlace(id: home.id, name: 'Новый дом', latitude: 56, longitude: 84),
    );
    final places = await repo().load();
    expect(places, hasLength(1));
    expect(places.single.id, home.id);
    expect(places.single.latitude, 56);
    expect(() => places.add(home), throwsUnsupportedError);
  });

  test(
    'accounts and guest remain separate; stale repository cannot read or write',
    () async {
      final accountA = repo();
      await accountA.save(point('Private A'));
      owner = 'b';
      expect(await repo().load(), isEmpty);
      await expectLater(accountA.load(), throwsStateError);
      await expectLater(accountA.save(point('wrong owner')), throwsStateError);
      await expectLater(accountA.remove('any'), throwsStateError);
      await repo().save(point('Private B'));
      owner = null;
      expect(await repo().load(), isEmpty);
      owner = 'a';
      expect((await repo().load()).single.name, 'Private A');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {'saved_places_v1_a', 'saved_places_v1_b'});
    },
  );

  test(
    'concurrent saves from different repositories do not overwrite each other',
    () async {
      await Future.wait(
        List.generate(25, (i) => repo().save(point('Place $i'))),
      );
      expect(await repo().load(), hasLength(25));
    },
  );

  test(
    'corrupt or unsupported data never becomes an empty or rewritten list',
    () async {
      final prefs = await SharedPreferences.getInstance();
      for (final original in [
        '{broken',
        '{"version":2,"places":[]}',
        jsonEncode({
          'version': 1,
          'places': [
            point('good').toJson(),
            {'name': 'broken'},
          ],
        }),
      ]) {
        await prefs.setString('saved_places_v1_a', original);
        await expectLater(repo().load(), throwsA(anything));
        await expectLater(repo().save(point('new')), throwsA(anything));
        await expectLater(repo().remove('old'), throwsA(anything));
        expect(prefs.getString('saved_places_v1_a'), original);
      }
    },
  );

  test('invalid coordinates, empty names and oversized names are rejected', () {
    for (final lat in [double.nan, double.infinity, 91.0, -91.0]) {
      expect(
        () => SavedPlace(name: 'test', latitude: lat, longitude: 83),
        throwsFormatException,
      );
    }
    expect(
      () => SavedPlace(name: 'test', latitude: 55, longitude: 181),
      throwsFormatException,
    );
    expect(() => point('   '), throwsFormatException);
    expect(() => point('x' * 81), throwsFormatException);
    expect(SavedPlace(name: 'Zero', latitude: 0, longitude: 0).latitude, 0);
  });

  test(
    'capacity rejects additions but allows edits and a confirmed removal',
    () async {
      final places = List.generate(
        SavedPlacesRepository.maxPlaces,
        (i) => point('Place $i', id: 'p$i'),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'saved_places_v1_a',
        jsonEncode({
          'version': 1,
          'places': places.map((p) => p.toJson()).toList(),
        }),
      );
      await expectLater(repo().save(point('too many')), throwsStateError);
      await repo().save(point('edited', id: 'p0'));
      expect((await repo().load()).first.name, 'edited');
      await repo().remove('p0');
      await repo().save(point('replacement'));
      expect(await repo().load(), hasLength(SavedPlacesRepository.maxPlaces));
    },
  );

  testWidgets(
    'save GPS position, reopen, edit and select a route destination',
    (tester) async {
      SavedPlace? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Открыть места'),
                onPressed: () async {
                  selected = await Navigator.push<SavedPlace>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SavedPlacesScreen(
                        repository: repo(),
                        locate: () async => const LatLng(55, 83),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть места'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Сохранить мою позицию'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Место у парка');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      final id = (await repo().load()).single.id;
      expect(find.text('Место у парка'), findsOneWidget);
      await tester.tap(find.byTooltip('Действия с местом'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Изменить'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Любимый старт');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect((await repo().load()).single.id, id);
      await tester.tap(find.text('Любимый старт'));
      await tester.pumpAndSettle();
      expect(selected?.latitude, 55);
      expect(selected?.longitude, 83);
      expect(selected?.name, 'Любимый старт');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('delete requires confirmation; cancel preserves the place', (
    tester,
  ) async {
    await repo().save(point('Дом'));
    await tester.pumpWidget(
      MaterialApp(home: SavedPlacesScreen(repository: repo())),
    );
    await tester.pumpAndSettle();
    for (final confirm in [false, true]) {
      await tester.tap(find.byTooltip('Действия с местом'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить место'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(confirm ? 'Удалить' : 'Отмена'));
      await tester.pumpAndSettle();
      expect(await repo().load(), hasLength(confirm ? 0 : 1));
    }
  });

  testWidgets('long emoji names are validated before creating the record', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SavedPlacesScreen(
          repository: repo(),
          locate: () async => const LatLng(55, 83),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Сохранить мою позицию'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '🚲' * 41);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Название слишком длинное'), findsOneWidget);
    expect(await repo().load(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable GPS does not save a default location', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SavedPlacesScreen(
          repository: repo(),
          locate: () async => throw StateError('GPS unavailable'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Сохранить мою позицию'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);
    expect(await repo().load(), isEmpty);
    expect(find.textContaining('Проверьте GPS'), findsOneWidget);
  });

  testWidgets('long place names fit a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await repo().save(
      point('Очень длинное название любимого места у речного парка'),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: SavedPlacesScreen(
          repository: repo(),
          locate: () async => const LatLng(55, 83),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Очень длинное'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('route planner provides a dedicated personal places entry', (
    tester,
  ) async {
    RouteEntryAction? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showRouteEntrySheet(context);
              },
              child: const Text('План'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('План'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Мои места'));
    await tester.pumpAndSettle();
    expect(selected, RouteEntryAction.myPlaces);
  });
}
