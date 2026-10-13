// Чек на заказе: что приложения о нём читают.
//
// Главное здесь не номер и не ссылка, а признак контура. Пока боевого ключа re:Kassa нет, чеки
// выбиваются на тестовом сервере: по виду настоящие, но в налоговую не ушедшие. Если это поле
// прочитается неверно, покупателю подпишут пробный документ как фискальный — а это уже не баг
// отображения.
import 'package:et_core/et_core.dart';
import 'package:test/test.dart';

void main() {
  group('чек на заказе', () {
    test('чека нет — и объекта нет', () {
      expect(OrderFiscal.fromMap(null), isNull);
      expect(OrderFiscal.fromMap(const <String, dynamic>{}), isNull);
    });

    test('номер и ссылка читаются', () {
      final f = OrderFiscal.fromMap({
        'ticketNumber': '000000000000',
        'url': 'https://ofd.example.invalid/t/1',
        'kgdKkmId': '000000000000',
      })!;
      expect(f.ticketNumber, '000000000000');
      expect(f.url, 'https://ofd.example.invalid/t/1');
      expect(f.issued, isTrue);
    });

    test('чек выбит, если есть хоть ссылка, хоть номер', () {
      expect(OrderFiscal.fromMap({'url': 'https://x.invalid/1'})!.issued, isTrue);
      expect(OrderFiscal.fromMap({'ticketNumber': '7'})!.issued, isTrue);
      expect(OrderFiscal.fromMap({'error': 'касса не ответила'})!.issued, isFalse);
    });

    test('ошибка не теряется: молчаливое отсутствие чека хуже видимой', () {
      expect(OrderFiscal.fromMap({'error': 'Касса хозяйства не подключена'})!.error,
          'Касса хозяйства не подключена');
    });

    // Признак ставит сервер по адресу re:Kassa. Клиент его не угадывает и не домысливает.
    test('тестовый контур виден', () {
      expect(OrderFiscal.fromMap({'url': 'https://x.invalid/1', 'test': true})!.test, isTrue);
    });

    test('без признака чек считается боевым — старые заказы тестовыми не были', () {
      expect(OrderFiscal.fromMap({'url': 'https://x.invalid/1'})!.test, isFalse);
    });

    test('признаком считается только настоящее да, а не строка и не единица', () {
      expect(OrderFiscal.fromMap({'url': 'https://x.invalid/1', 'test': 'true'})!.test, isFalse);
      expect(OrderFiscal.fromMap({'url': 'https://x.invalid/1', 'test': 1})!.test, isFalse);
      expect(OrderFiscal.fromMap({'url': 'https://x.invalid/1', 'test': false})!.test, isFalse);
    });
  });

  group('заказ отдаёт оба чека', () {
    test('продажа и возврат разбираются по отдельности', () {
      final o = FarmOrder.fromMap('o1', {
        'buyerUid': 'b',
        'partnerId': 'f',
        'status': 'completed',
        'amount': 421250,
        'fiscal': {'ticketNumber': '1', 'url': 'https://x.invalid/1', 'test': true},
        'fiscalReturn': {'ticketNumber': '2', 'url': 'https://x.invalid/2', 'test': true},
      });
      expect(o.fiscal?.ticketNumber, '1');
      expect(o.fiscalReturn?.ticketNumber, '2');
      expect(o.fiscal?.test, isTrue);
      expect(o.fiscalReturn?.test, isTrue);
    });

    test('заказ без чеков не падает', () {
      final o = FarmOrder.fromMap('o1', {
        'buyerUid': 'b', 'partnerId': 'f', 'status': 'created', 'amount': 1000,
      });
      expect(o.fiscal, isNull);
      expect(o.fiscalReturn, isNull);
    });
  });
}
