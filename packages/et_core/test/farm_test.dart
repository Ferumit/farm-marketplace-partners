import 'package:et_core/et_core.dart';
import 'package:test/test.dart';

/// What a farm files about itself, and the arithmetic of prices typed by hand.
void main() {
  group('цена, введённая руками', () {
    test('обычное число', () => expect(parseTenge('15000'), 15000));

    test('с пробелами и знаком тенге — так её показывает сама платформа', () {
      expect(parseTenge('15 000 ₸'), 15000);
      expect(parseTenge('15 000 ₸'), 15000);
    });

    test('запятая — десятичный разделитель, тенге целые', () {
      expect(parseTenge('15000,40'), 15000);
      expect(parseTenge('15000,60'), 15001);
    });

    test('пусто — это не цена, а не ноль', () {
      expect(parseTenge(''), isNull);
      expect(parseTenge('   '), isNull);
      expect(parseTenge(null), isNull);
    });

    test('ноль — цена; отрицательное и буквы — нет', () {
      expect(parseTenge('0'), 0);
      expect(parseTenge('-100'), isNull);
      expect(parseTenge('дорого'), isNull);
    });
  });

  group('идентификатор строки витрины', () {
    test('восемь знаков и не повторяется', () {
      final ids = {for (var i = 0; i < 200; i++) newOptionId()};
      expect(ids.length, greaterThan(190));
      expect(ids.every((id) => id.length == 8), isTrue);
    });
  });

  group('бумаги на животное: худший вердикт — это и есть состояние', () {
    FarmDocument doc(String status) => FarmDocument(
          id: status,
          kind: 'vet_certificate',
          label: 'Справка',
          fileUrl: 'https://example.invalid/x.pdf',
          status: status,
        );

    test('без документов', () {
      expect(documentsSummary(const []).state, 'none');
    });

    test('один отклонённый перевешивает принятые', () {
      final summary = documentsSummary([doc('approved'), doc('rejected'), doc('pending')]);
      expect(summary.state, 'rejected');
      expect(summary.tone, 'danger');
    });

    test('ожидание перевешивает принятое', () {
      expect(documentsSummary([doc('approved'), doc('pending')]).state, 'pending');
    });

    test('всё принято', () {
      expect(documentsSummary([doc('approved'), doc('approved')]).state, 'approved');
    });
  });

  group('что осталось сделать хозяйству', () {
    List<({String title, String note, String state, String go})> check({
      String status = 'pending_review',
      bool certified = false,
      List<String> approved = const [],
      List<String> filed = const [],
      bool legal = false,
      bool iin = false,
      bool storefront = false,
      bool animals = false,
      bool lots = false,
      bool kassa = false,
    }) =>
        farmChecklist(
          status: status,
          certified: certified,
          approvedKinds: approved,
          filedKinds: filed,
          hasLegal: legal,
          hasIin: iin,
          hasStorefront: storefront,
          hasAnimals: animals,
          hasLots: lots,
          hasKassa: kassa,
        );

    String stateOf(List<({String title, String note, String state, String go})> rows, String title) =>
        rows.firstWhere((r) => r.title == title).state;

    test('новое хозяйство: проверка ждёт администратора, остальное — за хозяйством', () {
      final rows = check();
      expect(stateOf(rows, 'Хозяйство проверено'), 'wait');
      expect(stateOf(rows, 'Реквизиты и ИИН/БИН'), 'todo');
      expect(stateOf(rows, 'Витрина'), 'todo');
      expect(rows.where((r) => r.state == 'done'), isEmpty);
    });

    test('отказ — это ход хозяйства, а не ожидание', () {
      expect(stateOf(check(status: 'rejected'), 'Хозяйство проверено'), 'todo');
    });

    test('оба сертификата загружены — ждём проверки, а не «сделайте»', () {
      final rows = check(filed: ['ses', 'vet_control']);
      expect(stateOf(rows, 'СЭС и ветконтроль'), 'wait');
    });

    test('один сертификат из двух — это ещё ход хозяйства', () {
      expect(stateOf(check(filed: ['ses']), 'СЭС и ветконтроль'), 'todo');
    });

    test('значок стоит — шаг закрыт, что бы ни лежало в документах', () {
      expect(stateOf(check(certified: true), 'СЭС и ветконтроль'), 'done');
    });

    test('ИИН без реквизитов не закрывает шаг', () {
      expect(stateOf(check(iin: true), 'Реквизиты и ИИН/БИН'), 'todo');
      expect(stateOf(check(iin: true, legal: true), 'Реквизиты и ИИН/БИН'), 'done');
    });

    test('проверенное хозяйство со всем на месте: ничего не осталось', () {
      final rows = check(
        status: 'verified',
        certified: true,
        filed: ['ses', 'vet_control'],
        approved: ['ses', 'vet_control'],
        legal: true,
        iin: true,
        storefront: true,
        animals: true,
        lots: true,
        kassa: true,
      );
      expect(rows.every((r) => r.state == 'done'), isTrue);
    });

    // Касса — не украшение: без неё покупатель не получит чек, который при расчёте с физлицом
    // обязателен по закону. Поэтому она такой же шаг чек-листа, как СЭС.
    test('без кассы шаг остаётся незакрытым', () {
      expect(stateOf(check(), 'Онлайн-касса'), 'todo');
      expect(stateOf(check(kassa: true), 'Онлайн-касса'), 'done');
    });
  });

  group('хозяйство продаёт', () {
    test('только проверенное', () {
      expect(farmSells('verified'), isTrue);
      expect(farmSells('active'), isTrue);
      expect(farmSells('pending_review'), isFalse);
      expect(farmSells('rejected'), isFalse);
    });
  });

  group('животное: то, что лежит в базе', () {
    test('фото читается из imageUrl — так его пишут сайт и оба приложения', () {
      final animal = Animal.fromMap('a1', {
        'partnerId': 'farm',
        'imageUrl': 'https://example.invalid/a.jpg',
        'price': 3500,
        'region': 'Акмолинская область',
        'regionCode': 'KZ-11',
        'gender': 'female',
        'weight': 420,
      });
      expect(animal.imageUrl, 'https://example.invalid/a.jpg');
      expect(animal.pricePerKg, 3500);
      expect(animal.region, 'Акмолинская область');
      expect(animal.regionCode, 'KZ-11');
      expect(animal.gender, 'female');
      expect(animal.status, 'active');
    });

    test('и обратно — под тем же ключом', () {
      final map = Animal(id: 'a1', partnerId: 'farm', imageUrl: 'u', pricePerKg: 3000).toMap();
      expect(map['imageUrl'], 'u');
      expect(map['price'], 3000);
    });
  });
}
