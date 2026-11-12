/// Android application identity is selected by the matching Gradle property.
/// UI beta has its own catalog; regular installations never read it.
abstract final class AppVariant {
  static const uiBeta = bool.fromEnvironment('UI_BETA');
  static const e2eeTestChat = uiBeta && bool.fromEnvironment('E2EE_TEST_CHAT');
  static const signalTest = uiBeta && bool.fromEnvironment('E2EE_SIGNAL_TEST');
  static const e2eeMessaging = uiBeta && bool.fromEnvironment('E2EE_MESSAGING');

  /// Promoted in stable 1.13.0. This selects features, never app identity.
  /// Future experiments need their own flag and are promoted individually.
  static const modernInterface = true;
  static const routeDrawing = bool.fromEnvironment(
    'ROUTE_DRAWING_ENABLED',
    defaultValue: true,
  );
  static const name = uiBeta ? 'PulsePath UI Beta' : 'PulsePath';
  static const updateTopic = uiBeta
      ? 'pulsepath_ui_beta_updates'
      : 'pulsepath_android_updates';
  static const uiBetaCatalog = 'app_ui_beta_releases';
}
