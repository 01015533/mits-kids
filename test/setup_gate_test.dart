import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mits_kids/parent_security');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('fresh installation keeps every tab behind deliberate setup', (
    tester,
  ) async {
    var setupCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') {
        return {'configured': false, 'legacy': false};
      }
      if (call.method == 'setup') setupCalls++;
      return null;
    });
    await tester.pumpWidget(const MitsKidsApp());
    await tester.pumpAndSettle();
    expect(find.text('Parent setup'), findsOneWidget);
    await tester.tap(find.text('Browse · Parent'));
    await tester.pumpAndSettle();
    expect(find.text('Parent setup'), findsOneWidget);
    expect(find.text('Parent browsing'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.enterText(find.byType(TextField).last, '654321');
    await tester.tap(find.text('Complete parent setup'));
    await tester.pumpAndSettle();
    expect(setupCalls, 0);
    expect(
      find.text('Choose a 6–12 digit PIN and enter it twice.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
