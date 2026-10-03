import 'dart:convert';

import '../models/filter_config.dart';

class FilterScript {
  static String build(FilterConfig config) {
    final encoded = jsonEncode(config.toJson());
    return '''
(() => {
  'use strict';
  window.__mitsFilterObserver?.disconnect();
  document.querySelectorAll('[data-mits-filtered]').forEach(card => {
    card.style.removeProperty('display');
    card.removeAttribute('data-mits-filtered');
  });
  const config = $encoded;
  const normalise = value => (value || '').toLocaleLowerCase();
  const channels = config.blockedChannels.map(normalise);
  const keywords = config.blockedKeywords.map(normalise);
  const selectors = [
    'ytm-media-item', 'ytm-compact-video-renderer', 'ytm-video-with-context-renderer',
    'ytd-rich-item-renderer', 'ytd-video-renderer', 'ytd-compact-video-renderer',
    'ytd-reel-shelf-renderer', 'ytm-reel-shelf-renderer'
  ].join(',');

  function blocked(card) {
    const text = normalise(card.innerText);
    const link = card.querySelector('a[href]')?.getAttribute('href') || '';
    if (config.blockShorts && (link.includes('/shorts/') || card.matches('ytd-reel-shelf-renderer,ytm-reel-shelf-renderer'))) return true;
    if (config.blockLive && (text.includes(' live ') || text.startsWith('live ') || text.includes('watching now'))) return true;
    return channels.some(x => x && text.includes(x)) || keywords.some(x => x && text.includes(x));
  }

  function sanitise(root = document) {
    root.querySelectorAll(selectors).forEach(card => {
      if (blocked(card)) {
        card.setAttribute('data-mits-filtered', 'true');
        card.style.setProperty('display', 'none', 'important');
      }
    });
  }

  let queued = false;
  const observer = new MutationObserver(() => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; sanitise(); });
  });
  observer.observe(document.documentElement, {childList: true, subtree: true});
  window.__mitsFilterObserver = observer;
  sanitise();
  window.__mitsFilterReady = true;
})();
''';
  }
}
