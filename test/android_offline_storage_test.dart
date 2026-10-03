import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/android_offline_storage.dart';
import 'package:mits_kids_youtube/src/services/offline_limits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mits_kids/offline_media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'storage query preserves native free byte counts above 32 bits',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'availableBytes');
        expect(call.arguments, {'path': '/private/offline'});
        return 5 * 1024 * 1024 * 1024;
      });
      expect(
        await AndroidOfflineStorage.availableBytes(
          Directory('/private/offline'),
        ),
        5 * 1024 * 1024 * 1024,
      );
    },
  );

  test(
    'missing native storage query refuses to assume unlimited space',
    () async {
      await expectLater(
        AndroidOfflineStorage.availableBytes(Directory('/private/offline')),
        throwsA(
          isA<DownloadFailure>().having(
            (error) => error.message,
            'message',
            contains('full Android app rebuild'),
          ),
        ),
      );
    },
  );

  test('native storage failure is a user-facing download failure', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'STORAGE_UNAVAILABLE');
    });
    await expectLater(
      AndroidOfflineStorage.availableBytes(Directory('/private/offline')),
      throwsA(
        isA<DownloadFailure>().having(
          (error) => error.message,
          'message',
          contains('free storage'),
        ),
      ),
    );
  });
}
