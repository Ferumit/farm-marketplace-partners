import 'package:et_core/et_core.dart';
import 'package:test/test.dart';

/// The stamp under every notification and every step of an order.
void main() {
  final now = DateTime(2026, 9, 25, 14, 30);

  test('сегодня — только время', () {
    expect(whenText(DateTime(2026, 9, 25, 9, 5), now: now), '09:05');
    expect(whenText(DateTime(2026, 9, 25, 0, 0), now: now), '00:00');
  });

  test('вчера так и называется', () {
    expect(whenText(DateTime(2026, 9, 24, 23, 59), now: now), 'вчера, 23:59');
  });

  test('позавчера — уже дата', () {
    expect(whenText(DateTime(2026, 9, 23, 10, 0), now: now), '23.09');
  });

  test('другой год — с годом, чтобы не путать', () {
    expect(whenText(DateTime(2025, 12, 31, 10, 0), now: now), '31.12.2025');
  });

  test('«вчера» считается по календарю, а не по суткам назад', () {
    // 00:30 сегодня и 23:30 вчера разделяет час, но это разные дни.
    final night = DateTime(2026, 9, 25, 0, 30);
    expect(whenText(DateTime(2026, 9, 24, 23, 30), now: night), 'вчера, 23:30');
    expect(whenText(DateTime(2026, 9, 25, 0, 10), now: night), '00:10');
  });

  test('ничего — пусто, а не «01.01.1970»', () {
    expect(whenText(null), '');
  });
}
