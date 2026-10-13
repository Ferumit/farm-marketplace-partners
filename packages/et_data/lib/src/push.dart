import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';

import 'notifications_repo.dart';

/// Push, from the phone's side.
///
/// The server writes a notification document for every event and a trigger knocks on every phone
/// the person is signed into. This class owns the token: it asks permission, registers the token
/// under that account, keeps it fresh, and takes it off the list at sign-out - a token left
/// behind is how the next person to hold the phone starts seeing someone else's orders.
///
/// Nothing here decides anything. A push is a knock; the app still reads the order, the
/// gathering or the notification itself from Firestore, because a message can be delayed, lost,
/// or delivered twice.
class Push {
  Push({FirebaseMessaging? messaging, NotificationsRepo? repo})
      : _messaging = messaging ?? FirebaseMessaging.instance,
        _repo = repo ?? NotificationsRepo();

  final FirebaseMessaging _messaging;
  final NotificationsRepo _repo;

  StreamSubscription<String>? _refresh;
  String? _token;

  /// Android 13 and iOS both ask. A refusal is a normal answer: the app keeps working and the
  /// notifications are still there when it is opened.
  Future<bool> ask() async {
    final settings = await _messaging.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  /// Registers this phone for the person now signed in. Safe to call again - the token is the
  /// document id, so re-registering is one write over the same document.
  Future<void> start({required String uid, required String role}) async {
    if (!await ask()) return;
    try {
      final token = await _messaging.getToken();
      if (token != null) {
        _token = token;
        await _repo.registerDevice(
          uid: uid,
          role: role,
          token: token,
          platform: Platform.isIOS ? 'ios' : 'android',
        );
      }
      await _refresh?.cancel();
      _refresh = _messaging.onTokenRefresh.listen((token) {
        _token = token;
        _repo.registerDevice(
          uid: uid,
          role: role,
          token: token,
          platform: Platform.isIOS ? 'ios' : 'android',
        );
      });
    } catch (_) {
      // No Play services, no network, or push disabled on this build. Not worth a word on screen.
    }
  }

  /// Sign-out: this phone comes off the account, so a message already on its way cannot be
  /// delivered to whoever signs in next.
  ///
  /// Bounded on purpose. Signing out is a door the person is walking through, and it must not
  /// wait on FCM or on a village connection: the Firestore write is queued by the SDK and lands
  /// when there is network again, and the token itself is left alone - deleting it costs a round
  /// trip to Google and buys nothing, because the next person to sign in registers it anew.
  Future<void> stop({required String uid, required String role}) async {
    await _refresh?.cancel();
    _refresh = null;
    final token = _token;
    _token = null;
    if (token == null) return;
    try {
      await _repo
          .forgetDevice(uid: uid, role: role, token: token)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Queued by Firestore, or the phone is offline - either way, not the person's problem.
    }
  }

  /// The app is open and in front. Android shows nothing of its own here, so the app does.
  Stream<RemoteMessage> get whileOpen => FirebaseMessaging.onMessage;

  /// The person tapped the notification while the app was in the background.
  Stream<RemoteMessage> get opened => FirebaseMessaging.onMessageOpenedApp;

  /// The app was started BY a notification - the message that did it, once.
  Future<RemoteMessage?> launchMessage() => _messaging.getInitialMessage();
}

/// What a push is about, in the app's own terms.
///
/// The server sends ids, not routes: `link` is the website's path and means nothing to a phone.
/// An unknown push still opens the app - to the notifications, where the text is.
class PushTarget {
  const PushTarget({this.orderId, this.groupId, this.kind, this.title, this.body});

  final String? orderId;
  final String? groupId;
  final String? kind;
  final String? title;
  final String? body;

  bool get isOrder => orderId != null && orderId!.isNotEmpty;
  bool get isGroup => groupId != null && groupId!.isNotEmpty;

  static PushTarget of(RemoteMessage message) {
    String? value(String key) {
      final raw = message.data[key];
      final text = raw is String ? raw.trim() : '';
      return text.isEmpty ? null : text;
    }

    return PushTarget(
      orderId: value('orderId'),
      groupId: value('groupId'),
      kind: value('kind'),
      title: message.notification?.title,
      body: message.notification?.body,
    );
  }
}
