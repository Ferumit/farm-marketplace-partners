import 'dart:io';

import 'package:et_core/et_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

/// Files: the animal on video, the meat, the scale, a vet certificate, the buyer's evidence.
///
/// Every limit here is the same one storage.rules enforces. Checking it on the phone as well is
/// not duplication for its own sake - it means a farmer on village mobile data is told "файл
/// больше 150 МБ" before spending ten minutes uploading it, instead of after.
class Uploads {
  Uploads({FirebaseStorage? storage}) : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  static const _videoLimitMb = 150;
  static const _imageLimitMb = 15;
  static const _docLimitMb = 20;
  static const _evidenceLimitMb = 50;

  static const _types = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'pdf': 'application/pdf',
  };

  static String _ext(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return 'jpg';
    final ext = path.substring(dot + 1).toLowerCase();
    return ext.length > 5 ? 'jpg' : ext;
  }

  static String contentTypeOf(String path) => _types[_ext(path)] ?? 'application/octet-stream';

  /// photo | video | doc - what an order's step may carry, named as the server names it.
  static String kindOf(String path) {
    final type = contentTypeOf(path);
    if (type.startsWith('video/')) return 'video';
    if (type.startsWith('image/')) return 'photo';
    if (type == 'application/pdf') return 'doc';
    return 'other';
  }

  static int _limitFor(String kind) => switch (kind) {
        'video' => _videoLimitMb,
        'doc' => _docLimitMb,
        _ => _imageLimitMb,
      };

  Future<String> _put(
    String path,
    File file,
    String contentType,
    void Function(double)? onProgress,
  ) async {
    final ref = _storage.ref(path);
    final task = ref.putFile(file, SettableMetadata(contentType: contentType));
    if (onProgress != null) {
      task.snapshotEvents.listen((snap) {
        if (snap.totalBytes > 0) onProgress(snap.bytesTransferred / snap.totalBytes);
      });
    }
    await task;
    return ref.getDownloadURL();
  }

  /// A file for one of the order's steps, into the farm's own folder for that order. The server
  /// accepts nothing else: a link from anywhere but here is refused (isOwnFile).
  Future<StepFile> orderFile({
    required String partnerId,
    required String orderId,
    required File file,
    void Function(double)? onProgress,
  }) async {
    final kind = kindOf(file.path);
    if (kind == 'other') throw const UploadRefused('Подойдёт фото, видео или PDF.');
    final limit = _limitFor(kind);
    await _checkSize(file, limit);
    final name = '${DateTime.now().millisecondsSinceEpoch}.${_ext(file.path)}';
    final url = await _put(
      Paths.orderFile(partnerId, orderId, name),
      file,
      contentTypeOf(file.path),
      onProgress,
    );
    return StepFile(url: url, kind: kind, name: _shortName(file.path));
  }

  /// The buyer's photo or video of what is wrong, for a dispute.
  Future<String> disputeFile({
    required String uid,
    required String orderId,
    required File file,
    void Function(double)? onProgress,
  }) async {
    final kind = kindOf(file.path);
    if (kind != 'photo' && kind != 'video') throw const UploadRefused('Подойдёт фото или видео.');
    await _checkSize(file, _evidenceLimitMb);
    final name = '${DateTime.now().millisecondsSinceEpoch}.${_ext(file.path)}';
    return _put(
      Paths.disputeFile(uid, orderId, name),
      file,
      contentTypeOf(file.path),
      onProgress,
    );
  }

  /// A scan of a document - a veterinary certificate on an animal, or one of the farm's own.
  Future<String> documentFile({
    required String path,
    required File file,
    void Function(double)? onProgress,
  }) async {
    final kind = kindOf(file.path);
    if (kind != 'photo' && kind != 'doc') {
      throw const UploadRefused('Документ загружается фотографией или PDF.');
    }
    await _checkSize(file, _docLimitMb);
    return _put(path, file, contentTypeOf(file.path), onProgress);
  }

  /// Anything the farm shows on its storefront: the slaughterhouse video, a lot's photo.
  Future<String> media({
    required String path,
    required File file,
    void Function(double)? onProgress,
  }) async {
    final kind = kindOf(file.path);
    await _checkSize(file, _limitFor(kind));
    return _put(path, file, contentTypeOf(file.path), onProgress);
  }

  Future<void> _checkSize(File file, int limitMb) async {
    final bytes = await file.length();
    if (bytes > limitMb * 1024 * 1024) {
      throw UploadRefused('Файл больше $limitMb МБ — снимите покороче или сожмите.');
    }
  }

  static String _shortName(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    final name = slash < 0 ? path : path.substring(slash + 1);
    return name.length > 120 ? name.substring(name.length - 120) : name;
  }
}

/// A file the platform will not take, said in words the person can act on.
class UploadRefused implements Exception {
  const UploadRefused(this.message);
  final String message;

  @override
  String toString() => message;
}
