import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

abstract final class AppMotion {
  static Duration brief(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 180);
  static Duration panel(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 280);
}

ThemeData pulsePathTheme({Brightness brightness = Brightness.light}) {
  final dark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFFE86532),
    brightness: brightness,
  );
  const radius = BorderRadius.all(Radius.circular(22));
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: dark
        ? const Color(0xFF141311)
        : const Color(0xFFFAF8F5),
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? const Color(0xFF141311) : const Color(0xFFFAF8F5),
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: 0,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.inverseSurface,
      contentTextStyle: TextStyle(color: colors.onInverseSurface),
    ),
    dividerTheme: DividerThemeData(color: colors.outlineVariant, space: 24),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: const RoundedRectangleBorder(borderRadius: radius),
      clipBehavior: Clip.antiAlias,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: MotionAwareTransitions(
          FadeForwardsPageTransitionsBuilder(),
        ),
        TargetPlatform.iOS: MotionAwareTransitions(
          CupertinoPageTransitionsBuilder(),
        ),
      },
    ),
  );
}

class MotionAwareTransitions extends PageTransitionsBuilder {
  const MotionAwareTransitions(this.delegate);
  final PageTransitionsBuilder delegate;
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => MediaQuery.disableAnimationsOf(context)
      ? child
      : delegate.buildTransitions(
          route,
          context,
          animation,
          secondaryAnimation,
          child,
        );
}

/// Starts at the real value. Rebuilds and filtering never replay from zero.
class AppProgressIndicator extends StatelessWidget {
  const AppProgressIndicator({
    super.key,
    required this.value,
    this.color,
    this.backgroundColor,
    this.minHeight = 5,
  });
  final double value, minHeight;
  final Color? color, backgroundColor;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: value, end: value),
    duration: AppMotion.panel(context),
    curve: Curves.easeOutCubic,
    builder: (_, v, _) => LinearProgressIndicator(
      value: v.clamp(0, 1),
      color: color,
      backgroundColor: backgroundColor,
      minHeight: minHeight,
      borderRadius: BorderRadius.circular(minHeight),
    ),
  );
}
