import '../models/filter_config.dart';
import '../models/offline_item.dart';

class PlaybackPolicy {
  static bool matchesRules({
    required String title,
    required String author,
    required String channelId,
    required FilterConfig rules,
  }) {
    bool matches(String value, List<String> blocked) => blocked.any(
      (term) =>
          term.trim().isNotEmpty &&
          value.toLowerCase().contains(term.trim().toLowerCase()),
    );
    return !matches(title, rules.blockedKeywords) &&
        !matches(author, rules.blockedChannels) &&
        !matches(channelId, rules.blockedChannels);
  }

  static bool allows(OfflineItem item, FilterConfig rules) =>
      item.approvedAt != null &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(item.contentHash) &&
      RegExp(r'^UC[a-zA-Z0-9_-]{22}$').hasMatch(item.channelId) &&
      matchesRules(
        title: item.title,
        author: item.author,
        channelId: item.channelId,
        rules: rules,
      );
}
