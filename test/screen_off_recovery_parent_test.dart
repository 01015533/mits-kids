import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/screens/parent_screen.dart';
import 'package:mits_kids_youtube/src/services/offline_repository.dart';
import 'package:mits_kids_youtube/src/services/parent_session.dart';
import 'package:mits_kids_youtube/src/services/screen_off_recovery_preferences.dart';

class _Library extends OfflineRepository {
  @override
  Future<List<OfflineItem>> all() async => [];
  @override
  Future<Directory> storageDirectory() async => Directory('/offline');
}

class _RecoveryPreferences extends ScreenOffRecoveryPreferences {
  bool enabled = false;
  bool failRead = false;
  bool failWrite = false;
  Completer<void>? pendingWrite;
  Completer<bool>? pendingRead;
  final writes = <bool>[];

  @override
  Future<bool> isEnabled() async {
    if (pendingRead != null) return pendingRead!.future;
    if (failRead) throw StateError('Read failed');
    return enabled;
  }

  @override
  Future<void> setEnabled(bool value, ParentSession session) async {
    final token = session.token;
    writes.add(value);
    if (pendingWrite != null) await pendingWrite!.future;
    if (failWrite) throw StateError('Write failed');
    if (session.token != token) throw StateError('Expired');
    enabled = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const parentChannel = MethodChannel('test/recovery-parent-ui');
  const mediaChannel = MethodChannel('mits_kids/offline_media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const toggleKey = ValueKey('screen-off-recovery-switch');
  late ParentSession session;
  late _Library library;
  late _RecoveryPreferences preferences;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(parentChannel, (call) async {
      if (call.method == 'status') return {'configured': true, 'legacy': false};
      if (call.method == 'authenticate') return {'token': 'parent'};
      return null;
    });
    messenger.setMockMethodCallHandler(
      mediaChannel,
      (call) async => 4294967296,
    );
    session = ParentSession(channel: parentChannel);
    library = _Library();
    preferences = _RecoveryPreferences();
  });

  tearDown(() {
    session.dispose();
    library.dispose();
    messenger.setMockMethodCallHandler(parentChannel, null);
    messenger.setMockMethodCallHandler(mediaChannel, null);
  });

  Future<void> open(
    WidgetTester tester, {
    ScreenOffRecoveryPreferences? service,
    bool settle = true,
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await session.initialise();
    await session.authenticate('123456');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: ParentScreen(
          session: session,
          library: library,
          screenOffRecoveryPreferences: service ?? preferences,
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> clean(WidgetTester tester) async {
    session.lock();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'experimental recovery starts off and auto-saves without content-rule save',
    (tester) async {
      await open(tester, service: ScreenOffRecoveryPreferences());
      expect(find.text('Playback'), findsOneWidget);
      expect(find.text('Experimental'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).value,
        isFalse,
      );
      expect(find.textContaining('Saved automatically'), findsOneWidget);
      await tester.tap(find.byKey(toggleKey));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).value,
        isTrue,
      );
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isTrue);
      expect(
        (await SharedPreferences.getInstance()).getString('filter_config_v1'),
        isNull,
      );
      await clean(tester);
      await open(tester, service: ScreenOffRecoveryPreferences());
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).value,
        isTrue,
      );
      await tester.tap(find.byKey(toggleKey));
      await tester.pumpAndSettle();
      expect(await ScreenOffRecoveryPreferences().isEnabled(), isFalse);
      await clean(tester);
    },
  );

  testWidgets(
    'pending save disables the switch and expired parent access cannot enable recovery',
    (tester) async {
      preferences.pendingWrite = Completer<void>();
      await open(tester);
      await tester.tap(find.byKey(toggleKey));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).onChanged,
        isNull,
      );
      expect(find.text('Saving recovery setting…'), findsOneWidget);
      session.lock();
      preferences.pendingWrite!.complete();
      await tester.pumpAndSettle();
      expect(preferences.enabled, isFalse);
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).value,
        isFalse,
      );
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).onChanged,
        isNull,
      );
      expect(
        find.text('Recovery could not be saved. Unlock Parent and try again.'),
        findsOneWidget,
      );
      await clean(tester);
    },
  );

  testWidgets(
    'save failure keeps the previous confirmed switch state and shows retry guidance',
    (tester) async {
      preferences.enabled = true;
      preferences.failWrite = true;
      await open(tester);
      await tester.tap(find.byKey(toggleKey));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).value,
        isTrue,
      );
      expect(
        find.textContaining('previous confirmed setting is shown'),
        findsOneWidget,
      );
      preferences.failWrite = false;
      await tester.tap(find.byKey(toggleKey));
      await tester.pumpAndSettle();
      expect(preferences.enabled, isFalse);
      expect(
        find.textContaining('previous confirmed setting is shown'),
        findsNothing,
      );
      await clean(tester);
    },
  );

  testWidgets(
    'failed load uses off with retry and an authenticated off repair',
    (tester) async {
      preferences.failRead = true;
      await open(tester);
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).value,
        isFalse,
      );
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).onChanged,
        isNull,
      );
      expect(
        find.textContaining('playback will treat it as off'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry recovery setting'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('playback will treat it as off'),
        findsOneWidget,
      );
      preferences.failRead = false;
      await tester.tap(find.text('Keep recovery off'));
      await tester.pumpAndSettle();
      expect(preferences.writes, [false]);
      expect(
        tester.widget<SwitchListTile>(find.byKey(toggleKey)).onChanged,
        isNotNull,
      );
      expect(find.text('Keep recovery off'), findsNothing);
      await clean(tester);
    },
  );

  testWidgets(
    'late load and save completions do not update a disposed parent screen',
    (tester) async {
      preferences.pendingRead = Completer<bool>();
      await open(tester, settle: false);
      await tester.pumpWidget(const SizedBox.shrink());
      preferences.pendingRead!.complete(false);
      await tester.pumpAndSettle();
      preferences.pendingRead = null;
      preferences.pendingWrite = Completer<void>();
      await open(tester);
      await tester.tap(find.byKey(toggleKey));
      await tester.pump();
      await clean(tester);
      preferences.pendingWrite!.complete();
      await tester.pumpAndSettle();
      expect(preferences.enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recovery guidance wraps with enlarged text on a narrow parent screen',
    (tester) async {
      await open(tester, textScale: 2);
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(toggleKey));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.textContaining(
          'Your Android PIN, pattern or password remains in place.',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await clean(tester);
    },
  );
}
