import 'package:et_core/et_core.dart';
import 'package:test/test.dart';

/// Ссылка приходит из WhatsApp, а не из приложения — значит, приходит любая.
void main() {
  LinkTarget? at(String url) => parseEtLink(Uri.tryParse(url));

  group('сбор — то, ради чего всё затевалось', () {
    test('ссылка организатора', () {
      expect(at('https://example.kz/group?id=g123'), const LinkTarget('group', id: 'g123'));
    });

    test('с www и с завершающим слэшем', () {
      expect(at('https://www.example.kz/group/?id=g123'), const LinkTarget('group', id: 'g123'));
    });

    test('сбор без id ведёт на главную, а не в пустой экран', () {
      expect(at('https://example.kz/group'), const LinkTarget('home'));
    });

    test('groupLink и разбор — одно и то же', () {
      expect(at(groupLink('g777')), const LinkTarget('group', id: 'g777'));
    });
  });

  group('туши', () {
    test('чистый адрес', () => expect(at('https://example.kz/lots/lot1'), const LinkTarget('lot', id: 'lot1')));
    test('старый адрес с ?id', () => expect(at('https://example.kz/lot.html?id=lot1'), const LinkTarget('lot', id: 'lot1')));
    test('раздел целиком', () => expect(at('https://example.kz/lots'), const LinkTarget('lots')));
    test('режим split не мешает', () => expect(at('https://example.kz/lots/lot1/split'), const LinkTarget('lot', id: 'lot1')));
  });

  group('заказы', () {
    test('на сайте адрес по лоту — ведём в список, а не в чужой заказ', () {
      expect(at('https://example.kz/orders/lot1'), const LinkTarget('order'));
    });
    test('явный orderId открывает заказ', () {
      expect(at('https://example.kz/order?orderId=o1'), const LinkTarget('order', id: 'o1'));
    });
  });

  group('кабинет хозяйства', () {
    test('заказы', () => expect(at('https://example.kz/cabinet/orders'), const LinkTarget('cabinetOrders')));
    test('лоты', () => expect(at('https://example.kz/cabinet/lots'), const LinkTarget('cabinetLots')));
    test('витрина', () => expect(at('https://example.kz/cabinet/storefront'), const LinkTarget('cabinetStorefront')));
    test('кабинет без раздела — заказы: это то, зачем туда заходят', () {
      expect(at('https://example.kz/cabinet'), const LinkTarget('cabinetOrders'));
    });
  });

  group('оплата и регистрация', () {
    // Сайт отдаёт заказ как ?id=, а разбор раньше смотрел только ?orderId= — ссылка на
    // конкретный заказ открывала список. На возврате с оплаты это значило бы, что человек
    // заплатил и попал непонятно куда.
    test('заказ по ?id= — как его даёт сайт', () {
      expect(at('https://example.kz/order?id=ord1'), const LinkTarget('order', id: 'ord1'));
    });
    test('заказ по ?orderId= продолжает работать', () {
      expect(at('https://example.kz/order?orderId=ord1'), const LinkTarget('order', id: 'ord1'));
    });
    test('возврат с оплаты ведёт на тот же заказ', () {
      expect(at('https://example.kz/pay/return?order=ord1&paid=1'),
          const LinkTarget('order', id: 'ord1'));
    });
    test('возврат без заказа — в список, а не в чужой заказ', () {
      expect(at('https://example.kz/pay/return'), const LinkTarget('order'));
    });
    test('QR хозяйства', () {
      expect(at('https://example.kz/register?role=partner'), const LinkTarget('registerPartner'));
    });
    test('регистрация без роли', () {
      expect(at('https://example.kz/register'), const LinkTarget('register'));
    });
  });

  group('чужое не открываем', () {
    test('другой домен с похожим путём', () {
      expect(at('https://example.kz.evil.com/group?id=g1'), isNull);
    });
    test('совсем другой сайт', () {
      expect(at('https://example.com/lots/lot1'), isNull);
    });
    test('мусор вместо ссылки', () {
      expect(parseEtLink(null), isNull);
      expect(at('https://example.kz/непонятно'), const LinkTarget('home'));
    });
  });
}
