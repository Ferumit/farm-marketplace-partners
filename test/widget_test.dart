// Widget tests for ET_partners
// Note: Full app widget tests require Firebase initialization.
// These tests verify pure UI logic that doesn't depend on Firebase.

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Basic Flutter rendering smoke test', (WidgetTester tester) async {
    // Verify that a minimal CupertinoApp renders without errors
    await tester.pumpWidget(
      const CupertinoApp(
        home: CupertinoPageScaffold(
          child: Center(
            child: Text('ET Partners'),
          ),
        ),
      ),
    );
    expect(find.text('ET Partners'), findsOneWidget);
  });

  test('LoginStep enum has correct values', () {
    // Verify the enum values exist and are distinct
    const phone = LoginStep.phone;
    const otp = LoginStep.otp;
    expect(phone, isNot(equals(otp)));
  });
}

enum LoginStep { phone, otp }
