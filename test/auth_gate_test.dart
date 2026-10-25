import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pulsepath/screens/auth_gate.dart';
import 'package:pulsepath/screens/login_screen.dart';
import 'package:pulsepath/screens/reset_password_screen.dart';
import 'package:pulsepath/services/auth_service.dart';

class FakeAuth extends AuthService {
  final events = StreamController<AuthState>.broadcast();
  @override
  bool get isSignedIn => false;
  @override
  String? get userId => null;
  @override
  Stream<AuthState> get authStateChanges => events.stream;
}

void main() {
  testWidgets('Recovery replaces pushed routes; sign-out removes recovery', (
    tester,
  ) async {
    final auth = FakeAuth();
    await tester.pumpWidget(
      MaterialApp(
        home: AuthGate(
          authService: auth,
          authedChild: const Text('Private map'),
        ),
      ),
    );
    final context = tester.element(find.byType(LoginScreen));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Pushed screen')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pushed screen'), findsOneWidget);
    final session = Session(
      accessToken: 'test',
      tokenType: 'bearer',
      user: const User(
        id: 'user-1',
        appMetadata: {},
        userMetadata: {},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00Z',
      ),
    );
    auth.events.add(AuthState(AuthChangeEvent.passwordRecovery, session));
    await tester.pumpAndSettle();
    expect(find.byType(ResetPasswordScreen), findsOneWidget);
    expect(find.text('Pushed screen'), findsNothing);
    expect(find.text('Private map'), findsNothing);
    auth.events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    await tester.pumpAndSettle();
    expect(find.byType(ResetPasswordScreen), findsOneWidget);
    auth.events.add(const AuthState(AuthChangeEvent.signedOut, null));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(ResetPasswordScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await auth.events.close();
  });
}
