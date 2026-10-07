import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/scroll_behavior.dart';
import '../core/theme.dart';
import '../features/auth/auth_repository.dart';
import 'providers.dart';
import 'router.dart';

class NivraApp extends ConsumerStatefulWidget {
  const NivraApp({super.key});

  @override
  ConsumerState<NivraApp> createState() => _NivraAppState();
}

class _NivraAppState extends ConsumerState<NivraApp> {
  @override
  void initState() {
    super.initState();
    // Kick the database and sync service into existence so a signed-in
    // session starts syncing without waiting for a screen to ask for it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(currentUserProvider).value;
      if (user != null) _onSignedIn(user);
    });
  }

  Future<void> _onSignedIn(NivraUser user) async {
    if (!user.isLocalOnly) {
      // Rows created before a backend existed belong to a placeholder user.
      // Hand them to the real account so they can reach the server.
      final claimed = await ref.read(syncDaoProvider).claimLocalRows(
            fromUserId: LocalOnlyAuthRepository.localUserId,
            toUserId: user.id,
          );
      if (claimed > 0) {
        debugPrint('nivra: claimed $claimed local rows for ${user.id}');
      }
    }
    await ref.read(syncServiceProvider).start(user.id);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentUserProvider, (previous, next) async {
      final user = next.value;
      if (user == null) {
        await ref.read(syncServiceProvider).stop();
        // A different shop must not see the last one's items.
        if (previous?.value != null) {
          await ref.read(syncDaoProvider).wipeAll();
        }
      } else if (previous?.value?.id != user.id) {
        await _onSignedIn(user);
      }
    });

    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'nivra',
      debugShowCheckedModeBanner: false,
      theme: NivraTheme.light(),
      darkTheme: NivraTheme.dark(),
      scrollBehavior: const NoGlowScrollBehavior(),
      routerConfig: router,
    );
  }
}
