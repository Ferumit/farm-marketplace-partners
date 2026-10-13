import 'package:cloud_firestore/cloud_firestore.dart';

class VetDocument {
  final String id;
  final String name; // e.g., 'Справка о здоровье', 'Паспорт животного'
  final String imageUrl;
  final String status; // 'pending', 'approved', 'rejected'
  final DateTime createdAt;

  VetDocument({
    required this.id,
    required this.name,
    required this.imageUrl,
    this.status = 'approved', // Auto-approved by default as requested
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'imageUrl': imageUrl,
        'status': status,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  factory VetDocument.fromMap(Map<String, dynamic> map) => VetDocument(
        id: map['id'] ?? '',
        name: map['name'] ?? '',
        imageUrl: map['imageUrl'] ?? '',
        status: map['status'] ?? 'pending',
        createdAt: (map['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      );
}
