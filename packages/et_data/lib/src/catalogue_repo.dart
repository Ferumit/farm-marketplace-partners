import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:et_core/et_core.dart';

import 'cart_repo.dart';

/// What a buyer browses: carcasses on sale, the farms behind them, and the animals in each lot.
///
/// Only a farm the platform has checked sells. The server enforces that in createOrder; the
/// catalogue applies the same rule to what it shows, or a buyer would configure an order that
/// cannot be placed.
class CatalogueRepo implements CatalogueRepoLike {
  CatalogueRepo({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const _sellingStatuses = ['verified', 'active'];
  static const _visibleLotStatuses = ['open', 'fully_booked'];

  /// The catalogue in one read: lots that are on sale, with only the checked farms kept.
  Future<CatalogueSnapshot> load() async {
    final partnersSnap = await _db
        .collection(Paths.partners)
        .where('status', whereIn: _sellingStatuses)
        .get();
    final partners = {
      for (final doc in partnersSnap.docs) doc.id: Partner.fromMap(doc.id, doc.data()),
    };

    final lotsSnap = await _db
        .collection(Paths.lots)
        .where('status', whereIn: _visibleLotStatuses)
        .get();
    final lots = lotsSnap.docs
        .map((d) => Lot.fromMap(d.id, d.data()))
        .where((lot) => partners.containsKey(lot.partnerId))
        .toList()
      ..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));

    final animals = await animalsByIds(lots.expand((l) => l.animalIds).toList());
    return CatalogueSnapshot(lots: lots, partners: partners, animals: animals);
  }

  @override
  Future<Lot?> lot(String id) async {
    final doc = await _db.collection(Paths.lots).doc(id).get();
    return doc.exists ? Lot.fromMap(doc.id, doc.data() ?? const {}) : null;
  }

  Stream<Lot?> watchLot(String id) => _db.collection(Paths.lots).doc(id).snapshots().map(
        (doc) => doc.exists ? Lot.fromMap(doc.id, doc.data() ?? const {}) : null,
      );

  /// A farm that is not checked is readable only by itself and staff, so for everyone else the
  /// read is refused rather than empty. That is an answer, not a failure: the farm exists and
  /// does not sell.
  @override
  Future<Partner?> partner(String id) async {
    try {
      final doc = await _db.collection(Paths.partners).doc(id).get();
      return doc.exists ? Partner.fromMap(doc.id, doc.data() ?? const {}) : null;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return null;
      rethrow;
    }
  }

  Future<List<Lot>> lotsOf(String partnerId) async {
    final snap = await _db
        .collection(Paths.lots)
        .where('partnerId', isEqualTo: partnerId)
        .where('status', whereIn: _visibleLotStatuses)
        .get();
    return snap.docs.map((d) => Lot.fromMap(d.id, d.data())).toList();
  }

  /// Firestore takes at most 30 ids per `whereIn`, and a lot list can ask for more.
  Future<Map<String, Animal>> animalsByIds(List<String> ids) async {
    final unique = ids.toSet().toList();
    final out = <String, Animal>{};
    for (var i = 0; i < unique.length; i += 30) {
      final chunk = unique.sublist(i, (i + 30).clamp(0, unique.length));
      if (chunk.isEmpty) break;
      final snap = await _db
          .collection(Paths.animals)
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      for (final doc in snap.docs) {
        out[doc.id] = Animal.fromMap(doc.id, doc.data());
      }
    }
    return out;
  }

  /// A farm's published reviews, newest first.
  Future<List<Review>> reviewsOf(String partnerId) async {
    final snap = await _db
        .collection(Paths.reviews)
        .where('partnerId', isEqualTo: partnerId)
        .where('status', isEqualTo: 'published')
        .orderBy('createdAt', descending: true)
        .get();
    return snap.docs.map((d) => Review.fromMap(d.id, d.data())).toList();
  }

  /// This buyer's review of one order, whatever its moderation status - or null.
  Future<Review?> reviewOfOrder(String orderId) async {
    try {
      final doc = await _db.collection(Paths.reviews).doc(orderId).get();
      return doc.exists ? Review.fromMap(doc.id, doc.data() ?? const {}) : null;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return null;
      rethrow;
    }
  }
}

/// One consistent picture of the catalogue: the lots, who sells them and what walks in them.
class CatalogueSnapshot {
  const CatalogueSnapshot({
    required this.lots,
    required this.partners,
    required this.animals,
  });

  final List<Lot> lots;
  final Map<String, Partner> partners;
  final Map<String, Animal> animals;

  Partner? farmOf(Lot lot) => partners[lot.partnerId];

  /// Newer lots carry their own meatType; older ones only have it through their first animal.
  String meatTypeOf(Lot lot) {
    if (lot.meatType != null && lot.meatType!.isNotEmpty) return lot.meatType!;
    for (final id in lot.animalIds) {
      final animal = animals[id];
      if (animal != null) return animal.type;
    }
    return 'cattle';
  }

  Animal? firstAnimalOf(Lot lot) {
    for (final id in lot.animalIds) {
      final animal = animals[id];
      if (animal != null) return animal;
    }
    return null;
  }
}
