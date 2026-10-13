import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import 'order_screen.dart';

/// «Уведомления» - everything the server has said to this farm.
///
/// Push is a knock and can be missed: the phone was off, the person was driving, the permission
/// was refused. The record is here, and it is the same document the push was made from - so what
/// is on screen is what happened, not what a message claimed.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthService>().uid;
    if (uid == null) return const SizedBox.shrink();
    final repo = NotificationsRepo();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Уведомления'),
        actions: [
          TextButton(
            onPressed: () => repo.markAllRead(uid),
            child: const Text('Прочитано'),
          ),
        ],
      ),
      body: StreamBuilder<List<AppNotification>>(
        stream: repo.stream(uid),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const EtEmpty(
              title: 'Не удалось загрузить',
              text: 'Проверьте связь.',
              icon: Icons.cloud_off,
            );
          }
          if (!snapshot.hasData) {
            return const Padding(
              padding: EdgeInsets.all(EtShape.gutter),
              child: Column(
                children: [
                  EtSkeleton(height: 86),
                  SizedBox(height: EtShape.gap),
                  EtSkeleton(height: 86),
                ],
              ),
            );
          }

          final notes = snapshot.data!;
          if (notes.isEmpty) {
            return const EtEmpty(
              title: 'Пока тихо',
              illustrated: true,
              text: 'Здесь появятся новые заказы, подтверждения покупателей и решения '
                  'администратора.',
              icon: Icons.notifications_none,
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(EtShape.gutter),
            itemCount: notes.length,
            itemBuilder: (context, i) =>
                EtReveal(index: i, child: _Card(note: notes[i], repo: repo)),
          );
        },
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.note, required this.repo});

  final AppNotification note;
  final NotificationsRepo repo;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Padding(
      padding: const EdgeInsets.only(bottom: EtShape.gap),
      child: EtCard(
        tinted: !note.read,
        onTap: () {
          repo.markRead(note.id);
          if (note.orderId != null && note.orderId!.isNotEmpty) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => OrderScreen(orderId: note.orderId!)),
            );
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(note.title, style: context.texts.titleSmall)),
                if (!note.read)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(top: 6, left: 8),
                    decoration: BoxDecoration(color: c.green, shape: BoxShape.circle),
                  ),
              ],
            ),
            if (note.body.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(note.body, style: context.texts.bodySmall?.copyWith(color: c.inkDim)),
            ],
            const SizedBox(height: 8),
            Text(
              whenText(note.createdAt),
              style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
            ),
          ],
        ),
      ),
    );
  }
}
