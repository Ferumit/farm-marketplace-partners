import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:et_core/et_core.dart';

/// Совместная покупка: 2-5 people splitting one carcass.
///
/// Everything is written by the functions (createGroupBuy / joinGroupBuy / leaveGroupBuy) - the
/// join that fills the last place is what places the order for everyone. This only reads.
class GroupBuysRepo {
  GroupBuysRepo({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Stream<GroupBuy?> watch(String groupId) => _db
      .collection(Paths.groupBuys)
      .doc(groupId)
      .snapshots()
      .map((doc) => doc.exists ? GroupBuy.fromMap(doc.id, doc.data() ?? const {}) : null);

  Future<GroupBuy?> read(String groupId) async {
    final doc = await _db.collection(Paths.groupBuys).doc(groupId).get();
    return doc.exists ? GroupBuy.fromMap(doc.id, doc.data() ?? const {}) : null;
  }

  /// Every gathering this person is in, newest first.
  Stream<List<GroupBuy>> mine(String uid) => _db
      .collection(Paths.groupBuys)
      .where('memberUids', arrayContains: uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map((d) => GroupBuy.fromMap(d.id, d.data())).toList());

  /// Gatherings still filling for one carcass - the way into someone else's покупка from inside
  /// the app, where a link would only open the website. Equality filters only, so it needs no
  /// index of its own; there are never more than a handful per lot.
  Stream<List<GroupBuy>> openForLot(String lotId) => _db
      .collection(Paths.groupBuys)
      .where('lotId', isEqualTo: lotId)
      .where('status', isEqualTo: 'open')
      .snapshots()
      .map((snap) => snap.docs.map((d) => GroupBuy.fromMap(d.id, d.data())).toList()
        ..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0))));

  /// The delivery address and the organiser's phone. The group itself is readable by anyone
  /// holding the link, so the contact details live where only the people in it can read them.
  Future<Map<String, dynamic>?> contact(String groupId) async {
    try {
      final doc = await _db
          .collection(Paths.groupBuys)
          .doc(groupId)
          .collection(Paths.private)
          .doc('contact')
          .get();
      return doc.exists ? doc.data() : null;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return null;
      rethrow;
    }
  }

  /// The link that invites someone into this gathering - the website's page, which opens for
  /// anyone and asks them to sign in only when they join.
  static String linkFor(String groupId) => groupLink(groupId);
}
