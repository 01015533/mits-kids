import 'package:flutter/material.dart';

import 'fixtures/security_persistence_checks.dart';

/// Operator harness built only as the disposable validation debug APK. Reusing
/// one APK makes process/reboot probes independent of Flutter rebuild latency.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('MITS_SECURITY_VALIDATION');
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(
            enabled
                ? 'Disposable security validation in progress…'
                : 'Validation harness disabled.',
          ),
        ),
      ),
    ),
  );
  if (!enabled) return;
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final result = await runSecurityPersistenceStage();
      await writeSecurityValidationResult(result);
      debugPrint('Disposable security validation: ${result['stage']} PASS');
    } catch (failure) {
      final description = securityValidationFailure(failure);
      // The same package guard protects the result writer on every exit path.
      try {
        await writeSecurityValidationResult({
          'result': 'FAIL',
          'detail': description,
        });
      } catch (_) {
        /* Refusal outside the validation package must not write. */
      }
      debugPrint('Disposable security validation failed: $description');
    }
  });
}
