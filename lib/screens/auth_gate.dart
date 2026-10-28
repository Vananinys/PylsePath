import '../services/recording_daily_activity_service.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';
import '../services/achievements_service.dart';
import '../services/chat_service.dart';
import '../services/notification_service.dart';
import '../services/push_service.dart';
import '../state/profile_provider.dart';
import 'login_screen.dart';
import 'onboarding_screen.dart';
import 'reset_password_screen.dart';
import '../services/group_ride_service.dart';
import '../services/background_location_service.dart';

/// Стартовый роутинг: есть сессия — показываем [authedChild], нет — вход.
///
/// Подписан на `onAuthStateChange`, поэтому вход и выход переключают экраны
/// без ручных `Navigator.push` (см. AuthService.signOut).
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.authedChild, this.authService});

  /// Экран для авторизованного пользователя (карта).
  final Widget authedChild;

  /// Позволяет подставить сервис в тестах.
  final AuthService? authService;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _authSubscription;
  late bool _signedIn;
  String? _userId;
  bool _recovering = false;
  var _navigatorKey = GlobalKey<NavigatorState>();

  AuthService get _auth => widget.authService ?? AuthService();

  @override
  void initState() {
    super.initState();
    // isSignedIn == false и когда сессии нет, и когда Supabase недоступен
    // (например, в тестах) — в обоих случаях показываем экран входа.
    _signedIn = _auth.isSignedIn;
    _userId = _auth.userId;
    unawaited(
      DailyActivityService.instance
          .bindToUser(_userId)
          .catchError((Object _) {}),
    );
    unawaited(BackgroundLocationService.instance.bindToUser(_userId));
    AchievementsService.bindToUser(_userId);
    GroupRideService().bindToUser(_userId);
    debugPrint('[AuthGate] старт: есть сессия = $_signedIn');
    _authSubscription = _auth.authStateChanges?.listen((state) {
      final signedIn = state.session != null;
      // Сюда приходит и результат перехода по ссылке из письма:
      // SDK сам обменял ?code=... на сессию (detectSessionInUri).
      debugPrint(
        '[AuthGate] auth event=${state.event}, сессия=${signedIn ? 'есть' : 'нет'}',
      );
      final uid = state.session?.user.id;
      if (uid != _userId) {
        unawaited(
          DailyActivityService.instance
              .bindToUser(uid)
              .catchError((Object _) {}),
        );
        unawaited(BackgroundLocationService.instance.bindToUser(uid));
      }
      final recovering =
          signedIn &&
          (state.event == AuthChangeEvent.passwordRecovery ||
              (_recovering && uid == _userId));
      if (mounted &&
          (signedIn != _signedIn ||
              uid != _userId ||
              recovering != _recovering)) {
        PushService.instance.detach();
        ChatService().resetSession();
        AchievementsService.bindToUser(uid);
        GroupRideService().bindToUser(uid);
        NotificationService.instance.bindToUser(uid);
        setState(() {
          _signedIn = signedIn;
          _userId = uid;
          _recovering = recovering;
          _navigatorKey = GlobalKey<NavigatorState>();
        });
      }
    });
  }

  @override
  void dispose() {
    // Очистка всех ресурсов перед выходом из приложения
    _authSubscription?.cancel();
    PushService.instance.detach();
    NotificationService.instance.bindToUser(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = _recovering
        ? ResetPasswordScreen(
            authService: _auth,
            onSaved: () {
              setState(() {
                _recovering = false;
                _navigatorKey = GlobalKey<NavigatorState>();
              });
            },
          )
        : _signedIn
        ? ChangeNotifierProvider<ProfileProvider>(
            key: ValueKey('profile-$_userId'),
            create: (_) => ProfileProvider(),
            child: KeyedSubtree(
              key: ValueKey('map-$_userId'),
              // Новый аккаунт проходит онбординг с выбором пресета,
              // существующий попадает на карту сразу.
              child: OnboardingGate(child: widget.authedChild),
            ),
          )
        : LoginScreen(authService: widget.authService);
    // All pushed routes and dialogs are disposed when the session changes.
    return NavigatorPopHandler(
      onPopWithResult: (_) => _navigatorKey.currentState?.maybePop(),
      child: Navigator(
        key: _navigatorKey,
        onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => child),
      ),
    );
  }
}
