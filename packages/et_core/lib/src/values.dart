/// Reading Firestore's loosely typed values without depending on Firestore.
///
/// This package is plain Dart on purpose: its arithmetic is the part that must be testable in
/// milliseconds and portable to anything. Firestore still hands documents over as
/// `Map<String, dynamic>` with `Timestamp` objects inside, so the conversions live here, done by
/// duck typing (`toDate()`), and every model goes through them.
library;

int asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? (double.tryParse(value)?.round() ?? 0);
  return 0;
}

double asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

String asText(dynamic value) => value == null ? '' : value.toString();

String? asTextOrNull(dynamic value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

bool asBool(dynamic value) => value == true;

List<String> asTextList(dynamic value) =>
    value is List ? value.map((e) => e.toString()).toList() : const [];

List<Map<String, dynamic>> asMapList(dynamic value) => value is List
    ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

Map<String, dynamic> asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

/// A Firestore `Timestamp`, a `DateTime`, milliseconds or an ISO string - or null.
DateTime? asTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  try {
    final converted = (value as dynamic).toDate();
    if (converted is DateTime) return converted;
  } catch (_) {
    // Not a Timestamp; fall through to the seconds shape the web SDK sometimes leaves behind.
  }
  if (value is Map && value['seconds'] is num) {
    return DateTime.fromMillisecondsSinceEpoch((value['seconds'] as num).round() * 1000);
  }
  return null;
}
