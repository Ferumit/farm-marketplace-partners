import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import 'notifications_screen.dart';
import 'order_screen.dart';

/// The farm's order desk - leadership's window 2.1.
///
/// Everything the farm has to do, with the next step written on every card: a farmer opening the
/// app at six in the morning should not have to work out where a deal stands, only what to press.
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthService>().uid;
    if (uid == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Заказы'),
        actions: [
          EtBell(
            unread: NotificationsRepo().unreadCount(uid),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const NotificationsScreen()),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<FarmOrder>>(
        stream: OrdersRepo().forPartner(uid),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const EtEmpty(
              title: 'Не удалось загрузить заказы',
              text: 'Проверьте связь и потяните вниз, чтобы обновить.',
              icon: Icons.cloud_off,
            );
          }
          if (!snapshot.hasData) {
            return ListView(
              padding: const EdgeInsets.all(EtShape.gutter),
              children: const [
                EtSkeleton(height: 120),
                SizedBox(height: EtShape.gap),
                EtSkeleton(height: 120),
              ],
            );
          }

          final orders = snapshot.data!;
          if (orders.isEmpty) {
            return const EtEmpty(
              title: 'Заказов пока нет',
              illustrated: true,
              text: 'Как только покупатель оформит тушу, заказ появится здесь — '
                  'и вы пройдёте по нему четыре шага до передачи.',
              icon: Icons.inventory_2_outlined,
            );
          }

          final active = orders.where((o) => !isFinished(o)).toList();
          final done = orders.where(isFinished).toList();

          return ListView(
            padding: const EdgeInsets.all(EtShape.gutter),
            children: [
              if (active.isNotEmpty) ...[
                const EtEyebrow('В работе'),
                const SizedBox(height: 10),
                for (var i = 0; i < active.length; i++)
                  EtReveal(index: i, child: _OrderCard(order: active[i])),
              ],
              if (done.isNotEmpty) ...[
                const SizedBox(height: 18),
                const EtEyebrow('Завершённые и отменённые'),
                const SizedBox(height: 10),
                for (var i = 0; i < done.length; i++)
                  EtReveal(index: i, child: _OrderCard(order: done[i])),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});

  final FarmOrder order;

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    final next = farmNextStep(order);
    final where = order.delivery.isPickup
        ? 'Самовывоз из хаба'
        : (order.deliveryAddress.isEmpty ? 'Адрес не указан' : order.deliveryAddress);

    return Padding(
      padding: const EdgeInsets.only(bottom: EtShape.gap),
      child: EtCard(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => OrderScreen(orderId: order.id)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The name first, the state under it: a carcass name is long, and side by side the
            // two squeezed each other into broken words on a narrow phone.
            Text(order.lotTitle.isEmpty ? 'Заказ' : order.lotTitle,
                style: context.texts.titleMedium),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: EtStatusChip(
                text: statusTextForFarm(order),
                tone: statusTone(order),
                icon: etStageIcon(order.status),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${orderSummary(format: order.format, estimatedWeightKg: order.estimatedWeightKg, shares: order.shares)}'
              ' · ${formatTenge(order.total)}',
              style: context.texts.bodySmall?.copyWith(color: c.inkDim),
            ),
            if (order.isJoint)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Совместная покупка · ${order.group!.size} '
                  '${pluralRu(order.group!.size, 'участник', 'участника', 'участников')}',
                  style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(order.delivery.isPickup ? Icons.store_outlined : Icons.location_on_outlined,
                    size: 16, color: c.inkFaint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    where,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                  ),
                ),
              ],
            ),
            if (next != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.arrow_forward, size: 16, color: c.green),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      next,
                      style: context.texts.bodyMedium
                          ?.copyWith(color: c.green, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
