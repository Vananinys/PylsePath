import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:pulsepath/data/app_settings.dart';
import 'package:pulsepath/data/privacy_consent_store.dart';
import 'package:pulsepath/models/privacy_consent.dart';
import 'package:pulsepath/models/user_profile.dart';
import 'package:pulsepath/screens/privacy_screen.dart';
import 'package:pulsepath/screens/register_screen.dart';
import 'package:pulsepath/screens/settings_screen.dart';
import 'package:pulsepath/services/auth_service.dart';

const _user = User(
  id: 'privacy-test-account',
  appMetadata: {},
  userMetadata: {},
  aud: 'authenticated',
  createdAt: '2026-10-25T00:00:00Z',
);

class _Auth extends AuthService {
  int requests = 0;
  bool confirmationRequired = false;

  @override
  Future<User> signUp({required String email, required String password}) async {
    requests++;
    if (confirmationRequired) {
      throw AuthServiceException(
        'Подтвердите e-mail',
        isEmailNotConfirmed: true,
        createdUserId: _user.id,
      );
    }
    return _user;
  }
}

class _FailingStore extends PrivacyConsentStore {
  @override
  Future<void> savePending(PrivacyConsentReceipt receipt) async =>
      throw StateError('disk full');
}

Future<void> _chooseAge(WidgetTester tester, RegistrationAgeGroup group) async {
  await _tapVisible(tester, find.byKey(const ValueKey('registration-age')));
  await tester.tap(find.text(group.label).last);
  await tester.pumpAndSettle();
}

Future<void> _credentials(WidgetTester tester) async {
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), 'test@example.com');
  await tester.enterText(fields.at(1), 'testing123');
  await tester.enterText(fields.at(2), 'testing123');
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 30,
  );
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('receipt is account scoped, preserves text versions and rejects malformed consent', () async {
    final store = PrivacyConsentStore();
    final receipt = PrivacyConsentReceipt(
      ageGroup: RegistrationAgeGroup.adult,
      acceptedAt: DateTime.utc(2026, 10, 25),
      source: 'registration',
    );
    await store.savePending(receipt);
    await store.saveForAccount('account-a', receipt);
    final read = await PrivacyConsentStore().readForAccount('account-a');
    expect(read!.isCurrent, isTrue);
    expect(read.acceptedAt, receipt.acceptedAt);
    expect(await store.readForAccount('account-b'), isNull);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(
      prefs.getString(PrivacyConsentStore.accountKey('account-a'))!,
    ) as Map;
    expect(saved.keys, isNot(contains('email')));
    expect(saved.keys, isNot(contains('analytics_enabled')));
    expect(
      () => PrivacyConsentReceipt.fromJson({
        ...receipt.toJson(),
        'age_group': RegistrationAgeGroup.under14.id,
      }),
      throwsFormatException,
    );
    expect(
      () => PrivacyConsentReceipt.fromJson({
        ...receipt.toJson(),
        'processing_consent': false,
      }),
      throwsFormatException,
    );
    await expectLater(
      store.saveForAccount(
        'under14',
        PrivacyConsentReceipt(
          ageGroup: RegistrationAgeGroup.under14,
          acceptedAt: DateTime.now(),
          source: 'registration',
        ),
      ),
      throwsStateError,
    );
  });

  test('version 54 receipts remain readable without gaining new consent', () {
    final old = PrivacyConsentReceipt.fromJson({
      'age_group': '18_plus',
      'accepted_at': '2026-10-25T00:00:00Z',
      'policy_version': '2026-10-25.1',
      'terms_version': '2026-10-25.1',
      'source': 'registration',
      'processing_consent': true,
      'terms_accepted': true,
    });
    expect(old.termsAcceptance, 'separate_checkbox');
    expect(old.isCurrent, isFalse);
    expect(old.policyVersion, '2026-10-25.1');
  });

  test(
    'new defaults are private and explicit existing choices survive load',
    () async {
      final settings = AppSettings();
      await settings.load();
      expect(settings.shareLivePosition, isFalse);
      final profile = UserProfile(weightKg: 70, heightCm: 175, age: 30);
      expect(profile.showWeight, isFalse);
      expect(profile.showAge, isFalse);
      expect(profile.showGender, isFalse);
      final existing = UserProfile.fromJson({
        ...profile.toJson(),
        'showWeight': true,
        'showAge': true,
        'showGender': true,
      });
      expect(
        existing.showWeight && existing.showAge && existing.showGender,
        isTrue,
      );
      await settings.setShareLivePosition(true);
      final reloaded = AppSettings();
      await reloaded.load();
      expect(reloaded.shareLivePosition, isTrue);
    },
  );

  testWidgets(
    'registration has no preselected age and under 14 cannot send a signup request',
    (tester) async {
      final auth = _Auth();
      await tester.pumpWidget(
        MaterialApp(home: RegisterScreen(authService: auth)),
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Зарегистрироваться'), findsNothing);
      await _chooseAge(tester, RegistrationAgeGroup.under14);
      expect(
        find.textContaining('PulsePath доступен с 14 лет'),
        findsOneWidget,
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(auth.requests, 0);
      expect(
        (await SharedPreferences.getInstance()).getString(
          PrivacyConsentStore.pendingKey,
        ),
        isNull,
      );
    },
  );

  testWidgets(
    'one explicit processing consent permits signup and receipt survives email confirmation',
    (tester) async {
      final auth = _Auth()..confirmationRequired = true;
      await tester.pumpWidget(
        MaterialApp(home: RegisterScreen(authService: auth)),
      );
      await _chooseAge(tester, RegistrationAgeGroup.adult);
      for (final tile in tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      )) {
        expect(tile.value, isFalse);
      }
      await _credentials(tester);
      await _tapVisible(tester, find.text('Зарегистрироваться'));
      expect(auth.requests, 0);
      expect(
        find.text('Подтвердите согласие на обработку данных.'),
        findsOneWidget,
      );
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('processing-consent')),
      );
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.byKey(const ValueKey('test-terms')), findsNothing);
      await _tapVisible(tester, find.text('Зарегистрироваться'));
      expect(auth.requests, 1);
      expect(
        (await PrivacyConsentStore().readForAccount(_user.id))!.isCurrent,
        isTrue,
      );
      expect(
        (await PrivacyConsentStore().readForAccount(_user.id))!.termsAcceptance,
        'submit_button',
      );
    },
  );

  testWidgets('failed local persistence prevents the auth request', (
    tester,
  ) async {
    final auth = _Auth();
    await tester.pumpWidget(
      MaterialApp(
        home: RegisterScreen(authService: auth, consentStore: _FailingStore()),
      ),
    );
    await _chooseAge(tester, RegistrationAgeGroup.adult);
    await _credentials(tester);
    await _tapVisible(tester, find.byKey(const ValueKey('processing-consent')));
    await _tapVisible(tester, find.text('Зарегистрироваться'));
    expect(auth.requests, 0);
    expect(find.textContaining('Регистрация не началась'), findsOneWidget);
  });

  testWidgets('age changes clear previous adult confirmations', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: RegisterScreen(authService: _Auth())),
    );
    await _chooseAge(tester, RegistrationAgeGroup.adult);
    await _tapVisible(tester, find.byKey(const ValueKey('processing-consent')));
    await tester.ensureVisible(find.byKey(const ValueKey('registration-age')));
    await _chooseAge(tester, RegistrationAgeGroup.teen);
    await _chooseAge(tester, RegistrationAgeGroup.adult);
    for (final tile in tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    )) {
      expect(tile.value, isFalse);
    }
  });

  testWidgets(
    '14 to 17 registration fits a narrow phone with one consent and large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final auth = _Auth();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: RegisterScreen(authService: auth),
        ),
      );
      await _chooseAge(tester, RegistrationAgeGroup.teen);
      await _credentials(tester);
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('processing-consent')),
      );
      await _tapVisible(tester, find.text('Зарегистрироваться'));
      expect(auth.requests, 1);
      expect(
        (await PrivacyConsentStore().readForAccount(_user.id))!.source,
        'registration',
      );
      expect(
        (await PrivacyConsentStore().readForAccount(_user.id))!.ageGroup,
        RegistrationAgeGroup.teen,
      );
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'privacy documents are readable offline on a narrow screen with large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const PrivacyScreen(),
        ),
      );
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Информация о данных'));
      expect(find.byType(SelectableText), findsOneWidget);
      expect(
        find.textContaining(PrivacyDocuments.contactEmail),
        findsOneWidget,
      );
      expect(find.textContaining('Ирландии'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'privacy center is reachable from grouped settings without accepting on behalf of old accounts',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Приватность'));
      await _tapVisible(tester, find.text('Данные и согласия'));
      expect(find.text('Статистика и отчёты об ошибках'), findsOneWidget);
      expect(find.textContaining('нет подтверждения'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          PrivacyConsentStore.pendingKey,
        ),
        isNull,
      );
    },
  );
}
