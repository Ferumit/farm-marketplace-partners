/// Money and the Russian words around it.
///
/// Every amount on the platform is an INTEGER NUMBER OF TENGE - not tiyn, not a double. The
/// server states this once (functions/index.js) and the data already lives in that shape; a
/// silent switch to minor units is the classic way to ship an order that costs a hundred times
/// too much, so the apps keep the same convention and convert only when printing.
library;

/// "232 500 ₸" - grouped with a non-breaking space, so the amount never wraps mid-number.
String formatTenge(num? amount) {
  final value = (amount ?? 0).round();
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return '${value < 0 ? '−' : ''}$buffer ₸';
}

/// What someone typed into a price field, as whole tenge - or null if it is not a price.
///
/// People paste amounts as they see them: «15 000», «15 000 ₸», «15000,00». The spaces may be
/// ordinary or non-breaking (formatTenge writes the latter), so both go. Negative is not a price.
int? parseTenge(String? raw) {
  final cleaned = (raw ?? '')
      .replaceAll(RegExp(r'[\s\u00a0₸]'), '')
      .replaceAll(',', '.');
  if (cleaned.isEmpty) return null;
  final value = double.tryParse(cleaned);
  if (value == null || value.isNaN || value.isInfinite || value < 0) return null;
  return value.round();
}

/// Russian needs three forms: 1 доля, 2 доли, 5 долей.
String pluralRu(int n, String one, String few, String many) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}

/// "66,2" - a decimal comma, because a dot reads as a thousands separator here.
String kgText(num? kg) {
  if (kg == null) return '';
  final rounded = (kg * 10).round() / 10;
  final text = rounded == rounded.roundToDouble()
      ? rounded.round().toString()
      : rounded.toStringAsFixed(1);
  return text.replaceAll('.', ',');
}

/// "~65 кг" - the weight of a carcass before the control weighing is always approximate.
String weightLabel(num? kg) => kg == null || kg == 0 ? '' : '~${kgText(kg)} кг';
