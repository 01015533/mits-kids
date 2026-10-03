class UrlPolicy {
  static const allowedHosts = {
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtu.be',
  };

  static bool isAllowedNavigation(Uri? uri) {
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443) {
      return false;
    }
    final host = uri.host.toLowerCase();
    return allowedHosts.contains(host);
  }

  static bool isDownloadableVideo(Uri? uri) {
    return videoId(uri) != null;
  }

  static String? videoId(Uri? uri) {
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        !allowedHosts.contains(uri.host.toLowerCase())) {
      return null;
    }
    final String? id;
    if (uri.host.toLowerCase() == 'youtu.be' && uri.pathSegments.length == 1) {
      id = uri.pathSegments.first;
    } else if (uri.path == '/watch') {
      if (uri.queryParametersAll['v']?.length != 1) return null;
      id = uri.queryParameters['v'];
    } else {
      return null;
    }
    return id != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id)
        ? id
        : null;
  }
}
