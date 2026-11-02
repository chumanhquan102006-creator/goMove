import 'package:flutter/material.dart';

/// Shared, presentation-only motion tokens for the M4.4A interface.
///
/// Keep transition timing in one place so screens can honour the platform's
/// reduced-motion setting without changing any domain or network state.
abstract final class AppMotion {
  static const Duration touch = Duration(milliseconds: 140);
  static const Duration feedback = Duration(milliseconds: 180);
  static const Duration card = Duration(milliseconds: 240);
  static const Duration pageEnter = Duration(milliseconds: 280);
  static const Duration pageExit = Duration(milliseconds: 220);
  static const Duration cash = Duration(milliseconds: 240);
  static const Duration sheet = Duration(milliseconds: 360);

  static const Curve enterCurve = Curves.easeOutCubic;
  static const Curve exitCurve = Curves.easeInCubic;
  static const Curve standardCurve = Curves.easeInOutCubic;

  static const double cardTravel = 12;
  static const double pageTravel = 16;

  static bool reduceMotion(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static Duration duration(BuildContext context, Duration normal) =>
      reduceMotion(context) ? Duration.zero : normal;

  /// One-shot entrance for a small Flutter-only header or card subtree.
  static Widget entrance(BuildContext context, Widget child) {
    if (reduceMotion(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: card,
      curve: enterCurve,
      child: child,
      builder: (_, progress, content) => Opacity(
        opacity: progress,
        child: Transform.translate(
          offset: Offset(0, cardTravel * (1 - progress)),
          child: content,
        ),
      ),
    );
  }

  /// For Flutter-only auth pages. Do not use this on routes containing MapLibre.
  static PageRoute<T> authRoute<T>(BuildContext context, Widget page) {
    final reduced = reduceMotion(context);
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: reduced ? Duration.zero : pageEnter,
      reverseTransitionDuration: reduced ? Duration.zero : pageExit,
      transitionsBuilder: (_, animation, __, child) {
        if (reduced) return child;
        return AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (_, content) {
            final curve = animation.status == AnimationStatus.reverse
                ? exitCurve
                : standardCurve;
            final progress = curve.transform(animation.value);
            return Opacity(
              opacity: progress,
              child: Transform.translate(
                offset: Offset(0, pageTravel * (1 - progress)),
                child: content,
              ),
            );
          },
        );
      },
    );
  }

  /// Slide/fade Flutter content. A destination containing a native map must
  /// mount it after this route completes and remove it before reverse motion.
  static PageRoute<T> contentRoute<T>(BuildContext context, Widget page) {
    final reduced = reduceMotion(context);
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: reduced ? Duration.zero : pageEnter,
      reverseTransitionDuration: reduced ? Duration.zero : pageExit,
      transitionsBuilder: (_, animation, __, child) {
        if (reduced) return child;
        final curved = animation.drive(CurveTween(curve: standardCurve));
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(.06, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  /// Authenticated home/logout routes switch immediately so an outgoing
  /// MapLibre view or private trip data is never animated underneath a page.
  static PageRoute<T> immediateRoute<T>(Widget page) => PageRouteBuilder<T>(
        pageBuilder: (_, __, ___) => page,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      );
}
