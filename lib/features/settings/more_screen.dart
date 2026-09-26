import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/billing.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider).value;
    final profile = ref.watch(businessProfileProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.storefront_outlined),
            title: const Text('Shop details'),
            subtitle: Text(
              (profile?.shopName ?? '').isEmpty
                  ? 'Not set — this goes on your bills'
                  : profile!.shopName,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/shop'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.local_shipping_outlined),
            title: const Text('Suppliers'),
            subtitle: const Text('Who you buy from, and what you owe them'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/suppliers'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Purchases'),
            subtitle: const Text('Stock coming in'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/purchases'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('Your data'),
            subtitle: const Text('Backup and sync'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sync'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('Next bill number'),
            subtitle: Text(
              invoiceLabel(
                prefix: profile?.invoicePrefix ?? '',
                number: profile?.invoiceNextNumber ?? 1,
              ),
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              user?.email ?? '',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text(
              'Sign out',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onTap: () => ref.read(authRepositoryProvider).signOut(),
          ),
        ],
      ),
    );
  }
}

class ShopDetailsScreen extends ConsumerStatefulWidget {
  const ShopDetailsScreen({super.key});

  @override
  ConsumerState<ShopDetailsScreen> createState() => _ShopDetailsScreenState();
}

class _ShopDetailsScreenState extends ConsumerState<ShopDetailsScreen> {
  final _shopName = TextEditingController();
  final _ownerName = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _prefix = TextEditingController();
  bool _loaded = false;

  @override
  void dispose() {
    for (final c in [_shopName, _ownerName, _phone, _address, _prefix]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) return;
    await ref.read(billingDaoProvider).updateProfile(
          userId: userId,
          shopName: _shopName.text.trim(),
          ownerName: _ownerName.text.trim(),
          phone: _phone.text.trim(),
          address: _address.text.trim(),
          invoicePrefix: _prefix.text.trim(),
        );
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = ref.watch(businessProfileProvider).value;

    if (profile != null && !_loaded) {
      _shopName.text = profile.shopName;
      _ownerName.text = profile.ownerName ?? '';
      _phone.text = profile.phone ?? '';
      _address.text = profile.address ?? '';
      _prefix.text = profile.invoicePrefix;
      _loaded = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Shop details')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
        children: [
          Text(
            'This is what your customers see on a bill.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _shopName,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Shop name'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ownerName,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Your name'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _address,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Address'),
          ),
          const SizedBox(height: 26),
          TextField(
            controller: _prefix,
            decoration: const InputDecoration(
              labelText: 'Bill number prefix',
              hintText: 'Leave blank for plain numbers',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Changing this only affects new bills. Old ones keep the number '
            'they were given.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(onPressed: _save, child: const Text('Save')),
        ),
      ),
    );
  }
}
