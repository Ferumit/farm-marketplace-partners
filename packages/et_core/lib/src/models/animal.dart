import '../values.dart';

/// A head of livestock on the farm. Its paperwork lives in the `documents` subcollection and is
/// decided by staff (reviewDocument) - a farm files documents `pending` and cannot approve them.
class Animal {
  const Animal({
    required this.id,
    required this.partnerId,
    this.type = 'cattle',
    this.breed = '',
    this.ageCategory,
    this.weight = 0,
    this.imageUrl,
    this.gender,
    this.pricePerKg = 0,
    this.region,
    this.regionCode,
    this.status = 'active',
    this.tag,
    this.createdAt,
  });

  final String id;
  final String partnerId;

  /// cattle | horse
  final String type;
  final String breed;

  /// бұзау | торпақ | тайынша | ересек for cattle; құлын | тай | құнан | байтал for horses.
  final String? ageCategory;
  final double weight;

  /// Stored under the key imageUrl - what the website and both apps have always written.
  final String? imageUrl;

  /// male | female, as the website's form words it.
  final String? gender;

  /// The farm's asking price per kilo of live weight, and where the animal stands. A lot carries
  /// its own price - this is what the farm starts from when it builds one.
  final int pricePerKg;
  final String? region;
  final String? regionCode;

  /// active | sold. Nothing moves it yet; lots are what sell.
  final String status;

  /// The farm's own ear tag or number, if it keeps one.
  final String? tag;
  final DateTime? createdAt;

  factory Animal.fromMap(String id, Map<String, dynamic> map) => Animal(
        id: id,
        partnerId: asText(map['partnerId']),
        type: asText(map['type']).isEmpty ? 'cattle' : asText(map['type']),
        breed: asText(map['breed']),
        ageCategory: asTextOrNull(map['ageCategory']),
        weight: asDouble(map['weight']),
        // photoUrl is what an early version of this model expected; nothing ever wrote it.
        imageUrl: asTextOrNull(map['imageUrl']) ?? asTextOrNull(map['photoUrl']),
        gender: asTextOrNull(map['gender']),
        pricePerKg: asInt(map['price']),
        region: asTextOrNull(map['region']),
        regionCode: asTextOrNull(map['regionCode']),
        status: asText(map['status']).isEmpty ? 'active' : asText(map['status']),
        tag: asTextOrNull(map['tag']),
        createdAt: asTime(map['createdAt']),
      );

  Map<String, dynamic> toMap() => {
        'partnerId': partnerId,
        'type': type,
        'breed': breed,
        'ageCategory': ageCategory,
        'weight': weight,
        'imageUrl': imageUrl,
        'gender': gender,
        'price': pricePerKg,
        'region': region,
        'regionCode': regionCode,
        'status': status,
        'tag': tag,
      };
}

/// A scanned document: a veterinary certificate on an animal, or one of the farm's own (СЭС,
/// ветконтроль). Filed `pending`, decided by staff, and the verdict is the only thing that moves.
class FarmDocument {
  const FarmDocument({
    required this.id,
    required this.kind,
    required this.label,
    required this.fileUrl,
    this.contentType = '',
    this.fileName = '',
    this.size = 0,
    this.status = 'pending',
    this.reviewNote,
    this.uploadedAt,
    this.reviewedAt,
  });

  final String id;

  /// vet_certificate | vet_passport | ses | vet_control | other
  final String kind;
  final String label;
  final String fileUrl;
  final String contentType;
  final String fileName;
  final int size;

  /// pending | approved | rejected
  final String status;
  final String? reviewNote;
  final DateTime? uploadedAt;
  final DateTime? reviewedAt;

  bool get isImage => contentType.startsWith('image/');
  bool get isPending => status == 'pending';

  factory FarmDocument.fromMap(String id, Map<String, dynamic> map) => FarmDocument(
        id: id,
        kind: asText(map['kind']),
        label: asText(map['label']),
        fileUrl: asText(map['fileUrl']),
        contentType: asText(map['contentType']),
        fileName: asText(map['fileName']),
        size: asInt(map['size']),
        status: asText(map['status']).isEmpty ? 'pending' : asText(map['status']),
        reviewNote: asTextOrNull(map['reviewNote']),
        uploadedAt: asTime(map['uploadedAt']),
        reviewedAt: asTime(map['reviewedAt']),
      );
}
