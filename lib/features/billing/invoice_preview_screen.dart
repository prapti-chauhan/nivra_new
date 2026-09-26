import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../domain/invoice.dart';

/// Shows Ramesh exactly what his customer will receive, then shares it.
///
/// The preview is not decoration. This is the only artefact of the app that
/// leaves the shop, and he should never send one without having seen it.
class InvoicePreviewScreen extends ConsumerStatefulWidget {
  const InvoicePreviewScreen({super.key, required this.billId});

  final String billId;

  @override
  ConsumerState<InvoicePreviewScreen> createState() =>
      _InvoicePreviewScreenState();
}

class _InvoicePreviewScreenState extends ConsumerState<InvoicePreviewScreen> {
  bool _sharing = false;

  @override
  Widget build(BuildContext context) {
    final doc = ref.watch(invoiceDocumentProvider(widget.billId));
    final pdf = ref.watch(invoicePdfProvider(widget.billId));

    return Scaffold(
      appBar: AppBar(title: Text(doc?.numberLabel ?? 'Bill')),
      body: pdf.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _Failed(message: '$error'),
        data: (bytes) {
          if (bytes == null || doc == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return PdfPreview(
            build: (_) => bytes,
            // The share and print affordances are ours, at the bottom, where
            // a thumb reaches. The package's toolbar buttons would be a
            // second set saying the same thing.
            allowSharing: false,
            allowPrinting: true,
            canChangePageFormat: false,
            canChangeOrientation: false,
            canDebug: false,
            useActions: true,
            padding: const EdgeInsets.all(12),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: FilledButton.icon(
          onPressed: (pdf.value == null || doc == null || _sharing)
              ? null
              : () => _share(doc, pdf.value!),
          icon: _sharing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.share_outlined),
          label: Text(_sharing ? 'Preparing…' : 'Share bill'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
        ),
      ),
    );
  }

  Future<void> _share(InvoiceDocument doc, Uint8List bytes) async {
    setState(() => _sharing = true);
    try {
      final path = await writeInvoiceToTempFile(doc, bytes);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: 'application/pdf')],
          // WhatsApp shows this as the caption beside the attachment, so the
          // customer can read the amount without opening the file.
          text: shareCaption(doc),
          subject: '${doc.numberLabel} from ${doc.shopName}',
          // Needed on iPad, harmless elsewhere.
          sharePositionOrigin:
              box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share the bill. $error')),
      );
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}

/// The message that travels with the attachment.
String shareCaption(InvoiceDocument doc) {
  final buffer = StringBuffer()
    ..write('${doc.shopName}\n')
    ..write('${doc.numberLabel} — ${Money.format(doc.totalPaise)}');
  if (doc.duePaise > 0 && doc.paidPaise > 0) {
    buffer.write('\nBalance due ${Money.format(doc.duePaise)}');
  }
  return buffer.toString();
}

/// Writes the bytes somewhere the share sheet can read them.
///
/// The file is named after the invoice, because the name is what the customer
/// sees in their WhatsApp downloads months later — "INV-0012.pdf" is findable,
/// "share.pdf" is not.
Future<String> writeInvoiceToTempFile(
  InvoiceDocument doc,
  Uint8List bytes,
) async {
  final dir = await getTemporaryDirectory();
  final safe = doc.numberLabel.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
  final file = File('${dir.path}/$safe.pdf');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

class _Failed extends StatelessWidget {
  const _Failed({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.description_outlined, size: 40),
            const SizedBox(height: 12),
            const Text('The bill could not be prepared.'),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
