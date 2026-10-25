// Базовый smoke-тест приложения: без активной сессии оно стартует на экране
// входа (роутинг выполняет AuthGate).
//
// ВАЖНО про SharedPreferences: в тестовом окружении плагин не зарегистрирован,
// и без `setMockInitialValues` вызов `SharedPreferences.getInstance()` НЕ
// завершается никогда (ответ платформы не приходит). Тест при этом не падает
// с ошибкой, а висит до 10-минутного таймаута — именно это здесь и происходило.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pulsepath/main.dart';
import 'package:pulsepath/data/app_settings.dart';
import 'package:pulsepath/data/saved_routes_repository.dart';
import 'package:pulsepath/screens/login_screen.dart';

void main() {
  testWidgets('App launches on login screen', (WidgetTester tester) async {
    // Ставим мок ДО первого обращения к SharedPreferences.
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final settings = AppSettings();
    await settings.load();
    final repository = SavedRoutesRepository();
    await repository.load();

    await tester.pumpWidget(
      PulsePathApp(settings: settings, repository: repository),
    );

    // Supabase в тестах не инициализирован, сессии нет — значит показываем вход.
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Вход в аккаунт'), findsOneWidget);
  });
}
