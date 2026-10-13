/// Firebase for both ET apps, typed through et_core.
///
/// The split is deliberate: et_core knows the model and the arithmetic and can be tested in
/// milliseconds; this package knows where things live and how to ask the server for them. A
/// screen should need neither a collection path nor a price formula of its own.
library;

export 'src/api.dart';
export 'src/cart_repo.dart';
export 'src/catalogue_repo.dart';
export 'src/group_buys_repo.dart';
export 'src/deep_links.dart';
export 'src/farm_repo.dart';
export 'src/firebase_setup.dart';
export 'src/notifications_repo.dart';
export 'src/orders_repo.dart';
export 'src/push.dart';
export 'src/uploads.dart';
