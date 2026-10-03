import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mits_kids_youtube/src/services/secure_youtube_client.dart';

void main() {
  test(
    'blocks local addresses, cleartext, credentials, ports and lookalikes before transport',
    () async {
      var calls = 0;
      final client = SecureYoutubeClient(
        transport: MockClient((_) async {
          calls++;
          return http.Response('', 200);
        }),
      );
      for (final value in [
        'http://www.youtube.com/',
        'https://127.0.0.1/',
        'https://10.0.130.1/',
        'https://[::1]/',
        'https://a.googlevideo.com.evil.test/',
        'https://user@www.youtube.com/',
        'https://www.youtube.com:8443/',
        'https://unneeded.youtube.com/',
      ]) {
        await expectLater(
          client.get(Uri.parse(value)),
          throwsA(isA<http.ClientException>()),
        );
      }
      expect(calls, 0);
      client.close();
    },
  );

  test(
    'each redirect is checked and automatic redirects are disabled',
    () async {
      var calls = 0;
      final client = SecureYoutubeClient(
        transport: MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          return http.Response(
            '',
            302,
            headers: {'location': 'http://10.0.130.1/private'},
          );
        }),
      );
      await expectLater(
        client.get(Uri.parse('https://www.youtube.com/')),
        throwsA(isA<http.ClientException>()),
      );
      expect(calls, 1);
      client.close();
    },
  );

  test('allowed CDN redirect strips credentials across origins', () async {
    var calls = 0;
    final client = SecureYoutubeClient(
      transport: MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://rr1.googlevideo.com/videoplayback'},
          );
        }
        expect(request.headers.containsKey('authorization'), isFalse);
        expect(request.headers.containsKey('cookie'), isFalse);
        return http.Response('media', 200);
      }),
    );
    final response = await client.get(
      Uri.parse('https://www.youtube.com/'),
      headers: {'authorization': 'private', 'cookie': 'private'},
    );
    expect(response.body, 'media');
    expect(calls, 2);
    client.close();
  });

  test('redirect loops stop after the configured bound', () async {
    var calls = 0;
    final client = SecureYoutubeClient(
      transport: MockClient((_) async {
        calls++;
        return http.Response('', 302, headers: {'location': '/loop'});
      }),
    );
    await expectLater(
      client.get(Uri.parse('https://www.youtube.com/')),
      throwsA(isA<http.ClientException>()),
    );
    expect(calls, 6);
    client.close();
  });
}
