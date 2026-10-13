import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:et_core/et_core.dart';

/// «Корзина» - what this buyer has picked and not yet ordered.
///
/// The same record the website writes (clients/{uid}/cart), so a cart filled on a phone is there
/// on the site and back again. Nothing in it is money: createOrder prices every order from the
/// lot and the farm's storefront when it is actually placed.
class CartRepo {
  CartRepo({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _cart(String uid) =>
      _db.collection(Paths.clients).doc(uid).collection(Paths.cart);

  Stream<List<CartItem>> watch(String uid) => _cart(uid).snapshots().map(
        (snap) => snap.docs.map((d) => CartItem.fromMap(d.id, d.data())).toList()
          ..sort((a, b) => (b.addedAt ?? DateTime(0)).compareTo(a.addedAt ?? DateTime(0))),
      );

  Stream<int> count(String uid) => _cart(uid).snapshots().map((snap) => snap.size);

  Future<List<CartItem>> read(String uid) async {
    final snap = await _cart(uid).get();
    return snap.docs.map((d) => CartItem.fromMap(d.id, d.data())).toList();
  }

  /// One entry per carcass and format - picking the same half twice updates it rather than
  /// doubling it, which is also what the website does with the same id.
  Future<void> add(String uid, CartItem item) =>
      _cart(uid).doc(CartItem.idFor(item.lotId, item.format)).set({
        ...item.toMap(),
        'addedAt': FieldValue.serverTimestamp(),
      });

  Future<void> remove(String uid, String itemId) => _cart(uid).doc(itemId).delete();

  /// Empties the cart, or just the lines that turned into orders.
  Future<void> clear(String uid, {List<String>? ids}) async {
    final list = ids ?? (await read(uid)).map((i) => i.id).toList();
    if (list.isEmpty) return;
    final batch = _db.batch();
    for (final id in list) {
      batch.delete(_cart(uid).doc(id));
    }
    await batch.commit();
  }
}

/// A cart line read back against the world as it is now: the lot, the farm, a fresh price - and
/// what is wrong with it, if anything.
class CartLine {
  const CartLine({required this.item, this.lot, this.farm, this.problem, this.quote});

  final CartItem item;
  final Lot? lot;
  final Partner? farm;

  /// Why this line cannot be ordered right now, in the words the buyer needs.
  final String? problem;
  final Quote? quote;

  int get amount => quote?.total ?? item.amount;
  bool get ready => problem == null;
}

/// Re-checks every line of the cart. A half someone else booked meanwhile, a farm that went off
/// sale, a cutting the farm removed - all of it shows in the cart rather than at the checkout.
Future<List<CartLine>> loadCartLines({
  required String uid,
  required CartRepo cart,
  required CatalogueRepoLike catalogue,
  List<CartItem>? items,
}) async {
  // A screen that watches the cart already has the items - re-reading them would only let the
  // list and the badge disagree for a moment.
  final list = items ?? await cart.read(uid);
  if (list.isEmpty) return const [];

  final lines = <CartLine>[];
  for (final item in list) {
    final lot = await catalogue.lot(item.lotId);
    final farm = lot == null ? null : await catalogue.partner(lot.partnerId);
    String? problem;
    Quote? q;
    if (lot == null) {
      problem = 'Туша снята с продажи';
    } else if (farm == null || !farm.sells) {
      problem = 'Хозяйство сейчас не продаёт';
    } else if (!(formatsOf(lot)[item.format]?.available ?? false)) {
      problem = 'Эту часть туши уже забронировали';
    } else {
      q = quote(
        lot,
        farm.storefront,
        format: item.format,
        cuttingId: item.cuttingId,
        deliveryId: item.deliveryId,
      );
    }
    lines.add(CartLine(item: item, lot: lot, farm: farm, problem: problem, quote: q));
  }
  return lines;
}

/// What [loadCartLines] needs of the catalogue - so it can be handed a stub in a test.
abstract class CatalogueRepoLike {
  Future<Lot?> lot(String id);
  Future<Partner?> partner(String id);
}
