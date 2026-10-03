import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'fixtures/security_persistence_checks.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('isolated staged native security persistence', (tester) async {
    final result = await runSecurityPersistenceStage();
    await writeSecurityValidationResult(result);
    expect(result['result'], 'PASS');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
