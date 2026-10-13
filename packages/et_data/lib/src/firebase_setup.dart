import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:et_core/et_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

/// Starting Firebase - against the real project, or against the emulators on this machine.
///
/// A deal moves money, stock and evidence, so it must be possible to walk the whole road without
/// touching a real farm: place an order, accept it, film four steps, weigh a carcass, dispute it.
/// A debug build with `--dart-define=ET_EMULATOR=true` talks to the local emulators under the
/// demo project instead - the same one the rules tests and the seed script use.
class EtFirebase {
  EtFirebase._();

  static const useEmulators = bool.fromEnvironment('ET_EMULATOR');

  /// Starts Firebase and, in a debug build asked for it, points every service at the emulators.
  ///
  /// The project id is NOT changed for the emulators: on Android the native SDK has already
  /// created the default app from google-services.json, and initialising it again with different
  /// options fails with `duplicate-app`. So the emulators must be started under this project's
  /// own id instead:
  ///
  ///   firebase emulators:start --only auth,firestore,functions,storage --project farm-marketplace-demo
  ///   node functions/seed-emulator.cjs           (ET_PROJECT=farm-marketplace-demo)
  static Future<FirebaseApp> init(FirebaseOptions options) async {
    final app = Firebase.apps.isNotEmpty
        ? Firebase.app()
        : await Firebase.initializeApp(options: options);
    if (kDebugMode && useEmulators) await _connect();
    return app;
  }

  static Future<void> _connect() async {
    // An Android emulator reaches the machine it runs on at 10.0.2.2; everything else at
    // localhost. Getting this wrong looks exactly like "no network", so it is worth a line.
    final host = defaultTargetPlatform == TargetPlatform.android ? '10.0.2.2' : '127.0.0.1';
    await FirebaseAuth.instance.useAuthEmulator(host, 9099);
    FirebaseFirestore.instance.useFirestoreEmulator(host, 8085);
    FirebaseFunctions.instanceFor(region: Paths.functionsRegion)
        .useFunctionsEmulator(host, 5001);
    await FirebaseStorage.instance.useStorageEmulator(host, 9199);
    debugPrint('ET: Firebase emulators at $host');
  }
}
