import 'package:flutter_test/flutter_test.dart';
import 'package:mits_kids_youtube/src/models/filter_config.dart';
import 'package:mits_kids_youtube/src/services/filter_script.dart';

void main() {
  test('serialises rules safely rather than interpolating raw JavaScript', () {
    const config = FilterConfig(
      blockedChannels: ["channel'); alert(1); ('"],
      blockedKeywords: ['scary'],
      blockShorts: true,
      blockLive: false,
    );
    final script = FilterScript.build(config);
    expect(script, contains(r'alert(1)'));
    expect(script, contains('MutationObserver'));
    expect(script, contains('__mitsFilterReady'));
  });
}
