import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/auth_service.dart';
import 'edit_partner_profile_screen.dart';
import 'farm_documents_screen.dart';
import 'farm_kassa_screen.dart';
import 'farm_legal_screen.dart';
import 'help_screen.dart';
import 'main_tabs_screen.dart';
import 'notifications_screen.dart';
import 'storefront_screen.dart';

/// The farm's own page: who it is on the platform, and everything about itself it can change.
///
/// The first thing on it is the checklist, because the question a farm actually arrives with is
/// «почему меня не видно» - status, papers, storefront, livestock, lots, in that order. Money and
/// the deal count are the platform's to write; this screen only reads them.
class PartnerProfileScreen extends StatefulWidget {
  const PartnerProfileScreen({super.key});

  @override
  State<PartnerProfileScreen> createState() => _PartnerProfileScreenState();
}

class _PartnerProfileScreenState extends State<PartnerProfileScreen> {
  final _farms = FarmRepo();

  bool _hasLegal = false;
  bool _hasIin = false;
  bool _hasKassa = false;
  bool _loadedPrivate = false;

  /// Why a moderator refused the farm. It lives in the private record - the profile everyone can
  /// read carries no verdict text - so it is read here and shown only to the farm itself.
  String? _reviewNote;

  @override
  void initState() {
    super.initState();
    _loadPrivate();
  }

  /// The private records are two small documents and they change rarely, so they are read rather
  /// than watched; returning to this tab after filling them in re-reads them.
  Future<void> _loadPrivate() async {
    final uid = context.read<AuthService>().uid;
    if (uid == null) return;
    try {
      final legal = await _farms.readPrivate(uid, Paths.privateLegal);
      final identity = await _farms.readPrivate(uid, Paths.privateIdentity);
      final review = await _farms.readPrivate(uid, Paths.privateReview).catchError((_) => null);
      // Сам доступ к кассе не читается принципиально — только отметка, что он есть.
      final kassa = await _farms.readPrivate(uid, Paths.privateKassaInfo).catchError((_) => null);
      if (!mounted) return;
      setState(() {
        _hasLegal = asText(legal?['legalName']).isNotEmpty && asText(legal?['address']).isNotEmpty;
        _hasIin = asText(identity?['iin']).length == 12;
        _hasKassa = asText(kassa?['znm']).isNotEmpty;
        _reviewNote = asTextOrNull(review?['note']);
        _loadedPrivate = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loadedPrivate = true);
    }
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    await _loadPrivate();
  }

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthService>().uid;
    if (uid == null) return const SizedBox.shrink();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Хозяйство'),
        actions: [
          IconButton(
            tooltip: 'Изменить профиль',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _open(const EditPartnerProfileScreen()),
          ),
        ],
      ),
      body: StreamBuilder<Partner?>(
        stream: _farms.watch(uid),
        builder: (context, snapshot) {
          final farm = snapshot.data;
          if (farm == null) {
            return snapshot.connectionState == ConnectionState.waiting
                ? const Padding(
                    padding: EdgeInsets.all(EtShape.gutter),
                    child: EtSkeleton(height: 200),
                  )
                : EtEmpty(
                    title: 'Хозяйство не найдено',
                    text: 'Завершите регистрацию или войдите заново.',
                    icon: Icons.storefront_outlined,
                    action: OutlinedButton(
                      onPressed: () => context.read<AuthService>().signOut(),
                      child: const Text('Выйти'),
                    ),
                  );
          }
          return _body(uid, farm);
        },
      ),
    );
  }

  Widget _body(String uid, Partner farm) {
    return StreamBuilder<List<FarmDocument>>(
      stream: _farms.farmDocuments(uid),
      builder: (context, documents) {
        return StreamBuilder<List<Animal>>(
          stream: _farms.animals(uid),
          builder: (context, animals) {
            return StreamBuilder<List<Lot>>(
              stream: _farms.lots(uid),
              builder: (context, lots) {
                final docs = documents.data ?? const <FarmDocument>[];
                return ListView(
                  padding: const EdgeInsets.all(EtShape.gutter),
                  children: [
                    _header(farm),
                    const SizedBox(height: EtShape.gap),
                    if (!farmSells(farm.status)) ...[
                      EtNotice(
                        text: farm.status == 'rejected'
                            ? 'Хозяйство не допущено к продажам.'
                                '${_reviewNote == null ? '' : ' Причина: $_reviewNote.'}'
                                ' Лоты не показываются покупателям, новые заказы не принимаются.'
                            : 'Хозяйство на проверке у администратора. Скот, документы и лоты '
                                'можно готовить уже сейчас — покупатели увидят лоты сразу после '
                                'подтверждения.',
                        icon: farm.status == 'rejected'
                            ? Icons.error_outline
                            : Icons.hourglass_empty,
                        tone: farm.status == 'rejected' ? 'danger' : 'neutral',
                      ),
                      const SizedBox(height: EtShape.gap),
                    ],
                    _money(farm),
                    const SizedBox(height: EtShape.gap),
                    _checklist(
                      farm: farm,
                      documents: docs,
                      hasAnimals: (animals.data ?? const []).isNotEmpty,
                      hasLots: (lots.data ?? const []).isNotEmpty,
                    ),
                    const SizedBox(height: EtShape.gap),
                    _links(farm, docs),
                    const SizedBox(height: EtShape.gap),
                    _legal(uid),
                    const SizedBox(height: 18),
                    OutlinedButton.icon(
                      onPressed: () => _confirmSignOut(),
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Выйти из аккаунта'),
                    ),
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: () => _deleteAccount(),
                      style: TextButton.styleFrom(foregroundColor: context.et.danger),
                      child: const Text('Удалить аккаунт'),
                    ),
                    const SizedBox(height: 24),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _header(Partner farm) {
    final c = context.et;
    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(farm.displayName, style: context.texts.headlineSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              EtStatusChip(
                text: farmStatusLabel[farm.status] ?? 'На проверке',
                tone: farmStatusTone[farm.status] ?? 'waiting',
              ),
              if (farm.certified) const EtStatusChip(text: 'Сертификаты', tone: 'active'),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            [
              if (farm.city != null && farm.city!.isNotEmpty) farm.city!,
              farm.phone,
            ].join(' · '),
            style: context.texts.bodySmall?.copyWith(color: c.inkDim),
          ),
          const SizedBox(height: 6),
          Text(
            '${farm.rating.toStringAsFixed(1)} · ${farm.totalDeals} '
            '${pluralRu(farm.totalDeals, 'сделка', 'сделки', 'сделок')}'
            '${farm.reviewsCount > 0 ? ' · ${farm.reviewsCount} ${pluralRu(farm.reviewsCount, 'отзыв', 'отзыва', 'отзывов')}' : ''}',
            style: context.texts.bodySmall?.copyWith(color: c.inkDim),
          ),
        ],
      ),
    );
  }

  Widget _money(Partner farm) {
    final c = context.et;
    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Деньги', style: context.texts.titleSmall),
          const SizedBox(height: 4),
          EtRow(label: 'Доступно', value: formatTenge(farm.walletBalance), strong: true),
          EtRow(
            label: 'Ждёт выплаты',
            sub: 'придёт по мере прохождения заказов',
            value: formatTenge(farm.pendingBalance),
          ),
          const SizedBox(height: 6),
          Text(
            'Деньги по заказу приходят частями: половина после подтверждения, четверть при '
            'отгрузке, четверть после получения покупателем.',
            style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
          ),
        ],
      ),
    );
  }

  Widget _checklist({
    required Partner farm,
    required List<FarmDocument> documents,
    required bool hasAnimals,
    required bool hasLots,
  }) {
    final c = context.et;
    final rows = farmChecklist(
      status: farm.status,
      certified: farm.certified,
      approvedKinds: documents.where((d) => d.status == 'approved').map((d) => d.kind),
      filedKinds: documents.where((d) => d.status != 'rejected').map((d) => d.kind),
      hasLegal: _hasLegal,
      hasIin: _hasIin,
      hasKassa: _hasKassa,
      hasStorefront: !farm.storefront.isEmpty,
      hasAnimals: hasAnimals,
      hasLots: hasLots,
    );
    final left = rows.where((r) => r.state == 'todo').length;

    return EtCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Что осталось сделать', style: context.texts.titleSmall),
          const SizedBox(height: 4),
          Text(
            left == 0
                ? 'Всё на месте.'
                : 'Осталось $left ${pluralRu(left, 'шаг', 'шага', 'шагов')} — '
                    'без этого покупатели вас не увидят.',
            style: context.texts.bodySmall?.copyWith(color: c.inkDim),
          ),
          const SizedBox(height: 12),
          // Строка списка и есть путь к тому, чего не хватает. Раньше она только сообщала:
          // «Витрина — не заполнена», — и человек искал, куда нажать, хотя нажать хотелось
          // прямо сюда. Нажимается всё, кроме проверки хозяйства: её делает администратор,
          // и торопить его нажатием нельзя.
          for (final row in rows)
            InkWell(
              onTap: row.go.isEmpty ? null : () => _openChecklistStep(row.go),
              borderRadius: EtShape.smallRadius,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (row.state) {
                      'done' => Icons.check_circle,
                      'wait' => Icons.hourglass_empty,
                      _ => Icons.radio_button_unchecked,
                    },
                    size: 18,
                    color: switch (row.state) {
                      'done' => c.green,
                      'wait' => c.rust,
                      _ => c.inkFaint,
                    },
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.title,
                          style: context.texts.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: row.state == 'done' ? c.inkDim : c.ink,
                          ),
                        ),
                        Text(
                          row.note,
                          style: context.texts.bodySmall?.copyWith(color: c.inkFaint),
                        ),
                      ],
                    ),
                  ),
                  if (row.go.isNotEmpty)
                    Icon(Icons.chevron_right, size: 18, color: c.inkFaint),
                ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Ведёт туда, где незакрытый шаг закрывается. Скот и лоты — переключением нижней вкладки,
  /// а не новым экраном поверх: иначе в стопке окажется второй такой же список, и «назад»
  /// будет ходить между ними по кругу.
  void _openChecklistStep(String go) {
    switch (go) {
      case 'legal':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const FarmLegalScreen()),
        );
      case 'documents':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const FarmDocumentsScreen()),
        );
      case 'storefront':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StorefrontScreen()),
        );
      case 'kassa':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const FarmKassaScreen()),
        ).then((_) => _loadPrivate());
      case 'animals':
        MainTabsScreen.openTab(context, 2);
      case 'lots':
        MainTabsScreen.openTab(context, 1);
    }
  }

  Widget _links(Partner farm, List<FarmDocument> documents) {
    final pending = documents.where((d) => d.status == 'pending').length;
    final rejected = documents.where((d) => d.status == 'rejected').length;

    return EtCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _link(
            icon: Icons.storefront_outlined,
            title: 'Витрина',
            sub: farm.storefront.isEmpty
                ? 'Не заполнена — покупателю нечего читать'
                : 'Описание, разделка, доставка',
            onTap: () => _open(const StorefrontScreen()),
          ),
          _link(
            icon: Icons.description_outlined,
            title: 'Документы хозяйства',
            sub: rejected > 0
                ? '$rejected ${pluralRu(rejected, 'документ отклонён', 'документа отклонено', 'документов отклонено')}'
                : pending > 0
                    ? '$pending ${pluralRu(pending, 'документ', 'документа', 'документов')} на проверке'
                    : farm.certified
                        ? 'СЭС и ветконтроль приняты'
                        : 'СЭС и ветеринарный контроль',
            onTap: () => _open(const FarmDocumentsScreen()),
          ),
          _link(
            icon: Icons.receipt_long_outlined,
            title: 'Онлайн-касса',
            sub: !_loadedPrivate
                ? 'Загружаем…'
                : _hasKassa
                    ? 'Чеки выбиваются автоматически'
                    : 'Без неё покупатель не получит чек',
            onTap: () => _open(const FarmKassaScreen()),
          ),
          _link(
            icon: Icons.badge_outlined,
            title: 'Реквизиты',
            sub: !_loadedPrivate
                ? 'Загружаем…'
                : _hasLegal && _hasIin
                    ? 'Заполнены'
                    : 'Нужны для проверки хозяйства',
            onTap: () => _open(const FarmLegalScreen()),
            last: true,
          ),
        ],
      ),
    );
  }

  Widget _legal(String uid) {
    return EtCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          // Помощь — первой строкой: сюда идут, когда застряли, а застрявший человек не листает.
          _link(
            icon: Icons.help_outline,
            title: 'Помощь',
            sub: 'Как завести счёт, собрать тушу и вести заказ',
            onTap: () => _open(const HelpScreen()),
          ),
          _link(
            icon: Icons.notifications_none,
            title: 'Уведомления',
            sub: 'Новые заказы и решения администратора',
            onTap: () => _open(const NotificationsScreen()),
          ),
          _link(
            icon: Icons.description_outlined,
            title: 'Условия для хозяйств',
            sub: 'Комиссия, выплаты, споры',
            onTap: () => _openUrl('https://example.kz/legal/terms-et-partners'),
          ),
          _link(
            icon: Icons.shield_outlined,
            title: 'Политика конфиденциальности',
            sub: 'Какие данные собираются и зачем',
            onTap: () => _openUrl('https://example.kz/legal/privacy-et-partners'),
            last: true,
          ),
        ],
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Удаление аккаунта хозяйства. Сервер откажет, пока есть незакрытые заказы или брони на
  /// тушах: это чужие деньги и чужое ожидание, а не только наша запись.
  void _deleteAccount() {
    final auth = context.read<AuthService>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EtDeleteAccountScreen(
          note: 'Пока есть незакрытые заказы или брони на тушах, аккаунт удалить нельзя: '
              'на той стороне сделки человек ждёт мясо. То же самое можно сделать на сайте: '
              'https://example.kz/legal/delete-account-et-partners',
          goes: const [
            'Профиль хозяйства и витрина — покупатели перестанут вас видеть',
            'Реквизиты, ИИН и документы',
            'Скот и лоты, на которые нет броней',
            'Телефоны для уведомлений и сами уведомления',
            'Сам вход по этому номеру',
          ],
          stays: const [
            'Закрытые заказы — это запись о деньгах, и она принадлежит обеим сторонам.',
            'Отзывы покупателей о хозяйстве: они писали их о сделках, которые были.',
          ],
          onDelete: () async {
            try {
              await EtApi().deleteMyAccount(role: 'partner');
              await auth.signOut();
              return null;
            } on EtApiException catch (e) {
              return e.message;
            } catch (_) {
              return 'Не удалось удалить аккаунт. Проверьте связь и попробуйте ещё раз.';
            }
          },
        ),
      ),
    );
  }

  Widget _link({
    required IconData icon,
    required String title,
    required String sub,
    required VoidCallback onTap,
    bool last = false,
  }) {
    final c = context.et;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: c.line)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: c.green),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: context.texts.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  Text(sub, style: context.texts.bodySmall?.copyWith(color: c.inkFaint)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: c.inkFaint),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut() async {
    final auth = context.read<AuthService>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text('Заказы и лоты останутся на месте — войти можно тем же номером.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Назад')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Выйти')),
        ],
      ),
    );
    if (ok == true) await auth.signOut();
  }
}
