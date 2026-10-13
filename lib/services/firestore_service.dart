import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:et_data/et_data.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../models/user_profile.dart';
import '../models/animal.dart';
import '../models/lot.dart';
import '../models/delivery_step.dart';

/// Service for Firestore CRUD operations.
///
/// The parts that the security rules judge - registering a farm, its private records, its
/// documents - now go through [FarmRepo] in the shared package, so this app and the website
/// write the same shape. The rest is still this app's own and is being moved across screen by
/// screen.
class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FarmRepo _farms = FarmRepo();

  /// Reads a document, retrying with backoff on transient Firestore errors
  /// (e.g. `unavailable` right after sign-in) instead of letting them crash
  /// whatever's awaiting this on the first hiccup.
  Future<DocumentSnapshot<Map<String, dynamic>>> _getWithRetry(
    DocumentReference<Map<String, dynamic>> ref,
  ) async {
    const delays = [Duration(milliseconds: 400), Duration(seconds: 1)];
    for (final delay in delays) {
      try {
        return await ref.get();
      } on FirebaseException {
        await Future.delayed(delay);
      }
    }
    return ref.get();
  }

  // ─── User Profile ───────────────────────────────────────────

  /// Registers a farm: the public profile with the platform's own fields at zero, and the
  /// ИИН/БИН filed in the farm's PRIVATE record.
  ///
  /// The public profile is readable by every buyer of a checked farm, so an identity number must
  /// never sit on it - this app used to write it there. And nothing the platform decides
  /// (status, rating, deals, balances) is ever sent again afterwards: firestore.rules refuses
  /// it, which is what stops a farm from registering a second time and resetting its own review.
  Future<void> registerFarm({
    required String uid,
    required String phone,
    required String displayName,
    String? city,
    String? iin,
  }) async {
    final existing = await _getWithRetry(_db.collection('partners').doc(uid));
    if (!existing.exists) {
      await _farms.register(uid: uid, phone: phone, displayName: displayName, city: city);
    } else {
      // Already registered - this is the same farm coming back, so only what it may change.
      await _farms.saveProfile(uid, displayName: displayName, city: city);
    }
    if (iin != null && iin.isNotEmpty) {
      await _farms.saveIin(uid, iin);
    }
  }

  /// Ensures a profile exists for the given UID in the partners collection.
  Future<void> ensureProfileExists(String uid, String? phoneNumber) async {
    final doc = await _getWithRetry(_db.collection('partners').doc(uid));
    if (!doc.exists) {
      await _farms.register(
        uid: uid,
        phone: phoneNumber ?? '',
        displayName: 'Партнер',
      );
    }
  }

  /// Fetches a user profile by UID. Returns null if not found.
  Future<UserProfile?> getUserProfile(String uid) async {
    final doc = await _db.collection('partners').doc(uid).get();
    if (!doc.exists || doc.data() == null) return null;
    return UserProfile.fromMap(doc.data()!);
  }

  /// Updates specific fields of a user profile.
  Future<void> updateUserProfile(String uid, Map<String, dynamic> data) async {
    await _db.collection('partners').doc(uid).update(data);
  }

  /// Stream of user profile changes (real-time).
  Stream<UserProfile?> userProfileStream(String uid) {
    return _db.collection('partners').doc(uid).snapshots().map((doc) {
      if (!doc.exists) return null;
      final data = doc.data();
      if (data == null) return null;
      return UserProfile.fromMap(data);
    });
  }

  /// Uploads an image to Firebase Storage and returns the download URL.
  Future<String> uploadImage(String path, File file) async {
    final ref = FirebaseStorage.instance.ref().child(path);
    await ref.putFile(file);
    return await ref.getDownloadURL();
  }

  // ─── Animals (ET_partners writes, ET_side_client reads) ─────

  /// Adds a new animal document. Returns the generated ID.
  Future<String> addAnimal(Animal animal) async {
    final docRef = await _db.collection('animals').add(animal.toMap());
    return docRef.id;
  }

  /// Gets all animals for a specific partner.
  Stream<List<Animal>> getAnimals(String partnerId) {
    return _db
        .collection('animals')
        .where('partnerId', isEqualTo: partnerId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Animal.fromMap(doc.id, doc.data()))
            .toList());
  }

  /// Fetches specific animals by their IDs.
  Future<List<Animal>> getAnimalsByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    
    List<Animal> animals = [];
    // Firestore 'in' query supports up to 10 items.
    for (int i = 0; i < ids.length; i += 10) {
      final chunk = ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);
      final snapshot = await _db
          .collection('animals')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      animals.addAll(snapshot.docs.map((doc) => Animal.fromMap(doc.id, doc.data())));
    }
    return animals;
  }

  /// Gets all active animals (for client market screen).
  Stream<List<Animal>> getMarketAnimals() {
    return _db
        .collection('animals')
        .where('status', isEqualTo: 'active')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => Animal.fromMap(doc.id, doc.data()))
            .toList());
  }

  /// Updates an animal document.
  Future<void> updateAnimal(String id, Map<String, dynamic> data) async {
    await _db.collection('animals').doc(id).update(data);
  }

  /// Deletes an animal document.
  Future<void> deleteAnimal(String id) async {
    await _db.collection('animals').doc(id).delete();
  }

  // ─── Lots ────────────────────────────────────────────────────

  /// Creates a new lot and returns its ID.
  Future<String> createLot(Lot lot) async {
    final docRef = await _db.collection('lots').add(lot.toMap());
    // Automatically initialize delivery chain
    await initializeLotTraceability(docRef.id);
    return docRef.id;
  }

  /// Stream of all lots for a given partner.
  Stream<List<Lot>> getLots(String partnerId) {
    return _db
        .collection('lots')
        .where('partnerId', isEqualTo: partnerId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((doc) => Lot.fromMap(doc.id, doc.data())).toList());
  }

  /// Updates a lot document.
  Future<void> updateLot(String id, Map<String, dynamic> data) async {
    await _db.collection('lots').doc(id).update(data);
  }

  /// Deletes a lot document.
  Future<void> deleteLot(String id) async {
    await _db.collection('lots').doc(id).delete();
  }

  // ─── Traceability (Delivery Steps) ──────────────────────────

  /// Initializes a default delivery chain for a lot.
  Future<void> initializeLotTraceability(String lotId) async {
    final steps = DeliveryStep.defaultChain(lotId);
    final batch = _db.batch();
    
    for (var step in steps) {
      final docRef = _db.collection('lots').doc(lotId).collection('deliveries').doc(step.id);
      batch.set(docRef, step.toMap());
    }
    
    await batch.commit();
  }

  /// Initializes delivery steps ONLY if none exist yet (idempotent).
  /// Call this when publishing a lot (draft → open).
  Future<void> initDeliveryStepsIfEmpty(String lotId) async {
    final existing = await _db
        .collection('lots')
        .doc(lotId)
        .collection('deliveries')
        .limit(1)
        .get();
    if (existing.docs.isEmpty) {
      await initializeLotTraceability(lotId);
    }
  }

  /// Saves a media URL to a specific delivery step.
  Future<void> saveStepMedia(String lotId, String stepId, String mediaUrl) async {
    await _db
        .collection('lots')
        .doc(lotId)
        .collection('deliveries')
        .doc(stepId)
        .update({'mediaUrl': mediaUrl});
  }


  /// Stream of delivery steps for a specific lot.
  Stream<List<DeliveryStep>> getDeliverySteps(String lotId) {
    return _db
        .collection('lots')
        .doc(lotId)
        .collection('deliveries')
        .snapshots()
        .map((snap) => snap.docs
            .map((doc) => DeliveryStep.fromMap(doc.id, doc.data()))
            .toList());
  }

  /// Updates a specific delivery step.
  Future<void> updateDeliveryStep(DeliveryStep step) async {
    await _db
        .collection('lots')
        .doc(step.lotId)
        .collection('deliveries')
        .doc(step.id)
        .update(step.toMap());
  }
}

