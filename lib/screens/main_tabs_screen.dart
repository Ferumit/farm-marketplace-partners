import 'dart:async';

import 'package:et_core/et_core.dart';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'notifications_screen.dart';
import 'order_screen.dart';
import 'orders_screen.dart';
import 'storefront_screen.dart';
import 'partner_profile_screen.dart';
import 'my_lots_screen.dart';
import 'my_animals_screen.dart';
import 'traceability_screen.dart';

/// The farm's cabinet.
///
/// Orders come first: they are the work. Chats left the bar - nothing could create one anyway
/// (the rules let only the server open a chat), and the buyer's phone is on every order card.
class MainTabsScreen extends StatefulWidget {
  const MainTabsScreen({super.key});

  /// Переключает нижнюю вкладку из любого места дерева. Нужно там, где экран подсказывает
  /// человеку следующий шаг: «Скот» и «Лоты» живут в панели внизу, и класть их копию поверх
  /// значило бы завести второй список, между которым и первым «назад» ходит по кругу.
  static void openTab(BuildContext context, int index) {
    context.findAncestorStateOfType<_MainTabsScreenState>()?._goTo(index);
  }

  @override
  State<MainTabsScreen> createState() => _MainTabsScreenState();
}

class _MainTabsScreenState extends State<MainTabsScreen> with _PushRouting {
  int _index = 0;

  void _goTo(int index) {
    if (!mounted) return;
    // Профиль открыт поверх вкладок? Снимаем, иначе человек переключит вкладку и не увидит её.
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _index = index);
  }

  @override
  void initState() {
    super.initState();
    listenForPushes();
    listenForLinks();
  }

  @override
  void dispose() {
    stopListeningForPushes();
    stopListeningForLinks();
    super.dispose();
  }

  /// Ссылка на кабинет с сайта открывает тот же раздел в приложении.
  @override
  void openLink(LinkTarget target) {
    if (!mounted) return;
    switch (target.kind) {
      case 'cabinetLots':
        setState(() => _index = 1);
      case 'cabinetAnimals':
        setState(() => _index = 2);
      case 'cabinetStorefront':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StorefrontScreen()),
        );
      default:
        setState(() => _index = 0);
    }
  }

  /// A push names the order it is about; the screen is read fresh from Firestore.
  @override
  void openPush(PushTarget target) {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (target.isOrder) {
      navigator.push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: target.orderId!)));
    } else {
      navigator.push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
    }
  }

  static const _tabs = [
    (icon: Icons.receipt_long_outlined, active: Icons.receipt_long, label: 'Заказы'),
    (icon: Icons.inventory_2_outlined, active: Icons.inventory_2, label: 'Лоты'),
    (icon: Icons.pets_outlined, active: Icons.pets, label: 'Скот'),
    (icon: Icons.route_outlined, active: Icons.route, label: 'След'),
    (icon: Icons.person_outline, active: Icons.person, label: 'Профиль'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.et;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          OrdersScreen(),
          MyLotsScreen(),
          MyAnimalsScreen(),
          TraceabilityScreen(),
          PartnerProfileScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          border: Border(top: BorderSide(color: c.line)),
        ),
        child: SafeArea(
          top: false,
          child: NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: Colors.transparent,
              indicatorColor: c.greenTint,
              labelTextStyle: WidgetStatePropertyAll(
                context.texts.labelSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            child: NavigationBar(
              selectedIndex: _index,
              height: 68,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final tab in _tabs)
                  NavigationDestination(
                    icon: Icon(tab.icon, color: c.inkFaint),
                    selectedIcon: Icon(tab.active, color: c.green),
                    label: tab.label,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Push, once the cabinet is on screen: a tap opens the order, and a message that arrives while
/// the farm is already looking gets a line at the bottom - Android shows nothing of its own
/// while the app is in front.
mixin _PushRouting<T extends StatefulWidget> on State<T> {
  final Push _push = Push();
  final DeepLinks _links = DeepLinks();
  StreamSubscription<RemoteMessage>? _opened;
  StreamSubscription<RemoteMessage>? _inApp;
  StreamSubscription<LinkTarget>? _linked;

  void openPush(PushTarget target);
  void openLink(LinkTarget target);

  /// Ссылка, которой приложение запустили, и ссылки, пришедшие в уже открытое, ведут в одно
  /// место.
  void listenForLinks() {
    _linked = _links.stream.listen(openLink);
    _links.initial().then((target) {
      if (target != null && !target.isEmpty && mounted) openLink(target);
    });
  }

  void stopListeningForLinks() => _linked?.cancel();

  void listenForPushes() {
    _opened = _push.opened.listen((message) => openPush(PushTarget.of(message)));
    _inApp = _push.whileOpen.listen(_announce);
    _push.launchMessage().then((message) {
      if (message != null && mounted) openPush(PushTarget.of(message));
    });
  }

  void stopListeningForPushes() {
    _opened?.cancel();
    _inApp?.cancel();
  }

  void _announce(RemoteMessage message) {
    if (!mounted) return;
    final target = PushTarget.of(message);
    final title = target.title ?? '';
    final body = target.body ?? '';
    if (title.isEmpty && body.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text([title, body].where((s) => s.isNotEmpty).join(' — ')),
        action: SnackBarAction(label: 'Открыть', onPressed: () => openPush(target)),
        duration: const Duration(seconds: 6),
      ),
    );
  }
}
