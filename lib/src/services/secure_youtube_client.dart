import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Dart networking needs its own policy; Android's WebView policy is not enough.
class SecureYoutubeClient extends http.BaseClient {
  SecureYoutubeClient({http.Client? transport})
    : _transport =
          transport ??
          IOClient(
            HttpClient()
              ..connectionTimeout = const Duration(seconds: 20)
              ..maxConnectionsPerHost = 4,
          );
  final http.Client _transport;

  static bool allows(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.fragment.isNotEmpty) {
      return false;
    }
    final host = uri.host.toLowerCase();
    return const {
          'youtube.com',
          'www.youtube.com',
          'm.youtube.com',
          'youtu.be',
          'youtubei.googleapis.com',
        }.contains(host) ||
        (host.endsWith('.googlevideo.com') &&
            !host.endsWith('..googlevideo.com'));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var uri = request.url;
    var method = request.method;
    final headers = Map<String, String>.from(request.headers);
    var body = await request.finalize().toBytes();
    if (body.length > 1024 * 1024) {
      throw http.ClientException('Request exceeds its limit.');
    }
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!allows(uri)) {
        throw http.ClientException('Download destination is not allowed.');
      }
      final outbound = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(headers)
        ..bodyBytes = body;
      final response = await _transport
          .send(outbound)
          .timeout(const Duration(seconds: 30));
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      await response.stream.listen((_) {}).cancel();
      final location = response.headers['location'];
      if (location == null || redirects == 5) {
        throw http.ClientException('Invalid or excessive redirects.');
      }
      final next = uri.resolve(location);
      if (!allows(next)) {
        throw http.ClientException('Download redirect is not allowed.');
      }
      if (next.origin != uri.origin) {
        headers.removeWhere(
          (key, _) => const {
            'authorization',
            'cookie',
            'proxy-authorization',
            'referer',
          }.contains(key.toLowerCase()),
        );
      }
      if (response.statusCode == 303 ||
          ((response.statusCode == 301 || response.statusCode == 302) &&
              method == 'POST')) {
        method = 'GET';
        body = body.sublist(0, 0);
        headers.removeWhere(
          (key, _) => const {
            'content-type',
            'content-length',
          }.contains(key.toLowerCase()),
        );
      }
      uri = next;
    }
    throw http.ClientException('Redirect limit reached.');
  }

  @override
  void close() => _transport.close();
}
