import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nivra_new/core/scroll_behavior.dart';

void main() {
  Widget app({ScrollBehavior? behavior}) => MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        scrollBehavior: behavior,
        home: Scaffold(
          body: ListView(
            children: [for (var i = 0; i < 3; i++) ListTile(title: Text('row $i'))],
          ),
        ),
      );

  bool hasOverscrollEffect(WidgetTester tester) =>
      find.byType(GlowingOverscrollIndicator).evaluate().isNotEmpty ||
      find.byType(StretchingOverscrollIndicator).evaluate().isNotEmpty;

  testWidgets('the default behaviour does draw an overscroll effect on Android',
      (tester) async {
    // The control. Without it, the test below would pass on a finder that
    // could never have found anything.
    await tester.pumpWidget(app());
    expect(hasOverscrollEffect(tester), isTrue);
  });

  testWidgets('NoGlowScrollBehavior draws none', (tester) async {
    await tester.pumpWidget(app(behavior: const NoGlowScrollBehavior()));
    expect(hasOverscrollEffect(tester), isFalse);
  });

  testWidgets('a short list still drags and settles without error',
      (tester) async {
    await tester.pumpWidget(app(behavior: const NoGlowScrollBehavior()));
    final gesture = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('row 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on iOS the list still bounces', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        scrollBehavior: const NoGlowScrollBehavior(),
        home: Scaffold(body: ListView(children: const [Text('a')])),
      ),
    );
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    // Physics are a chain of wrappers (always-scrollable, then bouncing, then
    // range-maintaining), so the outermost layer is not the one to ask.
    final chain = <Type>[];
    for (ScrollPhysics? p = scrollable.position.physics; p != null; p = p.parent) {
      chain.add(p.runtimeType);
    }
    expect(chain, contains(BouncingScrollPhysics));
  });
}
