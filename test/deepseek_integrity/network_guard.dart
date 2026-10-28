import 'dart:io';

/// Fails the test if production code unexpectedly opens an HTTP connection.
///
/// The scenarios in this directory are local-only. They use fake owners, fake
/// rides and in-memory preferences; no request to a real service is permitted.
class NetworkGuard {
  const NetworkGuard._();

  static HttpOverrides? _previous;

  static void install() {
    _previous = HttpOverrides.current;
    HttpOverrides.global = _RejectingHttpOverrides();
  }

  static void restore() {
    HttpOverrides.global = _previous;
  }
}

class _RejectingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    throw StateError(
      'Unexpected network request during a deepseek_integrity test. '
      'All data in these tests must be local and fictional.',
    );
  }
}
