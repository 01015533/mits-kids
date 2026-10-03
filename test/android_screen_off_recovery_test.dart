import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/android_screen_off_recovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/screen-off-recovery');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidScreenOffRecovery recovery;
  late List<MethodCall> calls;
  late Future<Object?> Function(bool) respond;

  Future<void> event(String method, Object? arguments) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    calls = [];
    respond = (_) async => true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      expect(call.method, 'setEligible');
      return respond((call.arguments as Map)['eligible'] as bool);
    });
    recovery = AndroidScreenOffRecovery(channel: channel);
  });

  tearDown(() async {
    await recovery.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('arming is separate from session-bound recovery notification', () async {
    final received = <ScreenOffRecoveryEvent>[];
    final subscription = recovery.events.listen(received.add);
    expect(await recovery.setEligible(true), isTrue);
    final session = (calls.single.arguments as Map)['session'] as int;
    expect(session, greaterThan(0));
    expect(received, isEmpty);
    await event('recovered', {'session': session - 1, 'cycle': 1});
    await event('recovered', null);
    await event('unknown', {'session': session, 'cycle': 1});
    await event('recovered', {'session': session});
    expect(received, isEmpty);
    await event('recovering', {'session': session, 'cycle': 1});
    await event('recovered', {'session': session, 'cycle': 1});
    await event('unavailable', {'session': session, 'cycle': 1});
    expect(received, [
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 1,
      ),
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 1),
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.unavailable,
        cycle: 1,
      ),
    ]);
    await subscription.cancel();
  });

  test('late arm result cannot overtake an immediate disable', () async {
    final pending = Completer<Object?>();
    respond = (eligible) => eligible ? pending.future : Future.value(true);
    final arming = recovery.setEligible(true);
    expect(await recovery.setEligible(false), isTrue);
    pending.complete(true);
    expect(await arming, isFalse);
    expect(calls.map((c) => (c.arguments as Map)['eligible']), [true, false]);
  });

  test('missing plugin fails closed without an exception', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await recovery.setEligible(true), isFalse);
    expect(await recovery.setEligible(false), isFalse);
  });

  test(
    'timed-out arm queues release and ignores late acknowledgement',
    () async {
      await recovery.dispose();
      recovery = AndroidScreenOffRecovery(
        channel: channel,
        responseTimeout: const Duration(milliseconds: 10),
      );
      calls.clear();
      final pending = Completer<Object?>();
      respond = (eligible) => eligible ? pending.future : Future.value(true);
      expect(await recovery.setEligible(true), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => (c.arguments as Map)['eligible']), [true, false]);
      pending.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(2));
    },
  );

  test('old disposal cannot remove the new player callback', () async {
    await recovery.setEligible(true);
    final oldSession = (calls.last.arguments as Map)['session'] as int;
    final next = AndroidScreenOffRecovery(channel: channel);
    final received = <ScreenOffRecoveryEvent>[];
    final subscription = next.events.listen(received.add);
    await next.setEligible(true);
    final newSession = (calls.last.arguments as Map)['session'] as int;
    expect(newSession, greaterThan(oldSession));
    await recovery.dispose();
    await event('recovered', {'session': oldSession, 'cycle': 1});
    expect(received, isEmpty);
    await event('recovered', {'session': newSession, 'cycle': 1});
    expect(received, [
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 1),
    ]);
    expect(await recovery.setEligible(true), isFalse);
    await subscription.cancel();
    await next.dispose();
  });

  test('old failed arm cannot release a newer successful arm', () async {
    final pending = Completer<Object?>();
    var request = 0;
    respond = (_) => ++request == 1 ? pending.future : Future.value(true);
    final old = recovery.setEligible(true);
    expect(await recovery.setEligible(true), isTrue);
    pending.completeError(PlatformException(code: 'OLD'));
    expect(await old, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => (c.arguments as Map)['eligible']), [true, true]);
  });

  test('five screen cycles acknowledge their own native handoff', () async {
    final received = <ScreenOffRecoveryEvent>[];
    final subscription = recovery.events.listen(received.add);
    expect(await recovery.setEligible(true), isTrue);
    final session = (calls.single.arguments as Map)['session'] as int;
    for (var cycle = 1; cycle <= 5; cycle++) {
      await event('recovering', {'session': session, 'cycle': cycle});
      await event('recovered', {'session': session, 'cycle': cycle});
      expect(await recovery.setEligible(true, cycle: cycle), isTrue);
      expect((calls.last.arguments as Map)['cycle'], cycle);
    }
    expect(received, hasLength(10));
    expect(calls.map((c) => (c.arguments as Map)['cycle']), [0, 1, 2, 3, 4, 5]);
    await subscription.cancel();
  });

  test(
    'new cycle rejects older and duplicate recovery notifications',
    () async {
      final received = <ScreenOffRecoveryEvent>[];
      final subscription = recovery.events.listen(received.add);
      await recovery.setEligible(true);
      final session = (calls.single.arguments as Map)['session'] as int;
      await event('recovering', {'session': session, 'cycle': 1});
      await event('recovering', {'session': session, 'cycle': 2});
      await event('recovered', {'session': session, 'cycle': 1});
      await event('unavailable', {'session': session, 'cycle': 1});
      await event('recovering', {'session': session, 'cycle': 2});
      await event('recovered', {'session': session, 'cycle': 2});
      await event('recovered', {'session': session, 'cycle': 2});
      await event('recovering', {'session': session, 'cycle': 2});
      expect(received, [
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovering,
          cycle: 1,
        ),
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovering,
          cycle: 2,
        ),
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovered,
          cycle: 2,
        ),
      ]);
      await recovery.setEligible(true);
      expect((calls.last.arguments as Map)['cycle'], 2);
      await subscription.cancel();
    },
  );

  test('old arm failure cannot revoke a newly reported screen cycle', () async {
    final pending = Completer<Object?>();
    respond = (eligible) => eligible ? pending.future : Future.value(true);
    final arming = recovery.setEligible(true);
    await Future<void>.delayed(Duration.zero);
    final session = (calls.single.arguments as Map)['session'] as int;
    await event('recovering', {'session': session, 'cycle': 1});
    pending.completeError(PlatformException(code: 'LATE'));
    expect(await arming, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => (c.arguments as Map)['eligible']), [true]);
  });

  test(
    'disabled recovery ignores queued events until explicitly armed',
    () async {
      final received = <ScreenOffRecoveryEvent>[];
      final subscription = recovery.events.listen(received.add);
      await recovery.setEligible(true);
      final session = (calls.single.arguments as Map)['session'] as int;
      await event('recovering', {'session': session, 'cycle': 1});
      await recovery.setEligible(false);
      await event('recovered', {'session': session, 'cycle': 1});
      await event('recovering', {'session': session, 'cycle': 2});
      expect(received, [
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovering,
          cycle: 1,
        ),
      ]);
      await recovery.setEligible(true);
      await event('recovering', {'session': session, 'cycle': 2});
      expect(received.last.cycle, 2);
      await subscription.cancel();
    },
  );

  test(
    'native revoke snapshot closes an unseen screen cycle before re-arming',
    () async {
      final received = <ScreenOffRecoveryEvent>[];
      final subscription = recovery.events.listen(received.add);
      await recovery.setEligible(true);
      final session = (calls.single.arguments as Map)['session'] as int;
      await event('recovering', {'session': session, 'cycle': 1});
      respond = (eligible) async =>
          eligible ? true : {'confirmed': true, 'cycle': 2};
      expect(await recovery.setEligible(false), isTrue);
      expect(await recovery.setEligible(true), isTrue);
      expect((calls.last.arguments as Map)['cycle'], 2);
      await event('recovering', {'session': session, 'cycle': 2});
      await event('recovered', {'session': session, 'cycle': 2});
      expect(received, hasLength(1));
      await event('recovering', {'session': session, 'cycle': 3});
      await event('recovered', {'session': session, 'cycle': 3});
      expect(received.last.cycle, 3);
      expect(received.last.status, ScreenOffRecoveryStatus.recovered);
      await subscription.cancel();
    },
  );

  test(
    'older revoke acknowledgement cannot disable a newer screen cycle',
    () async {
      final received = <ScreenOffRecoveryEvent>[];
      final subscription = recovery.events.listen(received.add);
      await recovery.setEligible(true);
      final session = (calls.single.arguments as Map)['session'] as int;
      await event('recovering', {'session': session, 'cycle': 1});
      final pending = Completer<Object?>();
      respond = (eligible) => eligible ? Future.value(true) : pending.future;
      final disabling = recovery.setEligible(false);
      expect(await recovery.setEligible(true), isTrue);
      await event('recovering', {'session': session, 'cycle': 3});
      pending.complete({'confirmed': true, 'cycle': 2});
      expect(await disabling, isFalse);
      await event('recovered', {'session': session, 'cycle': 3});
      expect(
        received.last,
        const ScreenOffRecoveryEvent(
          ScreenOffRecoveryStatus.recovered,
          cycle: 3,
        ),
      );
      await recovery.setEligible(true);
      expect((calls.last.arguments as Map)['cycle'], 3);
      await subscription.cancel();
    },
  );

  test('malformed native revoke snapshot cannot confirm concealment', () async {
    for (final result in [
      {'confirmed': true},
      {'confirmed': true, 'cycle': -1},
      {'confirmed': true, 'cycle': '2'},
      {'confirmed': false, 'cycle': 2},
    ]) {
      respond = (_) async => result;
      expect(await recovery.setEligible(false), isFalse);
    }
  });

  test('failed arm cleanup learns the native cycle before retrying', () async {
    respond = (eligible) async =>
        eligible ? false : {'confirmed': true, 'cycle': 2};
    expect(await recovery.setEligible(true), isFalse);
    expect(calls.map((c) => (c.arguments as Map)['eligible']), [true, false]);
    respond = (_) async => true;
    expect(await recovery.setEligible(true), isTrue);
    expect((calls.last.arguments as Map)['cycle'], 2);
  });

  test('malformed cycle messages cannot establish a recovery', () async {
    final received = <ScreenOffRecoveryEvent>[];
    final subscription = recovery.events.listen(received.add);
    await recovery.setEligible(true);
    final session = (calls.single.arguments as Map)['session'] as int;
    for (final cycle in [null, -1, 0, '1', 1.5]) {
      await event('recovering', {'session': session, 'cycle': cycle});
      await event('recovered', {'session': session, 'cycle': cycle});
    }
    expect(received, isEmpty);
    await subscription.cancel();
  });

  test('disable permanently invalidates that cycle across re-arming', () async {
    final received = <ScreenOffRecoveryEvent>[];
    final subscription = recovery.events.listen(received.add);
    await recovery.setEligible(true);
    final session = (calls.single.arguments as Map)['session'] as int;
    await event('recovering', {'session': session, 'cycle': 1});
    await recovery.setEligible(false);
    await recovery.setEligible(true);
    await event('recovered', {'session': session, 'cycle': 1});
    await event('unavailable', {'session': session, 'cycle': 1});
    expect(received, [
      const ScreenOffRecoveryEvent(
        ScreenOffRecoveryStatus.recovering,
        cycle: 1,
      ),
    ]);
    await event('recovering', {'session': session, 'cycle': 2});
    await event('recovered', {'session': session, 'cycle': 2});
    expect(
      received.last,
      const ScreenOffRecoveryEvent(ScreenOffRecoveryStatus.recovered, cycle: 2),
    );
    await subscription.cancel();
  });

  test(
    'disable also filters a recovery already queued to the stream',
    () async {
      final received = <ScreenOffRecoveryEvent>[];
      final subscription = recovery.events.listen(received.add);
      await recovery.setEligible(true);
      final session = (calls.single.arguments as Map)['session'] as int;
      final queued = messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('recovering', {'session': session, 'cycle': 1}),
        ),
        (_) {},
      );
      final disabling = recovery.setEligible(false);
      await queued;
      await disabling;
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
      await subscription.cancel();
    },
  );
}
