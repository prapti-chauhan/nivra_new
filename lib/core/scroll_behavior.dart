import 'package:flutter/material.dart';

/// Scrolling without the overscroll effect.
///
/// Android draws a glow (or, on newer Material, a stretch) when a list is
/// dragged past its end. This removes that and nothing else: the physics are
/// untouched, so iOS keeps its native bounce and Android lists simply stop at
/// their edge.
///
/// Applied once on `MaterialApp.router`, so every list, dialog and bottom sheet
/// inherits it and a new screen cannot forget to opt in.
class NoGlowScrollBehavior extends MaterialScrollBehavior {
  const NoGlowScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
}
