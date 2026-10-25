// Проверка, что deep link для подтверждения e-mail объявлен одинаково
// в коде и в платформенных конфигах. Рассинхрон здесь — классическая причина
// «ссылка из письма открывает браузер/localhost вместо приложения».
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:pulsepath/config.dart';

void main() {
  test('redirect URL собран из схемы и хоста', () {
    expect(AppConfig.authScheme, 'pulsepath');
    expect(AppConfig.authCallbackHost, 'login-callback');
    expect(AppConfig.authRedirectUrl, 'pulsepath://login-callback');
  });

  test('AndroidManifest объявляет нашу схему и хост', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(
      manifest.contains('android:scheme="${AppConfig.authScheme}"'),
      isTrue,
      reason: 'в манифесте нет android:scheme="${AppConfig.authScheme}"',
    );
    expect(
      manifest.contains('android:host="${AppConfig.authCallbackHost}"'),
      isTrue,
      reason: 'в манифесте нет android:host="${AppConfig.authCallbackHost}"',
    );
    // Важно: VIEW + BROWSABLE, иначе система не отдаст ссылку приложению.
    expect(manifest.contains('android.intent.action.VIEW'), isTrue);
    expect(manifest.contains('android.intent.category.BROWSABLE'), isTrue);
    // singleTop — чтобы ссылка попадала в уже запущенное приложение.
    expect(manifest.contains('android:launchMode="singleTop"'), isTrue);
  });

  test('Info.plist объявляет CFBundleURLTypes с нашей схемой', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(plist.contains('CFBundleURLTypes'), isTrue);
    expect(plist.contains('CFBundleURLSchemes'), isTrue);
    expect(
      plist.contains('<string>${AppConfig.authScheme}</string>'),
      isTrue,
      reason: 'в Info.plist нет схемы ${AppConfig.authScheme}',
    );
  });
}
