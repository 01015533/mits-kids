import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/services/url_policy.dart';

void main() {
  group('UrlPolicy', () {
    test('allows YouTube HTTPS navigation', () {
      expect(
        UrlPolicy.isAllowedNavigation(
          Uri.parse('https://m.youtube.com/watch?v=abc'),
        ),
        isTrue,
      );
    });

    test('rejects lookalike and insecure hosts', () {
      expect(
        UrlPolicy.isAllowedNavigation(
          Uri.parse('https://youtube.com.example.test/watch?v=abc'),
        ),
        isFalse,
      );
      expect(
        UrlPolicy.isAllowedNavigation(
          Uri.parse('http://youtube.com/watch?v=abc'),
        ),
        isFalse,
      );
    });

    test('only accepts concrete watch links for saving', () {
      expect(
        UrlPolicy.isDownloadableVideo(
          Uri.parse('https://www.youtube.com/watch?v=abcdefghijk'),
        ),
        isTrue,
      );
      expect(
        UrlPolicy.isDownloadableVideo(
          Uri.parse('https://www.youtube.com/results?search_query=test'),
        ),
        isFalse,
      );
    });

    test('normalises watch and short URLs to one video ID', () {
      expect(
        UrlPolicy.videoId(
          Uri.parse('https://m.youtube.com/watch?v=abcdefghijk&t=20'),
        ),
        'abcdefghijk',
      );
      expect(
        UrlPolicy.videoId(
          Uri.parse('https://youtu.be/abcdefghijk?si=tracking'),
        ),
        'abcdefghijk',
      );
    });
    test('rejects malformed IDs, credentials, ports and lookalikes', () {
      for (final url in [
        'https://youtube.com/watch?v=abc',
        'https://youtube.com.evil.test/watch?v=abcdefghijk',
        'https://user@youtube.com/watch?v=abcdefghijk',
        'https://youtube.com:8443/watch?v=abcdefghijk',
        'https://youtu.be/abcdefghijk/extra',
        'https://www.youtube.com/watch?v=abcdefghijk&v=lmnopqrstuv',
      ]) {
        expect(UrlPolicy.videoId(Uri.parse(url)), isNull);
      }
    });
  });
}
