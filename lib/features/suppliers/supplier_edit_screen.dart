import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';

class SupplierEditScreen extends ConsumerStatefulWidget {
  const SupplierEditScreen({super.key, this.supplierId});

  final String? supplierId;

  @override
  ConsumerState<SupplierEditScreen> createState() => _SupplierEditScreenState();
}

class _SupplierEditScreenState extends ConsumerState<SupplierEditScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _opening = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  bool get _isNew => widget.supplierId == null;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    _opening.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.supplierId;
    if (id != null && !_loaded) {
      final supplier = ref.watch(supplierProvider(id)).value;
      if (supplier != null) {
        _name.text = supplier.name;
        _phone.text = supplier.phone ?? '';
        _address.text = supplier.address ?? '';
        _loaded = true;
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'New supplier' : 'Edit supplier')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            controller: _name,
            autofocus: _isNew,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _address,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Address'),
          ),
          if (_isNew) ...[
            const SizedBox(height: 16),
            TextField(
              controller: _opening,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Already owed to them',
                helperText: 'Leave blank if you are square',
                prefixText: '₹ ',
              ),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: Text(_isNew ? 'Add supplier' : 'Save'),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('A name is needed.')));
      return;
    }

    final userId = ref.read(currentUserProvider).value?.id;
    if (userId == null) return;

    setState(() => _saving = true);
    final dao = ref.read(purchaseDaoProvider);
    final phone = _phone.text.trim();
    final address = _address.text.trim();

    try {
      if (_isNew) {
        await dao.createSupplier(
          userId: userId,
          name: name,
          phone: phone.isEmpty ? null : phone,
          address: address.isEmpty ? null : address,
          openingPayable: Money.tryParse(_opening.text) ?? 0,
        );
      } else {
        await dao.updateSupplier(
          id: widget.supplierId!,
          name: name,
          phone: phone.isEmpty ? null : phone,
          address: address.isEmpty ? null : address,
        );
      }
      if (mounted) context.pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
