/// Where everything lives in Firestore and Storage.
///
/// Collected in one place because the security rules are written against these exact paths: a
/// screen that invents its own path does not get a bug, it gets a refusal - and usually only on
/// someone else's phone.
library;

class Paths {
  Paths._();

  // Firestore collections
  static const partners = 'partners';
  static const clients = 'clients';
  static const lots = 'lots';
  static const animals = 'animals';
  static const orders = 'orders';
  static const reviews = 'reviews';
  static const groupBuys = 'groupBuys';
  static const notifications = 'notifications';
  static const disputes = 'disputes';
  static const payments = 'payments';
  static const staff = 'staff';
  static const feeds = 'feeds';
  static const chats = 'chats';

  // Subcollections
  static const documents = 'documents';
  static const deliveries = 'deliveries';
  static const purchases = 'purchases';
  static const cart = 'cart';
  static const devices = 'devices';
  static const private = 'private';

  /// The farm's private records: `identity` (ИИН/БИН), `contact` (email for notifications),
  /// `legal` (form, registered name, address), `location` (the exact point), `review` (the
  /// moderator's last decision). Readable by the farm and staff only - which is why the ИИН must
  /// never be written onto the public profile.
  static const privateIdentity = 'identity';
  static const privateContact = 'contact';
  static const privateLegal = 'legal';
  static const privateBank = 'bank';
  static const privateLocation = 'location';
  static const privateReview = 'review';

  /// Доступ к онлайн-кассе хозяйства: пароль и ПИН, которыми мы выбиваем фискальные чеки от его
  /// имени. Единственная запись в базе, которую не читает НИКТО из клиентов — ни сам фермер
  /// обратно, ни сотрудник. Читает только сервер.
  static const privateKassa = 'kassa';

  /// То же подключение, но без секретов: заводской номер и дата. Нужно, чтобы экран и чек-лист
  /// могли показать «касса подключена», не имея доступа к самим ключам.
  static const privateKassaInfo = 'kassaInfo';

  // Callable functions
  static const fnCreateOrder = 'createOrder';
  static const fnUpdateOrderStatus = 'updateOrderStatus';
  static const fnSubmitReview = 'submitReview';
  static const fnCreateGroupBuy = 'createGroupBuy';
  static const fnJoinGroupBuy = 'joinGroupBuy';
  static const fnLeaveGroupBuy = 'leaveGroupBuy';
  static const fnSetHubLocation = 'setHubLocation';
  static const fnDeleteMyAccount = 'deleteMyAccount';

  /// Functions and Firestore both live in europe-west3; a callable asked for from the default
  /// region answers 404, which reads as "функция не найдена" on a phone in a village.
  static const functionsRegion = 'europe-west3';

  // Storage folders. The rules scope each one to its owner.
  static String animalDocument(String partnerId, String animalId, String docId, String ext) =>
      'documents/$partnerId/$animalId/$docId.$ext';

  static String farmDocument(String partnerId, String docId, String ext) =>
      'documents/$partnerId/farm/$docId.$ext';

  static String orderFile(String partnerId, String orderId, String fileName) =>
      'orders/$partnerId/$orderId/$fileName';

  static String disputeFile(String uid, String orderId, String fileName) =>
      'disputes/$uid/${orderId}_$fileName';

  static String farmMedia(String partnerId, String fileName) => 'farms/$partnerId/$fileName';

  static String lotImage(String partnerId, String fileName) => 'lots/$partnerId/$fileName';

  static String animalPhoto(String partnerId, String animalId) =>
      'animals/$partnerId/$animalId.jpg';
}
