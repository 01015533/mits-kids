class FilterConfig {
  const FilterConfig({
    required this.blockedChannels,
    required this.blockedKeywords,
    required this.blockShorts,
    required this.blockLive,
  });

  final List<String> blockedChannels;
  final List<String> blockedKeywords;
  final bool blockShorts;
  final bool blockLive;

  static const defaults = FilterConfig(
    blockedChannels: [],
    blockedKeywords: [],
    blockShorts: true,
    blockLive: true,
  );

  Map<String, Object> toJson() => {
    'blockedChannels': blockedChannels,
    'blockedKeywords': blockedKeywords,
    'blockShorts': blockShorts,
    'blockLive': blockLive,
  };

  factory FilterConfig.fromJson(Map<String, dynamic> json) => FilterConfig(
    blockedChannels: List<String>.from(json['blockedChannels'] ?? const []),
    blockedKeywords: List<String>.from(json['blockedKeywords'] ?? const []),
    blockShorts: json['blockShorts'] as bool? ?? true,
    blockLive: json['blockLive'] as bool? ?? true,
  );
}
