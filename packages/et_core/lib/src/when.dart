/// Dates as a person says them.
///
/// Lists of events need a short, unambiguous stamp: «14:30» for today, «вчера, 09:05», then the
/// date. Everything on the platform happens in Kazakhstan, so the phone's own clock is the right
/// one to read - the server's Almaty time and the phone's agree wherever this is used.
library;

/// «14:30» · «вчера, 09:05» · «23.09» · «23.09.2025» for another year.
String whenText(DateTime? moment, {DateTime? now}) {
  if (moment == null) return '';
  final today = now ?? DateTime.now();
  final local = moment.isUtc ? moment.toLocal() : moment;
  final time = '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';

  final startOfToday = DateTime(today.year, today.month, today.day);
  final day = DateTime(local.year, local.month, local.day);
  final daysApart = startOfToday.difference(day).inDays;

  if (daysApart == 0) return time;
  if (daysApart == 1) return 'вчера, $time';

  final date = '${local.day.toString().padLeft(2, '0')}.'
      '${local.month.toString().padLeft(2, '0')}';
  return local.year == today.year ? date : '$date.${local.year}';
}
