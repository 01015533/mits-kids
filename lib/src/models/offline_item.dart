class OfflineItem {
  const OfflineItem({
    required this.id,
    required this.title,
    required this.sourceUrl,
    required this.filePath,
    required this.bytes,
    required this.createdAt,
    this.thumbnailUrl,
    this.author = '',
    this.channelId = '',
    this.contentHash = '',
    this.approvedAt,
  });

  final String id;
  final String title;
  final String sourceUrl;
  final String filePath;
  final int bytes;
  final DateTime createdAt;
  final String? thumbnailUrl;
  final String author;
  final String channelId;
  final String contentHash;
  final DateTime? approvedAt;

  factory OfflineItem.fromMap(Map<String, Object?> value) => OfflineItem(
    id: value['id']! as String,
    title: value['title']! as String,
    sourceUrl: value['source_url']! as String,
    filePath: value['file_path']! as String,
    bytes: value['bytes']! as int,
    createdAt: DateTime.parse(value['created_at']! as String),
    thumbnailUrl: value['thumbnail_url'] as String?,
    author: value['author'] as String? ?? '',
    channelId: value['channel_id'] as String? ?? '',
    contentHash: value['content_hash'] as String? ?? '',
    approvedAt: value['approved_at'] == null
        ? null
        : DateTime.parse(value['approved_at'] as String),
  );
}
