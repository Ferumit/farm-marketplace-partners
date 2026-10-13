import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

/// Service for uploading and managing files in Firebase Storage.
class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ImagePicker _picker = ImagePicker();

  /// Picks an image from gallery or camera.
  Future<File?> pickImage({ImageSource source = ImageSource.gallery}) async {
    final XFile? picked = await _picker.pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1920,
      maxHeight: 1920,
    );
    if (picked == null) return null;
    return File(picked.path);
  }

  /// Uploads an animal photo and returns the download URL.
  /// Files are stored at: animals/{partnerId}/{animalId}.jpg
  Future<String> uploadAnimalPhoto({
    required String partnerId,
    required String animalId,
    required File imageFile,
    void Function(double progress)? onProgress,
  }) async {
    final ref = _storage.ref('animals/$partnerId/$animalId.jpg');
    final uploadTask = ref.putFile(
      imageFile,
      SettableMetadata(contentType: 'image/jpeg'),
    );

    // Track upload progress if callback provided
    if (onProgress != null) {
      uploadTask.snapshotEvents.listen((snapshot) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        onProgress(progress);
      });
    }

    await uploadTask;
    return await ref.getDownloadURL();
  }

  /// Deletes an animal photo from Storage.
  Future<void> deleteAnimalPhoto(String partnerId, String animalId) async {
    try {
      await _storage.ref('animals/$partnerId/$animalId.jpg').delete();
    } catch (e) {
      // File may not exist — ignore silently
    }
  }

  /// Returns the download URL for an existing animal photo.
  Future<String?> getAnimalPhotoUrl(String partnerId, String animalId) async {
    try {
      return await _storage.ref('animals/$partnerId/$animalId.jpg').getDownloadURL();
    } catch (e) {
      return null;
    }
  }

  /// Uploads a veterinary document photo and returns the download URL.
  Future<String> uploadVetDocument({
    required String partnerId,
    required String documentId,
    required File imageFile,
    void Function(double progress)? onProgress,
  }) async {
    final ref = _storage.ref('vet_documents/$partnerId/$documentId.jpg');
    final uploadTask = ref.putFile(
      imageFile,
      SettableMetadata(contentType: 'image/jpeg'),
    );

    if (onProgress != null) {
      uploadTask.snapshotEvents.listen((snapshot) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        onProgress(progress);
      });
    }

    await uploadTask;
    return await ref.getDownloadURL();
  }
}
