import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:et_core/et_core.dart';

/// Notifications, and the device that should be woken for them.
///
/// The documents are written by the server inside the transaction of the event they announce, so
/// an app can only read them and mark its own read. The push token lives beside the person it
/// belongs to (clients/{uid}/devices or partners/{uid}/devices) so a sent-and-failed push can be
/// cleaned up later, and so signing out can remove just this phone.
class NotificationsRepo {
  NotificationsRepo({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const _shown = 30;

  Stream<List<AppNotification>> stream(String uid) => _db
      .collection(Paths.notifications)
      .where('uid', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(_shown)
      .snapshots()
      .map((snap) => snap.docs
          .map((d) => AppNotification.fromMap(d.id, d.data()))
          .toList());

  Stream<int> unreadCount(String uid) =>
      stream(uid).map((list) => list.where((n) => !n.read).length);

  /// Marking read is a convenience, not an operation: a refused or offline write changes nothing
  /// the person needs.
  Future<void> markRead(String id) async {
    try {
      await _db.collection(Paths.notifications).doc(id).update({
        'read': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Offline, or someone else's notification - either way, not worth a message on screen.
    }
  }

  Future<void> markAllRead(String uid) async {
    final snap = await _db
        .collection(Paths.notifications)
        .where('uid', isEqualTo: uid)
        .where('read', isEqualTo: false)
        .limit(_shown)
        .get();
    if (snap.docs.isEmpty) return;
    final batch = _db.batch();
    for (final doc in snap.docs) {
      batch.update(doc.reference, {'read': true, 'readAt': FieldValue.serverTimestamp()});
    }
    await batch.commit();
  }

  /// Registers this phone for push. `role` picks the record: a farm's devices sit on the farm.
  Future<void> registerDevice({
    required String uid,
    required String role,
    required String token,
    String platform = 'android',
  }) async {
    final owner = role == 'partner' ? Paths.partners : Paths.clients;
    await _db.collection(owner).doc(uid).collection(Paths.devices).doc(token).set({
      'token': token,
      'platform': platform,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Signing out takes this phone off the list - otherwise the next person to hold it gets
  /// someone else's orders in their notification shade.
  Future<void> forgetDevice({
    required String uid,
    required String role,
    required String token,
  }) async {
    final owner = role == 'partner' ? Paths.partners : Paths.clients;
    try {
      await _db.collection(owner).doc(uid).collection(Paths.devices).doc(token).delete();
    } catch (_) {
      // Already gone, or no network at sign-out; the server drops dead tokens when a push fails.
    }
  }
}
