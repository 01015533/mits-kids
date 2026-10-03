const maxOfflineVideos = 8;
const maxDownloadBytes = 1024 * 1024 * 1024;
const offlineStorageReserveBytes = 128 * 1024 * 1024;
const offlineMuxAllowanceBytes = 16 * 1024 * 1024;

class DownloadFailure implements Exception {
  const DownloadFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class DownloadCancelled extends DownloadFailure {
  const DownloadCancelled() : super('Download cancelled.');
}

class LibraryFull extends DownloadFailure {
  const LibraryFull()
    : super(
        'All 8 offline slots are occupied. Ask a parent to delete a saved video in Parent first. Blocked and earlier downloads also occupy slots.',
      );
}
