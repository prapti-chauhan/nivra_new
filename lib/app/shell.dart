import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';

/// Bills first, because billing is the whole app. Cold start to a new bill is
/// one tap. Opening straight onto the bill editor was tempting and rejected:
/// he also opens the app to check who owes him money, and that should not mean
/// backing out of a half-started bill.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return DayWatcher(
      child: Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (index) => navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          ),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'Bills',
            ),
            NavigationDestination(
              icon: Icon(Icons.inventory_2_outlined),
              selectedIcon: Icon(Icons.inventory_2),
              label: 'Items',
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: 'Customers',
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart),
              label: 'Reports',
            ),
            NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
          ],
        ),
      ),
    );
  }
}

/// Tells the app the day has changed.
///
/// A shop that never closes the app crosses midnight with it open, and
/// "Today" on the reports would go on showing yesterday. This arms a timer for
/// the next local midnight, and re-checks whenever the app returns to the
/// foreground, because a timer does not run while a phone is asleep and the
/// midnight may have passed during that time.
///
/// It lives in a widget, not a provider, so the timer ends with the widget and
/// nothing outlives the screen it serves.
class DayWatcher extends ConsumerStatefulWidget {
  const DayWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DayWatcher> createState() => _DayWatcherState();
}

class _DayWatcherState extends ConsumerState<DayWatcher>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _arm();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    ref.read(currentDayProvider.notifier).refresh();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    final now = DateTime.fromMillisecondsSinceEpoch(
      ref.read(databaseProvider).clock.nowMillis(),
    );
    final midnight = DateTime(now.year, now.month, now.day + 1);
    // A second past, so the clock has certainly ticked over when it fires.
    final wait = midnight.difference(now) + const Duration(seconds: 1);
    _timer = Timer(wait, () {
      if (!mounted) return;
      ref.read(currentDayProvider.notifier).refresh();
      _arm();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
