import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:et_core/et_core.dart';

/// The farm's own record: its profile, its private papers, its livestock and its lots.
///
/// What the PLATFORM decides about a farm - status, rating, deals, balances, the certified badge,
/// the public point - is written by the server alone. This class never sends those fields back,
/// which is also why registering again cannot reset a farm to «на проверке».
class FarmRepo {
  FarmRepo({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _farm(String uid) =>
      _db.collection(Paths.partners).doc(uid);

  Stream<Partner?> watch(String uid) => _farm(uid).snapshots().map(
        (doc) => doc.exists ? Partner.fromMap(doc.id, doc.data() ?? const {}) : null,
      );

  Future<Partner?> read(String uid) async {
    final doc = await _farm(uid).get();
    return doc.exists ? Partner.fromMap(doc.id, doc.data() ?? const {}) : null;
  }

  /// Registration. Only ever a CREATE with the platform's fields at zero - the rules check every
  /// one of them. An existing farm goes through [saveProfile] instead.
  Future<void> register({
    required String uid,
    required String phone,
    required String displayName,
    String? city,
    String? regionCode,
  }) async {
    await _farm(uid).set({
      'uid': uid,
      'phone': phone,
      'role': 'partner',
      'displayName': displayName,
      'city': city,
      'regionCode': regionCode,
      'status': 'pending_review',
      'rating': 0,
      'totalDeals': 0,
      'walletBalance': 0,
      'pendingBalance': 0,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// What a farm may change about itself: how it presents, and nothing else.
  Future<void> saveProfile(
    String uid, {
    String? displayName,
    String? city,
    String? regionCode,
    String? avatarUrl,
  }) =>
      _farm(uid).update({
        if (displayName != null) 'displayName': displayName,
        if (city != null) 'city': city,
        if (regionCode != null) 'regionCode': regionCode,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
      });

  Future<void> saveStorefront(String uid, Storefront storefront) => _farm(uid).update({
        'storefront': storefront.toMap(),
        'storefrontUpdatedAt': FieldValue.serverTimestamp(),
      });

  // ---- private records -------------------------------------------------------------------
  // The ИИН/БИН, the legal details, the email and the exact point are readable by the farm and
  // by staff only. The public profile is readable by every buyer, which is why none of this may
  // ever be written there - the app used to put the ИИН on it.

  Future<Map<String, dynamic>?> readPrivate(String uid, String docId) async {
    final doc = await _farm(uid).collection(Paths.private).doc(docId).get();
    return doc.exists ? doc.data() : null;
  }

  /// The ИИН/БИН. Can be corrected while the farm is under review or rejected; after approval it
  /// is part of what was checked, so changing it goes through staff.
  Future<void> saveIin(String uid, String iin) =>
      _farm(uid).collection(Paths.private).doc(Paths.privateIdentity).set({
        'iin': iin,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> saveLegal(
    String uid, {
    required String form,
    required String legalName,
    required String address,
  }) =>
      _farm(uid).collection(Paths.private).doc(Paths.privateLegal).set({
        'form': form,
        'legalName': legalName,
        'address': address,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// Счёт, на который платформа перечислит долю хозяйства. Меняется в любой момент: банк можно
  /// сменить, и ждать ради этого новой проверки незачем.
  Future<void> saveBank(
    String uid, {
    required String iban,
    required String bic,
    required String bankName,
    required String kbe,
  }) =>
      _farm(uid).collection(Paths.private).doc(Paths.privateBank).set({
        'iban': iban,
        'bic': bic,
        'bankName': bankName,
        'kbe': kbe,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// Доступ к онлайн-кассе: им сервер выбивает фискальные чеки от имени хозяйства.
  ///
  /// Пишется в две записи, и это не прихоть. Пароль и ПИН ложатся в `kassa`, которую не читает
  /// никто из клиентов: это действующие ключи, которыми выбиваются налоговые документы под
  /// чужим БИН. Заводской номер и дата — в `kassaInfo`, её читать можно: экрану и чек-листу
  /// нужно знать, что касса подключена, и для этого секреты незачем.
  Future<void> saveKassa(
    String uid, {
    required String znm,
    required String password,
    required String pin,
  }) async {
    final private = _farm(uid).collection(Paths.private);
    await private.doc(Paths.privateKassa).set({
      'znm': znm,
      'password': password,
      'pin': pin,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await private.doc(Paths.privateKassaInfo).set({
      'znm': znm,
      'connectedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Отключить кассу. Чеки перестанут выбиваться — об этом экран предупреждает прямо.
  Future<void> removeKassa(String uid) async {
    final private = _farm(uid).collection(Paths.private);
    await private.doc(Paths.privateKassa).delete();
    await private.doc(Paths.privateKassaInfo).delete();
  }

  /// The farm's email for order notifications. Its own business - it may set or clear it at any
  /// time, review or not.
  Future<void> saveContactEmail(String uid, String? email) =>
      _farm(uid).collection(Paths.private).doc(Paths.privateContact).set({
        'email': (email == null || email.isEmpty) ? null : email,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  // ---- livestock -----------------------------------------------------------------------------

  /// Sorted here rather than by the query: Firestore drops documents that lack the field it is
  /// ordered by, and an animal written without createdAt would disappear from its own farm's
  /// list. A farm has tens of head, not thousands.
  Stream<List<Animal>> animals(String uid) => _db
      .collection(Paths.animals)
      .where('partnerId', isEqualTo: uid)
      .snapshots()
      .map((snap) => snap.docs.map((d) => Animal.fromMap(d.id, d.data())).toList()
        ..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0))));

  Future<Animal?> animal(String id) async {
    final doc = await _db.collection(Paths.animals).doc(id).get();
    return doc.exists ? Animal.fromMap(doc.id, doc.data() ?? const {}) : null;
  }

  Future<String> addAnimal(Animal animal) async {
    final ref = await _db.collection(Paths.animals).add({
      ...animal.toMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  Future<void> updateAnimal(String id, Map<String, dynamic> fields) =>
      _db.collection(Paths.animals).doc(id).update(fields);

  Future<void> deleteAnimal(String id) => _db.collection(Paths.animals).doc(id).delete();

  Stream<List<FarmDocument>> animalDocuments(String animalId) => _db
      .collection(Paths.animals)
      .doc(animalId)
      .collection(Paths.documents)
      .snapshots()
      .map((snap) => snap.docs.map((d) => FarmDocument.fromMap(d.id, d.data())).toList());

  Stream<List<FarmDocument>> farmDocuments(String uid) => _farm(uid)
      .collection(Paths.documents)
      .snapshots()
      .map((snap) => snap.docs.map((d) => FarmDocument.fromMap(d.id, d.data())).toList());

  /// Files a document for review. It is always PENDING: the rules refuse anything else, and the
  /// verdict belongs to reviewDocument alone.
  Future<void> fileDocument({
    required DocumentReference<Map<String, dynamic>> ref,
    required String kind,
    required String label,
    required String fileUrl,
    required String storagePath,
    required String contentType,
    required String fileName,
    required int size,
    required String partnerId,
    String? animalId,
  }) =>
      ref.set({
        'kind': kind,
        'label': label,
        'fileUrl': fileUrl,
        'storagePath': storagePath,
        'contentType': contentType,
        'fileName': fileName,
        'size': size,
        'status': 'pending',
        'partnerId': partnerId,
        if (animalId != null) 'animalId': animalId,
        'uploadedAt': FieldValue.serverTimestamp(),
        'reviewedAt': null,
        'reviewedBy': null,
        'reviewNote': null,
      });

  DocumentReference<Map<String, dynamic>> newAnimalDocumentRef(String animalId) =>
      _db.collection(Paths.animals).doc(animalId).collection(Paths.documents).doc();

  DocumentReference<Map<String, dynamic>> animalDocumentRef(String animalId, String documentId) =>
      _db.collection(Paths.animals).doc(animalId).collection(Paths.documents).doc(documentId);

  DocumentReference<Map<String, dynamic>> newFarmDocumentRef(String uid) =>
      _farm(uid).collection(Paths.documents).doc();

  DocumentReference<Map<String, dynamic>> farmDocumentRef(String uid, String documentId) =>
      _farm(uid).collection(Paths.documents).doc(documentId);

  /// A document nobody has reviewed yet can be withdrawn; once reviewed it stays as the record.
  Future<void> withdrawDocument(DocumentReference<Map<String, dynamic>> ref) => ref.delete();

  // ---- lots ------------------------------------------------------------------------------------

  Stream<List<Lot>> lots(String uid) => _db
      .collection(Paths.lots)
      .where('partnerId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map((d) => Lot.fromMap(d.id, d.data())).toList());

  Future<String> createLot(Lot lot) async {
    final ref = await _db.collection(Paths.lots).add({
      ...lot.toCreateMap(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  /// A lot people have booked into is frozen: its shares are money. An empty one can be edited,
  /// published, withdrawn and deleted freely - the rules draw exactly this line.
  Future<void> updateLot(String id, Map<String, dynamic> fields) =>
      _db.collection(Paths.lots).doc(id).update(fields);

  Future<void> setLotStatus(String id, String status) =>
      _db.collection(Paths.lots).doc(id).update({'status': status});

  Future<void> deleteLot(String id) => _db.collection(Paths.lots).doc(id).delete();
}
