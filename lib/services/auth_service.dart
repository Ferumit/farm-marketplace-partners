import 'dart:async';
import 'package:et_data/et_data.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Service that wraps Firebase Phone Authentication.
/// Notifies listeners on auth state changes.
class AuthService extends ChangeNotifier {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Push follows the account, not the app: the token is registered for whoever is signed in
  /// and taken off that account at sign-out. Otherwise the next person to hold the phone gets
  /// someone else's orders in their notification shade.
  final Push _push = Push();
  String? _pushFor;

  User? _user;
  String? _verificationId;

  /// Номер текущего запроса кода.
  ///
  /// Каждый вызов verifyPhoneNumber заводит СВОЮ сессию и через минуту дёргает
  /// codeAutoRetrievalTimeout — со своим verificationId. Если человек запросил код дважды (первый
  /// раз не дошёл, нажал «отправить снова»), таймаут ПЕРВОГО запроса перезаписывал
  /// _verificationId уже после того, как пришла вторая SMS. Код из новой SMS проверялся против
  /// старой сессии, и Firebase отвечал session-expired — «сессия истекла» на свежем коде.
  ///
  /// Поэтому у каждого запроса есть номер, и чужие обратные вызовы игнорируются.
  int _otpSession = 0;
  bool _isLoading = false;
  String? _error;

  User? get user => _user;
  bool get isLoggedIn => _user != null;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get uid => _user?.uid;
  String? get phone => _user?.phoneNumber;

  AuthService() {
    _user = _auth.currentUser;
    _auth.authStateChanges().listen((User? user) {
      _user = user;
      _followPush();
      notifyListeners();
    });
  }

  /// Sends OTP code to the given phone number.
  /// [phoneNumber] should include country code, e.g. '+77001234567'
  Future<bool> sendOtp(String phoneNumber) async {
    final session = ++_otpSession;
    _verificationId = null;
    _isLoading = true;
    _error = null;
    notifyListeners();

    final completer = Completer<bool>();

    await _auth.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (PhoneAuthCredential credential) async {
        // Android сам прочитал SMS и вошёл. Сессия при этом ИЗРАСХОДОВАНА: если после этого
        // человек наберёт тот же код руками, Firebase ответит «сессия истекла».
        if (session != _otpSession) return;
        try {
          await _signInWithCredential(credential);
        } catch (_) {
          // Не вышло автоматически - человек введёт код сам.
          return;
        }
        if (!completer.isCompleted) completer.complete(true);
      },
      verificationFailed: (FirebaseAuthException e) {
        if (session != _otpSession) return;
        _error = _mapAuthError(e.code);
        _isLoading = false;
        notifyListeners();
        if (!completer.isCompleted) completer.complete(false);
      },
      codeSent: (String verificationId, int? resendToken) {
        if (session != _otpSession) return;
        _verificationId = verificationId;
        _isLoading = false;
        notifyListeners();
        if (!completer.isCompleted) completer.complete(true);
      },
      // Здесь НИЧЕГО не присваивается: id тот же, что уже пришёл в codeSent, а вот у старой
      // сессии он свой - и именно он затирал новый.
      codeAutoRetrievalTimeout: (String verificationId) {},
    );

    return completer.future;
  }

  /// Verifies the OTP code entered by the user.
  Future<bool> verifyOtp(String smsCode) async {
    if (_verificationId == null) {
      _error = 'Сначала запросите код';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: smsCode,
      );
      await _signInWithCredential(credential);
      return true;
    } on FirebaseAuthException catch (e) {
      _error = _mapAuthError(e.code);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> _signInWithCredential(PhoneAuthCredential credential) async {
    await _auth.signInWithCredential(credential);
    _verificationId = null;
    _user = _auth.currentUser;
    _isLoading = false;
    notifyListeners();
  }

  /// Registers this phone once per account. Asking for permission at sign-in is the one moment
  /// the reason is obvious: the next thing that happens is an order.
  void _followPush() {
    final uid = _user?.uid;
    if (uid == null || uid == _pushFor) return;
    _pushFor = uid;
    _push.start(uid: uid, role: 'partner');
  }

  /// Signs out the current user.
  Future<void> signOut() async {
    final uid = _user?.uid;
    if (uid != null) await _push.stop(uid: uid, role: 'partner');
    _pushFor = null;
    await _auth.signOut();
    _user = null;
    _verificationId = null;
    notifyListeners();
  }

  /// Clears any displayed error.
  void clearError() {
    _error = null;
    notifyListeners();
  }

  /// Maps Firebase error codes to user-friendly Russian messages.
  String _mapAuthError(String code) {
    switch (code) {
      case 'invalid-phone-number':
        return 'Неверный формат номера. Используйте формат: +7XXXXXXXXXX';
      case 'too-many-requests':
      case 'quota-exceeded':
        return 'Лимит запросов исчерпан. Используйте тестовый номер: +77000000012 (код: 123456), или подождите несколько минут.';
      case 'invalid-verification-code':
        return 'Неверный код подтверждения';
      case 'session-expired':
        return 'Сессия истекла. Запросите новый код';
      case 'missing-phone-number':
        return 'Введите номер телефона';
      case 'captcha-check-failed':
        return 'Проверка безопасности не пройдена. Попробуйте снова';
      default:
        return 'Ошибка: $code';
    }
  }
}
