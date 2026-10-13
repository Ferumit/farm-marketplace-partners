import 'dart:async';
import 'package:et_data/et_data.dart';
import 'package:et_ui/et_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_app_check/firebase_app_check.dart';

import 'package:provider/provider.dart';
import 'firebase_options.dart';
import 'services/auth_service.dart';
import 'services/firestore_service.dart';
import 'services/storage_service.dart';
import 'screens/main_tabs_screen.dart';

import 'models/user_profile.dart';
import 'theme/app_colors.dart';
import 'screens/welcome_screen.dart';


void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // A debug build started with --dart-define=ET_EMULATOR=true talks to the local Firebase
    // emulators instead of the live project, so a whole deal can be walked without touching a
    // real farm. Release builds always go to production.
    await EtFirebase.init(DefaultFirebaseOptions.currentPlatform);

    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
      providerApple: kDebugMode
          ? const AppleDebugProvider()
          : const AppleAppAttestProvider(),
    );

    // ─── Crashlytics setup ───────────────────────────────────────
    // Crashlytics alone would swallow the message: the default handler is what prints a layout
    // error to the console, and without it a broken screen just renders blank while debugging.
    FlutterError.onError = (details) {
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      if (kDebugMode) FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
    // Enable verbose crash reports in debug mode
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);

    runApp(const MyApp());
  }, (error, stack) {
    // Catches anything outside Flutter's own error zone (e.g. errors in
    // bare, unawaited Futures) that the handlers above would otherwise miss.
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        Provider(create: (_) => FirestoreService()),
        Provider(create: (_) => StorageService()),
      ],
      // Material, not Cupertino: the farm's app now shares the website's design - its palette,
      // its type and its parts (package et_ui) - and gains a dark theme, which matters on a
      // phone held in a slaughterhouse at six in the morning. Older Cupertino screens keep
      // working inside it while they are rebuilt.
      child: MaterialApp(
        title: 'ET Partner',
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', ''),
          Locale('ru', ''),
        ],
        theme: EtTheme.light(),
        darkTheme: EtTheme.dark(),
        themeMode: ThemeMode.system,
        home: const AuthGate(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _ensuringProfile = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (context, auth, _) {
        if (!auth.isLoggedIn || auth.uid == null) {
          return const WelcomeScreen();
        }

        FirebaseCrashlytics.instance.setUserIdentifier(auth.uid!);

        final firestore = context.read<FirestoreService>();

        return StreamBuilder<UserProfile?>(
          stream: firestore.userProfileStream(auth.uid!),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const CupertinoPageScaffold(
                backgroundColor: AppColors.surface,
                child: Center(child: CupertinoActivityIndicator()),
              );
            }

            final profile = snapshot.data;
            if (profile != null) {
              // Even if profile exists, if IIN is missing, they might still need RegistrationScreen
              // BUT the user asked for automatic record creation.
              // We'll let them into the app, but some features might check for completeness.
              return const MainTabsScreen();
            }

            // Auto-create profile if missing
            if (!_ensuringProfile) {
              _ensuringProfile = true;
              firestore.ensureProfileExists(auth.uid!, auth.phone).then((_) {
                if (mounted) setState(() => _ensuringProfile = false);
              }).catchError((Object e, StackTrace st) {
                FirebaseCrashlytics.instance.recordError(e, st, fatal: false);
                if (mounted) setState(() => _ensuringProfile = false);
              });
            }

            return const CupertinoPageScaffold(
              backgroundColor: AppColors.surface,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CupertinoActivityIndicator(),
                    SizedBox(height: 16),
                    Text('Подготовка кабинета партнера...',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
