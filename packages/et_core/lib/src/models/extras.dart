import '../values.dart';

/// A review of a farm. One per ORDER (reviews/{orderId}), written by the buyer of a deal that
/// completed and published only after a moderator reads it - which is also why `partners.rating`
/// can only be moved by people who actually bought.
class Review {
  const Review({
    required this.id,
    required this.partnerId,
    required this.buyerUid,
    required this.buyerName,
    required this.rating,
    this.text = '',
    this.lotTitle = '',
    this.status = 'pending',
    this.moderationNote,
    this.createdAt,
  });

  final String id;
  final String partnerId;
  final String buyerUid;
  final String buyerName;
  final int rating;
  final String text;
  final String lotTitle;

  /// pending | published | rejected
  final String status;
  final String? moderationNote;
  final DateTime? createdAt;

  bool get isPublished => status == 'published';

  factory Review.fromMap(String id, Map<String, dynamic> map) => Review(
        id: id,
        partnerId: asText(map['partnerId']),
        buyerUid: asText(map['buyerUid']),
        buyerName: asText(map['buyerName']),
        rating: asInt(map['rating']),
        text: asText(map['text']),
        lotTitle: asText(map['lotTitle']),
        status: asText(map['status']).isEmpty ? 'pending' : asText(map['status']),
        moderationNote: asTextOrNull(map['moderationNote']),
        createdAt: asTime(map['createdAt']),
      );
}

/// Совместная покупка: 2-5 people splitting one carcass. Nothing is held while it fills - the
/// join that takes the last place is what creates the order for everyone.
class GroupBuy {
  const GroupBuy({
    required this.id,
    required this.lotId,
    required this.partnerId,
    this.lotTitle = '',
    this.partnerName = '',
    this.format = 'half',
    this.size = 2,
    this.amount = 0,
    this.perMember = const [],
    this.members = const [],
    this.memberUids = const [],
    this.status = 'open',
    this.orderId,
    this.failedReason,
    this.creatorUid = '',
    this.creatorName = '',
    this.deliveryCity,
    this.deliveryMode = 'agree',
    this.deliveryDate,
    this.createdAt,
  });

  final String id;
  final String lotId;
  final String partnerId;
  final String lotTitle;
  final String partnerName;
  final String format;
  final int size;
  final int amount;
  final List<int> perMember;
  final List<GroupBuyMember> members;
  final List<String> memberUids;

  /// open | placed | failed | cancelled
  final String status;
  final String? orderId;
  final String? failedReason;
  final String creatorUid;
  final String creatorName;
  final String? deliveryCity;
  final String deliveryMode;
  final String? deliveryDate;
  final DateTime? createdAt;

  bool get isOpen => status == 'open';
  int get joined => members.length;
  int get freePlaces => (size - joined).clamp(0, size);

  int shareFor(String uid) {
    for (final member in members) {
      if (member.uid == uid) return member.amount;
    }
    return joined < perMember.length ? perMember[joined] : 0;
  }

  factory GroupBuy.fromMap(String id, Map<String, dynamic> map) {
    final delivery = asMap(map['delivery']);
    return GroupBuy(
      id: id,
      lotId: asText(map['lotId']),
      partnerId: asText(map['partnerId']),
      lotTitle: asText(map['lotTitle']),
      partnerName: asText(map['partnerName']),
      format: asText(map['format']).isEmpty ? 'half' : asText(map['format']),
      size: asInt(map['size']),
      amount: asInt(map['amount']),
      perMember: (map['perMember'] is List)
          ? (map['perMember'] as List).map(asInt).toList()
          : const [],
      members: asMapList(map['members']).map(GroupBuyMember.fromMap).toList(),
      memberUids: asTextList(map['memberUids']),
      status: asText(map['status']).isEmpty ? 'open' : asText(map['status']),
      orderId: asTextOrNull(map['orderId']),
      failedReason: asTextOrNull(map['failedReason']),
      creatorUid: asText(map['creatorUid']),
      creatorName: asText(map['creatorName']),
      deliveryCity: asTextOrNull(delivery['city']),
      deliveryMode: asText(delivery['mode']).isEmpty ? 'agree' : asText(delivery['mode']),
      deliveryDate: asTextOrNull(map['deliveryDate']),
      createdAt: asTime(map['createdAt']),
    );
  }
}

class GroupBuyMember {
  const GroupBuyMember({required this.uid, required this.name, required this.amount, this.joinedAt});

  final String uid;
  final String name;
  final int amount;
  final DateTime? joinedAt;

  factory GroupBuyMember.fromMap(Map<String, dynamic> map) => GroupBuyMember(
        uid: asText(map['uid']),
        name: asText(map['name']),
        amount: asInt(map['amount']),
        joinedAt: asTime(map['joinedAt']),
      );
}

/// A notification written by the server inside the transaction of the event it announces. The
/// apps read their own and may mark them read - nothing else, or a browser could forge
/// "хозяйство приняло заказ".
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    this.body = '',
    this.link,
    this.orderId,
    this.groupId,
    this.read = false,
    this.createdAt,
  });

  final String id;
  final String kind;
  final String title;
  final String body;
  final String? link;
  final String? orderId;
  final String? groupId;
  final bool read;
  final DateTime? createdAt;

  factory AppNotification.fromMap(String id, Map<String, dynamic> map) => AppNotification(
        id: id,
        kind: asText(map['kind']),
        title: asText(map['title']),
        body: asText(map['body']),
        link: asTextOrNull(map['link']),
        orderId: asTextOrNull(map['orderId']),
        groupId: asTextOrNull(map['groupId']),
        read: asBool(map['read']),
        createdAt: asTime(map['createdAt']),
      );
}

/// A line of «Корзина»: the carcass, the choice made about it and a preview of the price. The
/// amounts are recomputed by createOrder when the order is placed - nothing here is money.
class CartItem {
  const CartItem({
    required this.id,
    required this.lotId,
    required this.partnerId,
    required this.format,
    this.lotTitle = '',
    this.partnerName = '',
    this.imageUrl,
    this.cuttingId,
    this.cuttingName,
    this.deliveryId,
    this.deliveryCity,
    this.deliveryMode = 'agree',
    this.weightKg,
    this.amount = 0,
    this.addedAt,
  });

  final String id;
  final String lotId;
  final String partnerId;
  final String format;
  final String lotTitle;
  final String partnerName;
  final String? imageUrl;
  final String? cuttingId;
  final String? cuttingName;
  final String? deliveryId;
  final String? deliveryCity;
  final String deliveryMode;
  final double? weightKg;
  final int amount;
  final DateTime? addedAt;

  /// One entry per carcass and format: picking the same half twice updates it instead of
  /// doubling. The website uses exactly this id, so a cart filled there opens here.
  static String idFor(String lotId, String format) => '${lotId}__$format';

  factory CartItem.fromMap(String id, Map<String, dynamic> map) => CartItem(
        id: id,
        lotId: asText(map['lotId']),
        partnerId: asText(map['partnerId']),
        format: asText(map['format']),
        lotTitle: asText(map['lotTitle']),
        partnerName: asText(map['partnerName']),
        imageUrl: asTextOrNull(map['imageUrl']),
        cuttingId: asTextOrNull(map['cuttingId']),
        cuttingName: asTextOrNull(map['cuttingName']),
        deliveryId: asTextOrNull(map['deliveryId']),
        deliveryCity: asTextOrNull(map['deliveryCity']),
        deliveryMode: asText(map['deliveryMode']).isEmpty ? 'agree' : asText(map['deliveryMode']),
        weightKg: map['weightKg'] == null ? null : asDouble(map['weightKg']),
        amount: asInt(map['amount']),
        addedAt: asTime(map['addedAt']),
      );

  Map<String, dynamic> toMap() => {
        'lotId': lotId,
        'lotTitle': lotTitle,
        'imageUrl': imageUrl,
        'partnerId': partnerId,
        'partnerName': partnerName,
        'format': format,
        'cuttingId': cuttingId,
        'cuttingName': cuttingName,
        'deliveryId': deliveryId,
        'deliveryCity': deliveryCity,
        'deliveryMode': deliveryMode,
        'weightKg': weightKg,
        'amount': amount,
      };
}
