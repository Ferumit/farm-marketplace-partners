/// Адреса сайта, разобранные в то, что приложение умеет открыть.
///
/// Ссылку на совместную покупку человек получает в WhatsApp, а не в приложении: организатор
/// копирует её со страницы сбора. Если приложение установлено, она должна открыть сбор, а не
/// браузер — за это отвечают App Links в манифесте, а за то, ЧТО именно открыть, отвечает этот
/// разбор.
///
/// Здесь нет Firebase и нет Flutter: адреса — часть модели, и сайт с приложением обязаны
/// понимать их одинаково. Формы адресов взяты из nginx (deploy/nginx-site.conf), где чистые
/// URL превращаются в файлы: /lots/{id}, /orders/{lotId}, /farmers/{id}, /group?id=.
library;

/// Что открыть по ссылке. `kind` — одно из: group, lot, lots, order, farm, register,
/// registerPartner, cabinetOrders, cabinetLots, cabinetAnimals, cabinetStorefront, home.
class LinkTarget {
  const LinkTarget(this.kind, {this.id});

  final String kind;
  final String? id;

  bool get isEmpty => kind == 'home' && id == null;

  @override
  String toString() => id == null ? kind : '$kind:$id';

  @override
  bool operator ==(Object other) =>
      other is LinkTarget && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

const _host = 'example.kz';

/// Разбирает ссылку сайта. Чужой домен — null: приложение не открывает то, что ему не
/// адресовано, даже если формат пути совпал.
LinkTarget? parseEtLink(Uri? uri) {
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  if (host.isNotEmpty && host != _host && host != 'www.$_host') return null;

  final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final query = uri.queryParameters;

  if (parts.isEmpty) return const LinkTarget('home');

  // Сайт отдаёт и чистые адреса (/lots/{id}), и старые файловые (/lot.html?id=) — вторые всё ещё
  // ходят по перепискам, и ссылка годовой давности должна открываться так же.
  var head = parts.first.toLowerCase();
  if (head.endsWith('.html')) head = head.substring(0, head.length - 5);

  switch (head) {
    // Сбор: /group?id=... — так его отдаёт ссылка организатора.
    case 'group':
      final id = parts.length > 1 ? parts[1] : query['id'];
      return id == null || id.isEmpty ? const LinkTarget('home') : LinkTarget('group', id: id);

    // Туша: /lots/{id}, /lots/{id}/split и просто /lots.
    case 'lots':
    case 'lot':
      final id = parts.length > 1 ? parts[1] : query['id'];
      return id == null || id.isEmpty ? const LinkTarget('lots') : LinkTarget('lot', id: id);

    // Заказ. Исторически здесь ждали только ?orderId=, а сайт отдаёт ?id= — и ссылка на
    // конкретный заказ открывала список. Теперь принимаются оба, причём /orders/{id} остаётся
    // идентификатором ЛОТА (старый вид страницы), поэтому путь и запрос разведены.
    case 'orders':
    case 'order':
      final id = query['orderId'] ?? query['id'];
      return id == null || id.isEmpty ? const LinkTarget('order') : LinkTarget('order', id: id);

    // Возврат с платёжной страницы: /pay/return?order=... Ведём на тот же экран заказа —
    // платёж сам по себе экрана не имеет, человек должен увидеть результат там, где заказ.
    case 'pay':
      final id = query['order'] ?? query['orderId'] ?? query['id'];
      return id == null || id.isEmpty ? const LinkTarget('order') : LinkTarget('order', id: id);

    // Регистрация. ?role=partner — это QR, который хозяйству дают в руки: с установленным
    // ET Partners он открывает приложение, без него остаётся страницей сайта.
    case 'register':
      return query['role'] == 'partner'
          ? const LinkTarget('registerPartner')
          : const LinkTarget('register');

    case 'farmers':
    case 'farmer':
      final id = parts.length > 1 ? parts[1] : query['id'];
      return id == null || id.isEmpty ? const LinkTarget('home') : LinkTarget('farm', id: id);

    // Кабинет хозяйства.
    case 'cabinet':
      final section = parts.length > 1 ? parts[1] : '';
      return switch (section) {
        'lots' => const LinkTarget('cabinetLots'),
        'animals' => const LinkTarget('cabinetAnimals'),
        'storefront' => const LinkTarget('cabinetStorefront'),
        _ => const LinkTarget('cabinetOrders'),
      };

    default:
      return const LinkTarget('home');
  }
}

/// Ссылка на сбор — та самая, которую организатор отправляет друзьям.
String groupLink(String groupId) => 'https://$_host/group?id=$groupId';
