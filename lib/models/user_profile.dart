import 'package:cloud_firestore/cloud_firestore.dart';

/// User profile model — shared between ET_partners and ET_side_client.
/// Fields match the Firestore 'users' collection structure.
class UserProfile {
  final String uid;
  final String phone;
  final String role; // 'partner' or 'client'
  final String? displayName;
  final String? iin;       // ИИН/БИН
  final String? iban;      // Bank account
  final String? country;
  final String? documentUrl; // Vet permission doc
  final String status; // 'pending_review', 'verified', 'rejected', 'active'
  final DateTime createdAt;

  // ─── Extended fields (persisted to Firestore) ─────────────────
  final String? avatarUrl;  // Profile photo URL
  final String? city;       // e.g. "Қарағанды"
  final double rating;      // e.g. 4.9
  final int totalDeals;     // Total completed transactions
  final double walletBalance;   // Available balance in ₸
  final double pendingBalance;  // On-hold balance in ₸
  final List<String> achievements; // e.g. ['Тазалык 100%', 'GPS-верифицирован']

  UserProfile({
    required this.uid,
    required this.phone,
    required this.role,
    this.displayName,
    this.iin,
    this.iban,
    this.country,
    this.documentUrl,
    this.status = 'pending_review',
    DateTime? createdAt,
    this.avatarUrl,
    this.city,
    this.rating = 0.0,
    this.totalDeals = 0,
    this.walletBalance = 0.0,
    this.pendingBalance = 0.0,
    this.achievements = const [],
  }) : createdAt = createdAt ?? DateTime.now();

  /// Calculates profile completeness (0.0 - 1.0)
  double get completeness {
    int filled = 0;
    const int total = 5;
    if (phone.isNotEmpty) filled++;
    if (displayName != null && displayName!.isNotEmpty) filled++;
    if (iin != null && iin!.isNotEmpty) filled++;
    if (iban != null && iban!.isNotEmpty) filled++;
    if (documentUrl != null && documentUrl!.isNotEmpty) filled++;
    return filled / total;
  }

  /// Returns the next incomplete field label (for onboarding)
  String? get pendingField {
    if (displayName == null || displayName!.isEmpty) return 'Имя / Организация';
    if (iin == null || iin!.isEmpty) return 'ИИН/БИН';
    if (iban == null || iban!.isEmpty) return 'Номер IBAN';
    if (documentUrl == null || documentUrl!.isEmpty) return 'Ветеринарное разрешение';
    return null;
  }

  /// Short display name fallback
  String get shortName => displayName ?? phone;

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'phone': phone,
      'role': role,
      'displayName': displayName,
      'iin': iin,
      'iban': iban,
      'country': country,
      'documentUrl': documentUrl,
      'status': status,
      'createdAt': Timestamp.fromDate(createdAt),
      'avatarUrl': avatarUrl,
      'city': city,
      'rating': rating,
      'totalDeals': totalDeals,
      'walletBalance': walletBalance,
      'pendingBalance': pendingBalance,
      'achievements': achievements,
    };
  }

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    DateTime parsedDate = DateTime.now();
    if (map['createdAt'] is Timestamp) {
      parsedDate = (map['createdAt'] as Timestamp).toDate();
    } else if (map['createdAt'] is String) {
      parsedDate = DateTime.tryParse(map['createdAt']) ?? DateTime.now();
    }

    return UserProfile(
      uid: map['uid']?.toString() ?? '',
      phone: map['phone']?.toString() ?? '',
      role: map['role']?.toString() ?? 'partner',
      displayName: map['displayName']?.toString(),
      iin: map['iin']?.toString(),
      iban: map['iban']?.toString(),
      country: map['country']?.toString(),
      documentUrl: map['documentUrl']?.toString(),
      status: map['status']?.toString() ?? 'pending_review',
      createdAt: parsedDate,
      avatarUrl: map['avatarUrl']?.toString(),
      city: map['city']?.toString(),
      rating: map['rating'] != null ? double.tryParse(map['rating'].toString()) ?? 0.0 : 0.0,
      totalDeals: map['totalDeals'] != null ? int.tryParse(map['totalDeals'].toString()) ?? 0 : 0,
      walletBalance: map['walletBalance'] != null ? double.tryParse(map['walletBalance'].toString()) ?? 0.0 : 0.0,
      pendingBalance: map['pendingBalance'] != null ? double.tryParse(map['pendingBalance'].toString()) ?? 0.0 : 0.0,
      achievements: map['achievements'] is List ? List<String>.from(map['achievements'].map((e) => e.toString())) : [],
    );
  }

  UserProfile copyWith({
    String? displayName,
    String? iin,
    String? iban,
    String? country,
    String? documentUrl,
    String? status,
    String? avatarUrl,
    String? city,
    double? rating,
    int? totalDeals,
    double? walletBalance,
    double? pendingBalance,
    List<String>? achievements,
  }) {
    return UserProfile(
      uid: uid,
      phone: phone,
      role: role,
      displayName: displayName ?? this.displayName,
      iin: iin ?? this.iin,
      iban: iban ?? this.iban,
      country: country ?? this.country,
      documentUrl: documentUrl ?? this.documentUrl,
      status: status ?? this.status,
      createdAt: createdAt,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      city: city ?? this.city,
      rating: rating ?? this.rating,
      totalDeals: totalDeals ?? this.totalDeals,
      walletBalance: walletBalance ?? this.walletBalance,
      pendingBalance: pendingBalance ?? this.pendingBalance,
      achievements: achievements ?? this.achievements,
    );
  }
}
