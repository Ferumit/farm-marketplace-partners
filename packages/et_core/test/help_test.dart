import 'package:et_core/et_core.dart';
import 'package:test/test.dart';

void main() {
  test('у каждой статьи есть ответ одной фразой и свой идентификатор', () {
    final ids = <String>{};
    for (final a in helpArticles) {
      expect(a.id, isNotEmpty, reason: 'у статьи «${a.title}» нет идентификатора');
      expect(ids.add(a.id), isTrue, reason: 'идентификатор ${a.id} повторяется');
      expect(a.lead, isNotEmpty, reason: 'статья «${a.title}» не отвечает одной фразой');
      expect(a.title, isNotEmpty);
    }
  });

  test('экраны со значком «?» находят свою статью', () {
    // Имена те же, что переданы в EtHelpButton на экранах. Переименовали статью — упадёт здесь,
    // а не молча исчезнет кнопка у фермера.
    for (final id in ['legal', 'bank', 'documents', 'storefront', 'animals', 'lots', 'orders', 'kassa']) {
      expect(helpArticle(id), isNotNull, reason: 'нет статьи для экрана $id');
    }
    expect(helpArticle('такого-экрана-нет'), isNull);
  });

  group('поиск', () {
    test('пустой запрос отдаёт всё', () {
      expect(searchHelp('   ').length, helpArticles.length);
    });

    test('«счет» без ё находит статью про счёт', () {
      final found = searchHelp('счет');
      expect(found.map((a) => a.id), contains('bank'));
    });

    test('ищет по словам, которыми спрашивают, а не по заголовку', () {
      expect(searchHelp('куда платят').map((a) => a.id), contains('bank'));
      expect(searchHelp('иин').map((a) => a.id), contains('legal'));
      expect(searchHelp('не работает').map((a) => a.id), contains('trouble'));
    });

    test('несколько слов сужают выдачу, а не расширяют', () {
      final one = searchHelp('доставка');
      final two = searchHelp('доставка цена');
      expect(two.length, lessThanOrEqualTo(one.length));
      expect(two.map((a) => a.id), contains('storefront'));
    });

    test('чепуха не находит ничего', () {
      expect(searchHelp('щщщ'), isEmpty);
    });

    // Русский склоняет и спрягает, а фермер пишет как говорит. «Закрыть смену» и «фискальный
    // чек» раньше не находили ничего — хуже этого в справке только неверный ответ.
    test('окончания не мешают', () {
      for (final q in ['фискальный чек', 'закрыть смену', 'как выбить чек', 'подключить кассу']) {
        expect(searchHelp(q).map((a) => a.id), contains('kassa'), reason: 'запрос «$q» не нашёл кассу');
      }
    });

    test('вопросительные слова не мешают и не находят всё', () {
      expect(searchHelp('где чек').map((a) => a.id), contains('kassa'));
      // «Где» в одиночку — не повод вывалить всю справку как на пустой запрос.
      expect(searchHelp('где').length, lessThan(helpArticles.length));
    });

    test('склейка по началу не притягивает лишнее', () {
      // Четыре общие буквы нужны именно с пятибуквенного слова, иначе «а» находило бы всё.
      expect(searchHelp('абвгдежз'), isEmpty);
      expect(searchHelp('щщщщщ'), isEmpty);
    });
  });
}
