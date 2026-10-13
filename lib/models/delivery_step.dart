import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents a delivery/traceability step for a lot.
/// Stored in Firestore: lots/{lotId}/deliveries/{deliveryId}
class DeliveryStep {
  final String id;
  final String lotId;
  final String title;
  final String subtitle;
  final String? description;
  final String? location;
  final String status;      // 'completed', 'current', 'pending'
  final DateTime? completedAt;
  final String? gpsCoords;
  final String icon;
  final int order;
  final String? mediaUrl;   // Photo URL captured at this step

  DeliveryStep({
    required this.id,
    required this.lotId,
    required this.title,
    required this.subtitle,
    this.description,
    this.location,
    this.status = 'pending',
    this.completedAt,
    this.gpsCoords,
    this.icon = 'place',
    this.order = 0,
    this.mediaUrl,
  });

  bool get isCompleted => status == 'completed';
  bool get isInProgress => status == 'in_progress' || status == 'current';

  String get statusLabel {
    switch (status) {
      case 'completed': return 'Завершён';
      case 'in_progress':
      case 'current': return 'В процессе';
      case 'pending': return 'Ожидает';
      default: return status;
    }
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'lotId': lotId,
    'title': title,
    'subtitle': subtitle,
    'description': description,
    'location': location,
    'status': status,
    'completedAt': completedAt != null ? Timestamp.fromDate(completedAt!) : null,
    'gpsCoords': gpsCoords,
    'icon': icon,
    'order': order,
    'mediaUrl': mediaUrl,
  };

  factory DeliveryStep.fromMap(String id, Map<String, dynamic> map) => DeliveryStep(
    id: id,
    lotId: map['lotId'] ?? '',
    title: map['title'] ?? '',
    subtitle: map['subtitle'] ?? '',
    description: map['description'],
    location: map['location'],
    status: map['status'] ?? 'pending',
    completedAt: (map['completedAt'] as Timestamp?)?.toDate(),
    gpsCoords: map['gpsCoords'],
    icon: map['icon'] ?? 'place',
    order: map['order'] ?? 0,
    mediaUrl: map['mediaUrl'],
  );

  DeliveryStep copyWith({
    String? status,
    DateTime? completedAt,
    String? gpsCoords,
    String? mediaUrl,
    String? location,
  }) => DeliveryStep(
    id: id,
    lotId: lotId,
    title: title,
    subtitle: subtitle,
    description: description,
    location: location ?? this.location,
    status: status ?? this.status,
    completedAt: completedAt ?? this.completedAt,
    gpsCoords: gpsCoords ?? this.gpsCoords,
    icon: icon,
    order: order,
    mediaUrl: mediaUrl ?? this.mediaUrl,
  );

  /// Creates the agreed 6-step delivery chain (RU names).
  /// Step 1 starts as 'current', rest are 'pending'.
  static List<DeliveryStep> defaultChain(String lotId) => [
    DeliveryStep(
      id: 'step_1_selection',
      lotId: lotId,
      title: 'Отбор',
      subtitle: 'Выбор животных',
      description: 'Ветеринарный осмотр и отбор животных для партии.',
      status: 'current',
      icon: 'agriculture',
      order: 1,
    ),
    DeliveryStep(
      id: 'step_2_preparation',
      lotId: lotId,
      title: 'Подготовка',
      subtitle: 'Предпродажная подготовка',
      description: 'Взвешивание, документирование и карантин.',
      status: 'pending',
      icon: 'task_alt',
      order: 2,
    ),
    DeliveryStep(
      id: 'step_3_processing',
      lotId: lotId,
      title: 'Обработка',
      subtitle: 'Убойный цех',
      description: 'Забой, разделка и ветеринарная сертификация.',
      status: 'pending',
      icon: 'factory',
      order: 3,
    ),
    DeliveryStep(
      id: 'step_4_packaging',
      lotId: lotId,
      title: 'Упаковка',
      subtitle: 'Фасовка и маркировка',
      description: 'Контрольное взвешивание, вакуумная упаковка и маркировка партии.',
      status: 'pending',
      icon: 'scale',
      order: 4,
    ),
    DeliveryStep(
      id: 'step_5_dispatch',
      lotId: lotId,
      title: 'Отправка',
      subtitle: 'Погрузка и транспорт',
      description: 'Загрузка в рефрижератор и отправка клиенту.',
      status: 'pending',
      icon: 'local_shipping',
      order: 5,
    ),
    DeliveryStep(
      id: 'step_6_delivery',
      lotId: lotId,
      title: 'Доставка',
      subtitle: 'Передача клиенту',
      description: 'Финальная передача и подтверждение получения.',
      status: 'pending',
      icon: 'content_cut',
      order: 6,
    ),
  ];
}
