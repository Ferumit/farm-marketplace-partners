import 'dart:io';

import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';

/// «Документы хозяйства» - СЭС, ветконтроль and whatever else the farm is asked for.
///
/// Every file is filed as PENDING and stays that way until a moderator decides: the rules refuse
/// a document that arrives already approved, and reviewDocument is what puts the «Сертификаты»
/// badge on the storefront. So this screen files, shows the verdict and its reason, and lets the
/// farm withdraw what nobody has looked at yet.
class FarmDocumentsScreen extends StatefulWidget {
  const FarmDocumentsScreen({super.key});

  @override
  State<FarmDocumentsScreen> createState() => _FarmDocumentsScreenState();
}

class _FarmDocumentsScreenState extends State<FarmDocumentsScreen> {
  final _farms = FarmRepo();
  final _uploads = Uploads();

  double? _progress;
  String? _error;

  String? get _uid => context.read<AuthService>().uid;

  /// Which certificate, then the photograph of it.
  Future<void> _addDocument() async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(EtShape.gutter, 16, EtShape.gutter, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Какой документ?'),
              ),
            ),
            for (final kind in farmDocKinds)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(kind.label),
                onTap: () => Navigator.pop(context, kind.id),
              ),
          ],
        ),
      ),
    );
    if (kind == null) return;
    await _file(kind);
  }

  Future<void> _file(String kind) async {
    final uid = _uid;
    if (uid == null) return;

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Сфотографировать'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Выбрать из галереи'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picked = await ImagePicker().pickImage(source: source, imageQuality: 88);
    if (picked == null) return;

    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      final ref = _farms.newFarmDocumentRef(uid);
      final file = File(picked.path);
      final storagePath = Paths.farmDocument(uid, ref.id, 'jpg');
      final url = await _uploads.documentFile(
        path: storagePath,
        file: file,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      await _farms.fileDocument(
        ref: ref,
        kind: kind,
        label: farmDocLabel(kind),
        fileUrl: url,
        storagePath: storagePath,
        contentType: Uploads.contentTypeOf(picked.path),
        fileName: picked.name,
        size: await file.length(),
        partnerId: uid,
      );
      if (!mounted) return;
      setState(() => _progress = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Документ отправлен на проверку.')),
      );
    } on UploadRefused catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = 'Не удалось отправить документ. Проверьте связь.';
        });
      }
    }
  }

  Future<void> _withdraw(FarmDocument document) async {
    final uid = _uid;
    if (uid == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Убрать документ?'),
        content: Text('«${document.label}» перестанет ждать проверки. '
            'Загрузить заново можно в любой момент.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Назад')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Убрать')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _farms.withdrawDocument(_farms.farmDocumentRef(uid, document.id));
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось убрать документ.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Документы хозяйства'),
        actions: const [EtHelpButton(articleId: 'documents')],
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<List<FarmDocument>>(
              stream: _farms.farmDocuments(uid),
              builder: (context, snapshot) {
                final documents = [...(snapshot.data ?? const <FarmDocument>[])]
                  ..sort((a, b) =>
                      (b.uploadedAt ?? DateTime(0)).compareTo(a.uploadedAt ?? DateTime(0)));
                return ListView(
                  padding: const EdgeInsets.all(EtShape.gutter),
                  children: [
                    const EtNotice(
                      text: 'СЭС и ветеринарный контроль — по ним хозяйство получает значок '
                          '«Сертификаты» на витрине. Документы проверяет администратор.',
                      icon: Icons.verified_outlined,
                    ),
                    const SizedBox(height: EtShape.gap),
                    _filing(documents),
                    if (_error != null) ...[
                      const SizedBox(height: EtShape.gap),
                      EtNotice(text: _error!, icon: Icons.error_outline, tone: 'danger'),
                    ],
                    const SizedBox(height: 18),
                    if (documents.isEmpty)
                      const EtEmpty(
                        title: 'Документов пока нет',
                        text: 'Загрузите СЭС и ветеринарный контроль — это то, что проверяет '
                            'администратор.',
                        icon: Icons.description_outlined,
                      )
                    else ...[
                      const EtEyebrow('Загруженные'),
                      const SizedBox(height: 10),
                      for (final document in documents) _card(document),
                    ],
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),
    );
  }

  Widget _filing(List<FarmDocument> documents) {
    final uploading = _progress != null;
    final filed = documents.where((d) => d.status != 'rejected').map((d) => d.kind).toSet();

    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Загрузить документ', style: context.texts.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Фотография или скан. До 20 МБ.',
            style: context.texts.bodySmall?.copyWith(color: context.et.inkFaint),
          ),
          const SizedBox(height: 12),
          if (uploading)
            EtProgress(
              percent: _progress!,
              label: 'Отправляем документ',
              trailing: '${(_progress! * 100).round()} %',
            )
          else ...[
            for (final kind in farmDocKinds)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(
                      filed.contains(kind.id) ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 16,
                      color: filed.contains(kind.id) ? context.et.green : context.et.inkFaint,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        kind.label,
                        style: context.texts.bodySmall?.copyWith(
                          color: filed.contains(kind.id) ? context.et.inkFaint : context.et.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _addDocument,
              icon: const Icon(Icons.photo_camera_outlined, size: 18),
              label: const Text('Загрузить документ'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _card(FarmDocument document) {
    final c = context.et;
    return Padding(
      padding: const EdgeInsets.only(bottom: EtShape.gap),
      child: EtCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(document.label.isEmpty ? farmDocLabel(document.kind) : document.label,
                style: context.texts.titleSmall),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: EtStatusChip(
                text: docStatusLabel[document.status] ?? document.status,
                tone: docStatusTone[document.status] ?? 'neutral',
              ),
            ),
            if (document.reviewNote != null && document.reviewNote!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Администратор: ${document.reviewNote}',
                style: context.texts.bodySmall?.copyWith(color: c.danger),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(document.fileUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Открыть'),
                ),
                const Spacer(),
                if (document.status == 'pending')
                  TextButton(
                    onPressed: () => _withdraw(document),
                    child: const Text('Убрать'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
