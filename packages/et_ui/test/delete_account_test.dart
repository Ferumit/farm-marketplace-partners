import 'package:et_ui/et_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Экран удаления аккаунта — единственная кнопка на платформе, которая стирает человека.
///
/// Проверяется здесь, а не на устройстве, по простой причине: подтверждение набирается
/// кириллицей, а `adb shell input text` кириллицу не умеет. То, что нельзя честно проверить
/// руками, проверяется тестом.
void main() {
  Widget host(EtDeleteAccountScreen screen) => MaterialApp(
        theme: EtTheme.light(),
        home: screen,
      );

  testWidgets('кнопка спит, пока не набрано подтверждение', (tester) async {
    var called = false;
    await tester.pumpWidget(host(EtDeleteAccountScreen(
      goes: const ['Профиль'],
      stays: const ['Закрытые заказы'],
      onDelete: () async {
        called = true;
        return null;
      },
    )));

    final button = find.widgetWithText(FilledButton, 'Удалить аккаунт навсегда');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'не то слово');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(called, isFalse);
  });

  testWidgets('подтверждение принимается в любом регистре', (tester) async {
    await tester.pumpWidget(host(EtDeleteAccountScreen(
      goes: const ['Профиль'],
      stays: const ['Закрытые заказы'],
      onDelete: () async => null,
    )));

    await tester.enterText(find.byType(TextField), ' удалить ');
    await tester.pump();
    final button = find.widgetWithText(FilledButton, 'Удалить аккаунт навсегда');
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  });

  testWidgets('между кнопкой и удалением стоит вопрос, и «Назад» его закрывает', (tester) async {
    var called = false;
    await tester.pumpWidget(host(EtDeleteAccountScreen(
      goes: const ['Профиль'],
      stays: const ['Закрытые заказы'],
      onDelete: () async {
        called = true;
        return null;
      },
    )));

    await tester.enterText(find.byType(TextField), 'УДАЛИТЬ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить аккаунт навсегда'));
    await tester.pumpAndSettle();

    expect(find.text('Удалить аккаунт?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Назад'));
    await tester.pumpAndSettle();
    expect(called, isFalse);
  });

  testWidgets('отказ сервера показывается его словами, а не «ошибка»', (tester) async {
    await tester.pumpWidget(host(EtDeleteAccountScreen(
      goes: const ['Профиль'],
      stays: const ['Закрытые заказы'],
      onDelete: () async => 'Есть незакрытый заказ. Дождитесь получения.',
    )));

    await tester.enterText(find.byType(TextField), 'УДАЛИТЬ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить аккаунт навсегда'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Есть незакрытый заказ'), findsOneWidget);
  });

  testWidgets('что уйдёт и что останется — на экране до нажатия, а не после', (tester) async {
    await tester.pumpWidget(host(EtDeleteAccountScreen(
      note: 'Пока идёт заказ, удалить нельзя.',
      goes: const ['Профиль, имя и город', 'Корзина'],
      stays: const ['Закрытые заказы остаются записью о деньгах'],
      onDelete: () async => null,
    )));

    expect(find.text('Что будет удалено'), findsOneWidget);
    expect(find.text('Что останется'), findsOneWidget);
    expect(find.text('Профиль, имя и город'), findsOneWidget);
    expect(find.text('Закрытые заказы остаются записью о деньгах'), findsOneWidget);
    expect(find.textContaining('Пока идёт заказ'), findsOneWidget);
  });
}
