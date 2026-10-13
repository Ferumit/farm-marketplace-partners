/// The shared model of the ET platform.
///
/// Both apps (ET for buyers, ET Partners for farms) speak through this package, and the website
/// mirrors the same rules in js/carcass.js and js/order-status.js. The server is still the only
/// authority on prices and on who may move an order - everything here exists so that a person is
/// never shown one number and charged another.
library;

export 'src/carcass.dart';
export 'src/farm.dart';
export 'src/help.dart';
export 'src/links.dart';
export 'src/money.dart';
export 'src/order_flow.dart';
export 'src/paths.dart';
export 'src/values.dart';
export 'src/when.dart';
export 'src/models/animal.dart';
export 'src/models/extras.dart';
export 'src/models/lot.dart';
export 'src/models/order.dart';
export 'src/models/partner.dart';
