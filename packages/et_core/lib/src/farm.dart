/// What a farm files about itself, and how the platform's verdicts read.
///
/// The same wording the website's cabinet uses, so a farm that files a certificate on the phone
/// and looks at it in the browser sees one thing, not two. The kinds themselves are the server's:
/// `ses` and `vet_control` are what reviewDocument counts towards the certified badge.
library;

import 'dart:math';

import 'models/animal.dart';

/// An id for a new cutting option or delivery city. Orders name the option they were priced
/// with, so an id has to outlive an edit of the row above it - the website generates them the
/// same way.
String newOptionId() {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(8, (_) => alphabet[_random.nextInt(alphabet.length)]).join();
}

final _random = Random();

/// The farm's own papers. Animals have their own kinds (vet_certificate, vet_passport).
const farmDocKinds = <({String id, String label, String short})>[
  (
    id: 'ses',
    label: 'Санитарно-эпидемиологическое заключение (СЭС)',
    short: 'СЭС',
  ),
  (
    id: 'vet_control',
    label: 'Ветеринарный контроль (ветеринарно-санитарное заключение)',
    short: 'Ветконтроль',
  ),
  (
    id: 'other',
    label: 'Другой документ хозяйства',
    short: 'Другой документ',
  ),
];

/// The two the platform waits for before it marks a farm as certified - CERTIFYING_KINDS in
/// functions/index.js decides this, and the checklist only tells the farm what it is waiting on.
const certifyingKinds = ['ses', 'vet_control'];

String farmDocLabel(String kind) {
  for (final k in farmDocKinds) {
    if (k.id == kind) return k.label;
  }
  return 'Документ хозяйства';
}

String farmDocShort(String kind) {
  for (final k in farmDocKinds) {
    if (k.id == kind) return k.short;
  }
  return 'Документ';
}

const docStatusLabel = {
  'pending': 'На проверке',
  'approved': 'Принят',
  'rejected': 'Отклонён',
};

const docStatusTone = {
  'pending': 'waiting',
  'approved': 'active',
  'rejected': 'danger',
};

/// The worst verdict across one animal's paperwork - what the farm needs to see in a list, and
/// the same summary the website shows next to each head.
({String state, String label, String tone}) documentsSummary(List<FarmDocument> documents) {
  if (documents.isEmpty) {
    return (state: 'none', label: 'Нет документов', tone: 'off');
  }
  if (documents.any((d) => d.status == 'rejected')) {
    return (state: 'rejected', label: 'Есть отклонённый', tone: 'danger');
  }
  if (documents.any((d) => d.status == 'pending')) {
    return (state: 'pending', label: 'На проверке', tone: 'waiting');
  }
  return (state: 'approved', label: 'Документы подтверждены', tone: 'active');
}

/// Legal form of the farm. Part of what review checks, so it lives in the private record.
const legalForms = <({String id, String label})>[
  (id: 'kh', label: 'Крестьянское хозяйство (КХ)'),
  (id: 'fh', label: 'Фермерское хозяйство (ФХ)'),
  (id: 'ip', label: 'Индивидуальный предприниматель (ИП)'),
  (id: 'too', label: 'Товарищество (ТОО)'),
];

String legalFormLabel(String? id) {
  for (final form in legalForms) {
    if (form.id == id) return form.label;
  }
  return '';
}

/// pending_review | verified | active | rejected
const farmStatusLabel = {
  'pending_review': 'На проверке',
  'verified': 'Проверено',
  'active': 'Проверено',
  'rejected': 'Не допущено',
};

const farmStatusTone = {
  'pending_review': 'waiting',
  'verified': 'active',
  'active': 'active',
  'rejected': 'danger',
};

/// Whether this farm may sell right now. The rules say the same thing about its lots, so a farm
/// that reads «на проверке» here will not see its lots in the catalogue either.
bool farmSells(String status) => status == 'verified' || status == 'active';

/// What stands between the farm and buyers, in the order it has to be done.
///
/// Both surfaces show it because a farm that does not know why it is invisible blames the
/// platform: `done` is finished, `wait` is filed and waiting for a moderator, `todo` is the
/// farm's move.
List<({String title, String note, String state, String go})> farmChecklist({
  required String status,
  required bool certified,
  required Iterable<String> approvedKinds,
  required Iterable<String> filedKinds,
  required bool hasLegal,
  required bool hasIin,
  required bool hasStorefront,
  required bool hasAnimals,
  required bool hasLots,
  bool hasKassa = false,
}) {
  final filed = filedKinds.toSet();
  final approved = approvedKinds.toSet();
  final certState = certified
      ? 'done'
      : certifyingKinds.every(filed.contains)
          ? 'wait'
          : 'todo';

  return [
    (
      title: 'Хозяйство проверено',
      go: '',
      note: switch (status) {
        'rejected' => 'Администратор не допустил хозяйство к продажам',
        'pending_review' => 'Заявка у администратора',
        _ => 'Лоты видны покупателям',
      },
      state: farmSells(status)
          ? 'done'
          : status == 'rejected'
              ? 'todo'
              : 'wait',
    ),
    (
      title: 'Реквизиты и ИИН/БИН',
      go: 'legal',
      note: hasLegal && hasIin ? 'Заполнены' : 'Нужны для проверки хозяйства',
      state: hasLegal && hasIin ? 'done' : 'todo',
    ),
    (
      title: 'СЭС и ветконтроль',
      go: 'documents',
      note: switch (certState) {
        'done' => 'Значок «Сертификаты» стоит на витрине',
        'wait' => 'Загружены, ждут проверки'
            '${approved.length == 1 ? ' — один уже принят' : ''}',
        _ => 'Без них не будет значка «Сертификаты»',
      },
      state: certState,
    ),
    (
      title: 'Витрина',
      go: 'storefront',
      note: hasStorefront
          ? 'Покупатели видят, как вы работаете'
          : 'Опишите хозяйство, разделку и доставку',
      state: hasStorefront ? 'done' : 'todo',
    ),
    (
      title: 'Скот',
      go: 'animals',
      note: hasAnimals ? 'Есть в списке' : 'Заведите животных — из них собираются лоты',
      state: hasAnimals ? 'done' : 'todo',
    ),
    (
      title: 'Лоты',
      go: 'lots',
      note: hasLots ? 'Есть в продаже' : 'Соберите тушу и выставьте её',
      state: hasLots ? 'done' : 'todo',
    ),
    // Касса идёт последней, но до первой продажи: без неё покупатель не получит чек, а чек при
    // расчёте с физлицом обязателен по закону. Продавец — хозяйство, поэтому и касса его.
    (
      title: 'Онлайн-касса',
      go: 'kassa',
      note: hasKassa ? 'Чеки выбиваются' : 'Без неё покупатель не получит чек',
      state: hasKassa ? 'done' : 'todo',
    ),
  ];
}
