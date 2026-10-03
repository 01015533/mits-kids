import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/models/filter_config.dart';
import 'package:mits_kids_youtube/src/models/offline_item.dart';
import 'package:mits_kids_youtube/src/services/playback_policy.dart';

void main() {
  OfflineItem saved({
    bool approved = true,
    String channel = 'UCabcdefghijklmnopqrstuv',
  }) => OfflineItem(
    id: 'abcdefghijk',
    title: 'Example science',
    sourceUrl: '',
    filePath: '',
    bytes: 4,
    author: 'Example channel',
    channelId: channel,
    contentHash: List.filled(64, 'a').join(),
    createdAt: DateTime.utc(2026),
    approvedAt: approved ? DateTime.utc(2026) : null,
  );
  test('approval and canonical channel identity are required', () {
    expect(PlaybackPolicy.allows(saved(), FilterConfig.defaults), isTrue);
    expect(
      PlaybackPolicy.allows(saved(approved: false), FilterConfig.defaults),
      isFalse,
    );
    expect(
      PlaybackPolicy.allows(saved(channel: ''), FilterConfig.defaults),
      isFalse,
    );
  });
  test(
    'new keyword, channel name and channel-ID blocks revoke saved playback',
    () {
      for (final rules in [
        const FilterConfig(
          blockedChannels: [],
          blockedKeywords: ['SCIENCE'],
          blockShorts: true,
          blockLive: true,
        ),
        const FilterConfig(
          blockedChannels: ['example channel'],
          blockedKeywords: [],
          blockShorts: true,
          blockLive: true,
        ),
        const FilterConfig(
          blockedChannels: ['UCabcdefghijklmnopqrstuv'],
          blockedKeywords: [],
          blockShorts: true,
          blockLive: true,
        ),
      ]) {
        expect(PlaybackPolicy.allows(saved(), rules), isFalse);
      }
    },
  );
}
