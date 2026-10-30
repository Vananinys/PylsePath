/// Android application identity is selected by the matching Gradle property.
/// UI beta has its own catalog; regular installations never read it.
abstract final class AppVariant {
  static const uiBeta = bool.fromEnvironment('UI_BETA');
  static const name = uiBeta ? 'PulsePath UI Beta' : 'PulsePath';
  static const updateTopic = uiBeta
      ? 'pulsepath_ui_beta_updates'
      : 'pulsepath_android_updates';
  static const uiBetaCatalog = 'app_ui_beta_releases';
}
