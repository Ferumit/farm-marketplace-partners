import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:et_core/et_core.dart';

/// Reading orders. Nobody writes them from here - see EtApi.
///
/// Both sides read the same documents through the same model, so what the farm ticks off is
/// exactly what the buyer sees, without a second shape in between.
class OrdersRepo {
  OrdersRepo({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _orders => _db.collection(Paths.orders);

  FarmOrder _of(DocumentSnapshot<Map<String, dynamic>> doc) =>
      FarmOrder.fromMap(doc.id, doc.data() ?? const {});

  /// Everything this farm has to work on, newest first.
  Stream<List<FarmOrder>> forPartner(String partnerId) => _orders
      .where('partnerId', isEqualTo: partnerId)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map(_of).toList());

  /// This buyer's own orders.
  Stream<List<FarmOrder>> forBuyer(String uid) => _orders
      .where('buyerUid', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map(_of).toList());

  /// Orders of a joint purchase this person is in but did not gather: they follow the deal, the
  /// organiser decides it.
  Stream<List<FarmOrder>> sharedWith(String uid) => _orders
      .where('memberUids', arrayContains: uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.where((d) => d.data()['buyerUid'] != uid).map(_of).toList());

  Stream<FarmOrder?> watch(String orderId) =>
      _orders.doc(orderId).snapshots().map((doc) => doc.exists ? _of(doc) : null);

  Future<FarmOrder?> read(String orderId) async {
    final doc = await _orders.doc(orderId).get();
    return doc.exists ? _of(doc) : null;
  }

  /// The buyer's claim about an order, so both the tracker and the farm's card can say what was
  /// written and what the platform decided.
  Future<Map<String, dynamic>?> disputeOf(String disputeId) async {
    final doc = await _db.collection(Paths.disputes).doc(disputeId).get();
    return doc.exists ? doc.data() : null;
  }
}
